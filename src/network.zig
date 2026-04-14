//! Network initialization for EC2 instances.
//!
//! This module handles network interface discovery, DHCP configuration,
//! and interface naming.
//!
//! * Single ENI (common case): run DHCP on the single interface, and
//!   rename to eth0 if needed.
//! * Multiple ENIs: bootstrap DHCP on the lowest ifindex candidate to
//!   get connectivity, then fetch the mapping from MAC to device
//!   numbers from IMDS. Rename all interfaces to ethN by device number
//!   if necessary, then run DHCP on eth0. Secondaries are not configured.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const testing = std.testing;

const aws = @import("aws");
const dhcpz = @import("dhcpz");
const nlz = @import("nlz");

const constants = @import("constants.zig");
const fs = @import("fs.zig");

pub const Error = error{
    NoPrimaryInterface,
    DhcpTimeout,
    DhcpProtocol,
    NetlinkError,
    SocketError,
    ImdsError,
    OutOfMemory,
};

const dhcp_total_budget_ns: u64 = 15 * std.time.ns_per_s;
const dhcp_initial_retransmit_ns: u64 = 200 * std.time.ns_per_ms;
const dhcp_max_retransmit_ns: u64 = 4 * std.time.ns_per_s;
const carrier_wait_budget_ms: i32 = 10_000;

const max_interfaces = 16;

const ignored_prefixes = [_][]const u8{
    "lo",   "veth", "docker", "br",      "virbr",
    "vlan", "tun",  "tap",    "macvtap", "bond",
    "team", "wg",   "ppp",    "dummy",
};

const Candidate = struct {
    name_buf: [16]u8,
    name_len: u8,
    mac: [6]u8,
    ifindex: u32,

    fn name(self: *const Candidate) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

pub fn initializeNetwork(allocator: Allocator, imds_client: *aws.ImdsClient) !void {
    var socket = nlz.Socket.open() catch return Error.NetlinkError;
    defer socket.close();

    var candidates_buf: [max_interfaces]Candidate = undefined;
    var candidate_count: usize = 0;
    var lo_ifindex: ?u32 = null;

    {
        var links = socket.getLinks(allocator) catch return Error.NetlinkError;
        defer links.deinit();

        while (links.next()) |link| {
            const lname = link.name orelse continue;

            if (std.mem.eql(u8, lname, "lo")) {
                lo_ifindex = link.ifindex();
                continue;
            }

            if (link.isVirtual()) continue;
            if (isIgnored(lname)) continue;
            const mac = link.getMacAddress() orelse continue;

            if (candidate_count >= max_interfaces) {
                std.log.warn("more than {d} interfaces, ignoring {s}", .{ max_interfaces, lname });
                continue;
            }
            candidates_buf[candidate_count] = makeCandidate(lname, mac, link.ifindex());
            candidate_count += 1;
        }
    }

    if (candidate_count == 0) {
        std.log.err("no usable network interface found", .{});
        return Error.NoPrimaryInterface;
    }

    try configureLoopback(allocator, &socket, lo_ifindex);

    var candidates = candidates_buf[0..candidate_count];
    if (candidate_count == 1) {
        try configureSingleEni(allocator, &socket, &candidates[0]);
    } else {
        try configureMultiEni(allocator, &socket, candidates, imds_client);
    }

    setHostname(imds_client) catch |err| {
        std.log.warn("failed to set hostname: {s}", .{@errorName(err)});
    };
}

fn configureSingleEni(
    allocator: Allocator,
    socket: *nlz.Socket,
    primary: *Candidate,
) !void {
    if (!std.mem.eql(u8, primary.name(), "eth0")) {
        try renameInterface(allocator, socket, primary, "eth0");
    }

    try bringUpAndWaitCarrier(allocator, socket, primary.ifindex);

    var ack = try runDhcp(allocator, primary.name(), primary.mac);
    defer ack.deinit();

    try applyLease(allocator, socket, primary.ifindex, &ack);
}

const DeviceNumberMap = struct {
    macs: [max_interfaces][17]u8,
    device_numbers: [max_interfaces]u32,
    len: usize,

    fn deviceNumberForMac(self: *const DeviceNumberMap, mac: [6]u8) ?u32 {
        const mac_str = macToString(mac);
        for (self.macs[0..self.len], self.device_numbers[0..self.len]) |*m, dn| {
            if (std.mem.eql(u8, m, &mac_str)) return dn;
        }
        return null;
    }
};

fn configureMultiEni(
    allocator: Allocator,
    socket: *nlz.Socket,
    candidates: []Candidate,
    imds_client: *aws.ImdsClient,
) !void {
    // Sort by ifindex so we bootstrap on the lowest one (most likely primary).
    std.mem.sort(Candidate, candidates, {}, struct {
        fn lessThan(_: void, a: Candidate, b: Candidate) bool {
            return a.ifindex < b.ifindex;
        }
    }.lessThan);

    var bootstrap = &candidates[0];

    // Bootstrap: bring up, DHCP, apply lease to get IMDS connectivity.
    try bringUpAndWaitCarrier(allocator, socket, bootstrap.ifindex);

    var bootstrap_ack = try runDhcp(allocator, bootstrap.name(), bootstrap.mac);
    defer bootstrap_ack.deinit();

    try applyLease(allocator, socket, bootstrap.ifindex, &bootstrap_ack);

    // Get MAC -> device-number mapping for all interfaces from IMDS.
    const devmap = discoverDeviceNumbers(imds_client) catch |err| {
        std.log.warn(
            "IMDS device-number discovery failed: {s}, using bootstrap interface as primary",
            .{@errorName(err)},
        );
        if (!std.mem.eql(u8, bootstrap.name(), "eth0")) {
            try flushAndRename(allocator, socket, bootstrap, &bootstrap_ack, "eth0");
            try applyLease(allocator, socket, bootstrap.ifindex, &bootstrap_ack);
        }
        return;
    };

    // Find which candidate is device-number 0 (primary).
    var primary_idx: ?usize = null;
    for (candidates, 0..) |*c, i| {
        if (devmap.deviceNumberForMac(c.mac)) |dn| {
            if (dn == 0) {
                primary_idx = i;
                break;
            }
        }
    }

    const pidx = primary_idx orelse {
        std.log.err("no candidate matched IMDS device-number 0", .{});
        return Error.NoPrimaryInterface;
    };

    // Flush bootstrap lease before renaming anything.
    flushLease(allocator, socket, bootstrap.ifindex, &bootstrap_ack);

    // Rename all candidates to ethN based on device-number.
    for (candidates) |*c| {
        const dn = devmap.deviceNumberForMac(c.mac) orelse continue;
        var name_buf: [16]u8 = undefined;
        const desired = std.fmt.bufPrint(&name_buf, "eth{d}", .{dn}) catch continue;
        if (!std.mem.eql(u8, c.name(), desired)) {
            renameInterface(allocator, socket, c, desired) catch |err| {
                std.log.warn("failed to rename {s} to {s}: {s}", .{
                    c.name(),
                    desired,
                    @errorName(err),
                });
            };
        }
    }

    // DHCP and apply lease on the primary.
    var primary = &candidates[pidx];
    try bringUpAndWaitCarrier(allocator, socket, primary.ifindex);

    var primary_ack = try runDhcp(allocator, primary.name(), primary.mac);
    defer primary_ack.deinit();

    try applyLease(allocator, socket, primary.ifindex, &primary_ack);
}

fn bringUpAndWaitCarrier(allocator: Allocator, socket: *nlz.Socket, ifindex: u32) !void {
    var carrier_mon = nlz.LinkMonitor.open(nlz.rtnetlink.RTMGRP.LINK) catch |err| {
        std.log.err("failed to open link monitor: {s}", .{@errorName(err)});
        return Error.NetlinkError;
    };
    defer carrier_mon.close();

    socket.setLinkUp(ifindex, allocator) catch |err| {
        std.log.err("setLinkUp failed on ifindex {d}: {s}", .{ ifindex, @errorName(err) });
        return Error.NetlinkError;
    };

    try waitForCarrier(allocator, socket, &carrier_mon, ifindex);
}

fn waitForCarrier(
    allocator: Allocator,
    socket: *nlz.Socket,
    monitor: *nlz.LinkMonitor,
    ifindex: u32,
) !void {
    {
        var links = socket.getLinks(allocator) catch return Error.NetlinkError;
        defer links.deinit();
        while (links.next()) |link| {
            if (link.ifindex() == ifindex and link.hasCarrier()) return;
        }
    }

    monitor.waitCarrier(ifindex, carrier_wait_budget_ms) catch |err| {
        std.log.err(
            "carrier never came up on ifindex {d}: {s}",
            .{ ifindex, @errorName(err) },
        );
        return Error.NetlinkError;
    };
}

fn renameInterface(
    allocator: Allocator,
    socket: *nlz.Socket,
    candidate: *Candidate,
    desired: []const u8,
) !void {
    // Resolve collisions: if desired name is taken by another interface,
    // move it aside first.
    var collision_ifindex: ?u32 = null;
    var max_eth_idx: u32 = 0;

    {
        var links = socket.getLinks(allocator) catch return Error.NetlinkError;
        defer links.deinit();
        while (links.next()) |link| {
            const lname = link.name orelse continue;
            if (std.mem.eql(u8, lname, desired) and link.ifindex() != candidate.ifindex) {
                collision_ifindex = link.ifindex();
            }
            if (std.mem.startsWith(u8, lname, "eth")) {
                if (std.fmt.parseInt(u32, lname[3..], 10)) |n| {
                    if (n > max_eth_idx) max_eth_idx = n;
                } else |_| {}
            }
        }
    }

    if (collision_ifindex) |ci| {
        var buf: [16]u8 = undefined;
        const new_name = std.fmt.bufPrint(&buf, "eth{d}", .{max_eth_idx + 1}) catch
            return Error.NetlinkError;
        // Must bring down to rename.
        socket.setLinkDown(ci, allocator) catch {};
        socket.setLinkName(ci, new_name, allocator) catch |err| {
            std.log.err("failed to move {s} collision aside: {s}", .{ desired, @errorName(err) });
            return Error.NetlinkError;
        };
    }

    socket.setLinkDown(candidate.ifindex, allocator) catch {};
    socket.setLinkName(candidate.ifindex, desired, allocator) catch |err| {
        std.log.err("failed to rename ifindex {d} to {s}: {s}", .{
            candidate.ifindex,
            desired,
            @errorName(err),
        });
        return Error.NetlinkError;
    };

    const n = @min(desired.len, candidate.name_buf.len);
    @memcpy(candidate.name_buf[0..n], desired[0..n]);
    candidate.name_len = @intCast(n);
}

fn flushAndRename(
    allocator: Allocator,
    socket: *nlz.Socket,
    candidate: *Candidate,
    ack: *dhcpz.v4.Message,
    desired: []const u8,
) !void {
    flushLease(allocator, socket, candidate.ifindex, ack);
    try renameInterface(allocator, socket, candidate, desired);
    socket.setLinkUp(candidate.ifindex, allocator) catch return Error.NetlinkError;
}

fn flushLease(
    allocator: Allocator,
    socket: *nlz.Socket,
    ifindex: u32,
    ack: *dhcpz.v4.Message,
) void {
    const subnet = ack.options.get(.subnet_mask) orelse return;
    const prefix_len = subnetMaskToPrefix(subnet);

    // Remove default route first, then the address.
    socket.delRouteIPv4(ifindex, .{ 0, 0, 0, 0 }, 0, allocator) catch {};
    socket.delAddressIPv4(ifindex, ack.yiaddr, prefix_len, allocator) catch {};
}

fn makeCandidate(iface_name: []const u8, mac: [6]u8, ifindex: u32) Candidate {
    var c: Candidate = .{
        .name_buf = undefined,
        .name_len = 0,
        .mac = mac,
        .ifindex = ifindex,
    };
    const n = @min(iface_name.len, c.name_buf.len);
    @memcpy(c.name_buf[0..n], iface_name[0..n]);
    c.name_len = @intCast(n);
    return c;
}

fn isIgnored(iface_name: []const u8) bool {
    for (ignored_prefixes) |p| {
        if (std.mem.startsWith(u8, iface_name, p)) return true;
    }
    return false;
}

fn configureLoopback(allocator: Allocator, socket: *nlz.Socket, lo_ifindex: ?u32) !void {
    const idx = lo_ifindex orelse return;
    socket.setLinkUp(idx, allocator) catch |err| {
        std.log.warn("failed to bring up lo: {s}", .{@errorName(err)});
        return;
    };
    socket.addAddressIPv4(idx, .{ 127, 0, 0, 1 }, 8, allocator) catch {};
    socket.addAddressIPv6(
        idx,
        .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 },
        128,
        allocator,
    ) catch {};
}

fn discoverDeviceNumbers(imds_client: *aws.ImdsClient) !DeviceNumberMap {
    const imds_alloc = imds_client.allocator;

    const macs_list = imds_client.getMetadata(
        "/latest/meta-data/network/interfaces/macs/",
        .{},
    ) catch return Error.ImdsError;
    defer imds_alloc.free(macs_list);

    var result: DeviceNumberMap = .{
        .macs = undefined,
        .device_numbers = undefined,
        .len = 0,
    };

    var it = std.mem.splitScalar(u8, macs_list, '\n');
    while (it.next()) |line| {
        const mac = std.mem.trim(u8, line, " \t\r\n/");
        if (mac.len != 17) continue;
        if (result.len >= max_interfaces) break;

        var path_buf: [128]u8 = undefined;
        const path = std.fmt.bufPrint(
            &path_buf,
            "/latest/meta-data/network/interfaces/macs/{s}/device-number",
            .{mac},
        ) catch continue;

        const devnum_str = imds_client.getMetadata(path, .{}) catch continue;
        defer imds_alloc.free(devnum_str);

        const dn = std.fmt.parseInt(u32, std.mem.trim(u8, devnum_str, " \t\r\n"), 10) catch continue;

        @memcpy(&result.macs[result.len], mac[0..17]);
        result.device_numbers[result.len] = dn;
        result.len += 1;
    }

    if (result.len == 0) return Error.ImdsError;
    return result;
}

fn runDhcp(
    allocator: Allocator,
    iface_name: []const u8,
    mac: [6]u8,
) !dhcpz.v4.Message {
    const sock = try openDhcpSocket(iface_name);
    defer posix.close(sock);

    var xid_bytes: [4]u8 = undefined;
    std.crypto.random.bytes(&xid_bytes);
    const xid = std.mem.readInt(u32, &xid_bytes, .little);

    const start_ns = std.time.nanoTimestamp();
    const deadline_ns = start_ns + @as(i128, dhcp_total_budget_ns);

    var discover = try dhcpz.v4.createDiscover(allocator, xid, mac);
    defer discover.deinit();
    var dbuf: [1500]u8 = undefined;
    const dlen = discover.encode(&dbuf) catch return Error.DhcpProtocol;

    var offer = try exchange(allocator, sock, dbuf[0..dlen], xid, .offer, deadline_ns);
    defer offer.deinit();

    const server_id = offer.options.get(.server_identifier) orelse return Error.DhcpProtocol;
    const offered_ip = offer.yiaddr;

    var request = try dhcpz.v4.createRequest(allocator, xid, mac, offered_ip, server_id);
    defer request.deinit();
    var rbuf: [1500]u8 = undefined;
    const rlen = request.encode(&rbuf) catch return Error.DhcpProtocol;

    return try exchange(allocator, sock, rbuf[0..rlen], xid, .ack, deadline_ns);
}

fn exchange(
    allocator: Allocator,
    sock: posix.fd_t,
    packet: []const u8,
    xid: u32,
    want: dhcpz.v4.MessageType,
    deadline_ns: i128,
) !dhcpz.v4.Message {
    var retransmit_ns: u64 = dhcp_initial_retransmit_ns;
    while (true) {
        try sendBroadcast(sock, packet);

        const now = std.time.nanoTimestamp();
        if (now >= deadline_ns) return Error.DhcpTimeout;

        const window_end = @min(now + @as(i128, retransmit_ns), deadline_ns);
        if (try recvUntil(allocator, sock, xid, want, window_end)) |msg| {
            return msg;
        }
        if (std.time.nanoTimestamp() >= deadline_ns) return Error.DhcpTimeout;

        retransmit_ns = @min(retransmit_ns * 2, dhcp_max_retransmit_ns);
    }
}

fn sendBroadcast(sock: posix.fd_t, packet: []const u8) !void {
    const addr = posix.sockaddr.in{
        .family = posix.AF.INET,
        .port = std.mem.nativeToBig(u16, dhcpz.v4.SERVER_PORT),
        .addr = 0xFFFFFFFF,
    };
    _ = posix.sendto(sock, packet, 0, @ptrCast(&addr), @sizeOf(posix.sockaddr.in)) catch |err| {
        std.log.warn("DHCP sendto failed: {s}", .{@errorName(err)});
        return Error.SocketError;
    };
}

fn recvUntil(
    allocator: Allocator,
    sock: posix.fd_t,
    xid: u32,
    want: dhcpz.v4.MessageType,
    deadline_ns: i128,
) !?dhcpz.v4.Message {
    var buf: [1500]u8 = undefined;
    while (true) {
        const now = std.time.nanoTimestamp();
        if (now >= deadline_ns) return null;

        const remaining_ms_i128 = @divFloor(deadline_ns - now, std.time.ns_per_ms);
        const remaining_ms: i32 = if (remaining_ms_i128 > std.math.maxInt(i32))
            std.math.maxInt(i32)
        else if (remaining_ms_i128 < 1)
            1
        else
            @intCast(remaining_ms_i128);

        var pfd = [_]posix.pollfd{.{
            .fd = sock,
            .events = posix.POLL.IN,
            .revents = 0,
        }};
        const pr = posix.poll(&pfd, remaining_ms) catch return Error.SocketError;
        if (pr == 0) return null;

        const n = posix.recvfrom(sock, &buf, 0, null, null) catch |err| {
            if (err == error.WouldBlock) continue;
            return Error.SocketError;
        };
        if (n == 0) continue;

        var msg = dhcpz.v4.Message.decode(allocator, buf[0..n]) catch continue;
        if (msg.xid == xid) {
            if (msg.options.getMessageType()) |mt| {
                if (mt == want) return msg;
            }
        }
        msg.deinit();
    }
}

fn openDhcpSocket(iface_name: []const u8) !posix.fd_t {
    const sock = posix.socket(posix.AF.INET, posix.SOCK.DGRAM, posix.IPPROTO.UDP) catch
        return Error.SocketError;
    errdefer posix.close(sock);

    const one: c_int = 1;
    posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&one)) catch {};
    posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.BROADCAST, std.mem.asBytes(&one)) catch {};

    var ifname: [16]u8 = [_]u8{0} ** 16;
    const ifn = @min(iface_name.len, 15);
    @memcpy(ifname[0..ifn], iface_name[0..ifn]);
    posix.setsockopt(
        sock,
        posix.SOL.SOCKET,
        linux.SO.BINDTODEVICE,
        ifname[0 .. ifn + 1],
    ) catch return Error.SocketError;

    const bind_addr = posix.sockaddr.in{
        .family = posix.AF.INET,
        .port = std.mem.nativeToBig(u16, dhcpz.v4.CLIENT_PORT),
        .addr = 0,
    };
    posix.bind(sock, @ptrCast(&bind_addr), @sizeOf(posix.sockaddr.in)) catch
        return Error.SocketError;

    return sock;
}

fn applyLease(
    allocator: Allocator,
    socket: *nlz.Socket,
    ifindex: u32,
    ack: *dhcpz.v4.Message,
) !void {
    const subnet = ack.options.get(.subnet_mask) orelse return Error.DhcpProtocol;
    const prefix_len = subnetMaskToPrefix(subnet);

    const routers = ack.options.get(.router) orelse return Error.DhcpProtocol;
    if (routers.len == 0) return Error.DhcpProtocol;
    const gateway = routers[0];

    socket.addAddressIPv4(ifindex, ack.yiaddr, prefix_len, allocator) catch |err| {
        std.log.err("addAddressIPv4: {s}", .{@errorName(err)});
        return Error.NetlinkError;
    };
    socket.addRouteIPv4(ifindex, .{ 0, 0, 0, 0 }, gateway, 0, allocator) catch |err| {
        std.log.err("addRouteIPv4: {s}", .{@errorName(err)});
        return Error.NetlinkError;
    };

    writeResolvConf(ack) catch |err| {
        std.log.warn("resolv.conf: {s}", .{@errorName(err)});
    };
}

fn writeResolvConf(ack: *dhcpz.v4.Message) !void {
    const dns = ack.options.get(.domain_name_server) orelse return;
    if (dns.len == 0) return;

    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();

    if (ack.options.get(.domain_name)) |dn| w.print("domain {s}\n", .{dn}) catch {};

    if (ack.options.get(.domain_search)) |list| {
        if (list.len > 0) {
            w.writeAll("search") catch {};
            for (list) |d| w.print(" {s}", .{d}) catch {};
            w.writeAll("\n") catch {};
        }
    }

    for (dns) |s| {
        w.print("nameserver {}.{}.{}.{}\n", .{ s[0], s[1], s[2], s[3] }) catch {};
    }

    try fs.atomicWriteFile(constants.FILE_ETC_RESOLV_CONF, fbs.getWritten(), 0o644);
}

fn subnetMaskToPrefix(mask: [4]u8) u8 {
    const bits = (@as(u32, mask[0]) << 24) |
        (@as(u32, mask[1]) << 16) |
        (@as(u32, mask[2]) << 8) |
        @as(u32, mask[3]);
    return @intCast(@popCount(bits));
}

fn macToString(mac: [6]u8) [17]u8 {
    var out: [17]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}", .{
        mac[0], mac[1], mac[2], mac[3], mac[4], mac[5],
    }) catch unreachable;
    return out;
}

fn setHostname(imds_client: *aws.ImdsClient) !void {
    const hostname = imds_client.getMetadata("/latest/meta-data/local-hostname", .{}) catch
        return Error.ImdsError;
    defer imds_client.allocator.free(hostname);

    const trimmed = std.mem.trim(u8, hostname, " \t\r\n");
    if (trimmed.len == 0) return;

    const ret = linux.syscall2(.sethostname, @intFromPtr(trimmed.ptr), trimmed.len);
    if (posix.errno(ret) != .SUCCESS) return Error.ImdsError;
}

test "subnetMaskToPrefix /24" {
    try testing.expectEqual(@as(u8, 24), subnetMaskToPrefix(.{ 255, 255, 255, 0 }));
}

test "subnetMaskToPrefix /32" {
    try testing.expectEqual(@as(u8, 32), subnetMaskToPrefix(.{ 255, 255, 255, 255 }));
}

test "subnetMaskToPrefix /0" {
    try testing.expectEqual(@as(u8, 0), subnetMaskToPrefix(.{ 0, 0, 0, 0 }));
}

test "subnetMaskToPrefix /16" {
    try testing.expectEqual(@as(u8, 16), subnetMaskToPrefix(.{ 255, 255, 0, 0 }));
}

test "subnetMaskToPrefix /20" {
    try testing.expectEqual(@as(u8, 20), subnetMaskToPrefix(.{ 255, 255, 240, 0 }));
}

test "subnetMaskToPrefix /8" {
    try testing.expectEqual(@as(u8, 8), subnetMaskToPrefix(.{ 255, 0, 0, 0 }));
}

test "macToString formats correctly" {
    const mac = [6]u8{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 };
    const result = macToString(mac);
    try testing.expectEqualStrings("52:54:00:12:34:56", &result);
}

test "macToString all zeros" {
    const result = macToString(.{ 0, 0, 0, 0, 0, 0 });
    try testing.expectEqualStrings("00:00:00:00:00:00", &result);
}

test "macToString all ff" {
    const result = macToString(.{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff });
    try testing.expectEqualStrings("ff:ff:ff:ff:ff:ff", &result);
}

test "isIgnored matches prefixes" {
    try testing.expect(isIgnored("lo"));
    try testing.expect(isIgnored("lo0"));
    try testing.expect(isIgnored("veth123"));
    try testing.expect(isIgnored("docker0"));
    try testing.expect(isIgnored("br-abc"));
    try testing.expect(isIgnored("virbr0"));
    try testing.expect(isIgnored("tun0"));
    try testing.expect(isIgnored("tap0"));
    try testing.expect(isIgnored("wg0"));
    try testing.expect(isIgnored("dummy0"));
}

test "isIgnored rejects real interfaces" {
    try testing.expect(!isIgnored("eth0"));
    try testing.expect(!isIgnored("ens5"));
    try testing.expect(!isIgnored("enp0s3"));
    try testing.expect(!isIgnored("eno1"));
}

test "makeCandidate preserves fields" {
    const c = makeCandidate("ens5", .{ 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff }, 7);
    try testing.expectEqualStrings("ens5", c.name());
    try testing.expectEqual([6]u8{ 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff }, c.mac);
    try testing.expectEqual(@as(u32, 7), c.ifindex);
}

test "makeCandidate truncates long names" {
    const long_name = "this_is_a_very_long_interface_name";
    const c = makeCandidate(long_name, .{ 0, 0, 0, 0, 0, 0 }, 1);
    try testing.expectEqual(@as(u8, 16), c.name_len);
    try testing.expectEqualStrings("this_is_a_very_l", c.name());
}

test "DeviceNumberMap lookup" {
    var m: DeviceNumberMap = .{ .macs = undefined, .device_numbers = undefined, .len = 0 };
    const mac_a = [6]u8{ 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x01 };
    const mac_b = [6]u8{ 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x02 };
    const mac_c = [6]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff };

    m.macs[0] = macToString(mac_a);
    m.device_numbers[0] = 0;
    m.macs[1] = macToString(mac_b);
    m.device_numbers[1] = 1;
    m.len = 2;

    try testing.expectEqual(@as(?u32, 0), m.deviceNumberForMac(mac_a));
    try testing.expectEqual(@as(?u32, 1), m.deviceNumberForMac(mac_b));
    try testing.expectEqual(@as(?u32, null), m.deviceNumberForMac(mac_c));
}
