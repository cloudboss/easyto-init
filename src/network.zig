//! Network initialization for EC2 instances.
//!
//! This module handles network interface discovery, DHCP configuration,
//! and interface naming. It supports persistence across reboots.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

const aws_sdk = @import("aws_sdk");
const dhcpz = @import("dhcpz");
const nlz = @import("nlz");

const RetryBackoff = @import("backoff.zig").RetryBackoff;
const constants = @import("constants.zig");
const mkdir_p = @import("fs.zig").mkdir_p;

/// Information about a network interface.
pub const InterfaceInfo = struct {
    name: []const u8,
    mac: ?[6]u8,
    ifindex: u32,
    is_virtual: bool,

    pub fn getMacString(self: InterfaceInfo) ?[17]u8 {
        const mac = self.mac orelse return null;
        return macToString(mac);
    }
};

/// Per-interface address configuration from DHCP.
pub const AddressConfig = struct {
    address: [4]u8,
    prefix_len: u8,
    gateway: [4]u8,
};

/// DNS resolver configuration.
pub const ResolverConfig = struct {
    dns_servers: []const [4]u8,
    domain_name: ?[]const u8,
    search_list: []const []const u8,

    pub fn deinit(self: *ResolverConfig, allocator: Allocator) void {
        allocator.free(self.dns_servers);
        if (self.domain_name) |dn| allocator.free(dn);
        for (self.search_list) |s| allocator.free(s);
        allocator.free(self.search_list);
    }
};

/// Combined DHCP lease information.
pub const DhcpLease = struct {
    address: AddressConfig,
    resolver: ResolverConfig,

    pub fn deinit(self: *DhcpLease, allocator: Allocator) void {
        self.resolver.deinit(allocator);
    }
};

/// Interface naming family.
const IfFamily = union(enum) {
    simple: struct {
        prefix: []const u8,
        index: u32,
    },
    protected,
};

/// Persisted interface entry for JSON serialization.
const InterfaceEntry = struct {
    iface: []const u8,
    mac: ?[]const u8 = null,
    family: []const u8,
    index: ?u32 = null,
    primary: bool,
    present: bool,
    last_seen: []const u8,
    ip_address: ?[]const u8 = null,
    prefix_len: ?u8 = null,
    gateway: ?[]const u8 = null,
};

/// Persisted resolver configuration.
const PersistedResolverConfig = struct {
    dns_servers: []const []const u8 = &.{},
    domain_name: ?[]const u8 = null,
    search_list: []const []const u8 = &.{},
};

/// Persisted network state for JSON serialization.
const PersistedNetworkState = struct {
    interfaces: []const InterfaceEntry = &.{},
    resolver: ?PersistedResolverConfig = null,
};

/// Errors that can occur during network initialization.
pub const Error = error{
    NetworkInitFailed,
    DhcpFailed,
    NoCarrier,
    SocketError,
    NetlinkError,
    InvalidInterface,
    OutOfMemory,
    Timeout,
};

/// Initialize network interfaces with retry/backoff.
pub fn initializeNetwork(allocator: Allocator, imds_client: *aws_sdk.imds.ImdsClient) !void {
    const timeout_ns: u64 = 60 * std.time.ns_per_s;
    const start = std.time.nanoTimestamp();
    var backoff = RetryBackoff.init(2000);
    var last_error: ?anyerror = null;

    while (true) {
        initializeNetworkInner(allocator, imds_client) catch |err| {
            std.log.warn("network initialization attempt failed: {s}", .{@errorName(err)});
            last_error = err;
            const elapsed: u64 = @intCast(std.time.nanoTimestamp() - start);
            if (elapsed >= timeout_ns) {
                break;
            }
            backoff.wait();
            continue;
        };
        return;
    }

    if (last_error) |err| {
        return err;
    }
    return Error.NetworkInitFailed;
}

fn initializeNetworkInner(allocator: Allocator, imds_client: *aws_sdk.imds.ImdsClient) !void {
    var socket = nlz.Socket.open() catch {
        std.log.err("failed to create netlink socket", .{});
        return Error.NetlinkError;
    };
    defer socket.close();

    // Load persisted state if available
    var parsed_state = loadPersistedState(allocator);
    defer parsed_state.deinit();
    const persisted_state = parsed_state.value();

    // Get current interfaces
    var links = socket.getLinks(allocator) catch {
        std.log.err("failed to get network interfaces", .{});
        return Error.NetlinkError;
    };
    defer links.deinit();

    var interfaces: std.ArrayListUnmanaged(InterfaceInfo) = .empty;
    defer interfaces.deinit(allocator);

    while (links.next()) |link| {
        const name = link.name orelse continue;
        try interfaces.append(allocator, .{
            .name = name,
            .mac = link.getMacAddress(),
            .ifindex = link.ifindex(),
            .is_virtual = link.isVirtual(),
        });
    }

    // Ensure loopback is configured
    try ensureLoopback(&socket, interfaces.items, allocator);

    // Select and configure primary interface
    const select_result = try selectPrimaryInterface(
        &socket,
        imds_client,
        interfaces.items,
        &persisted_state,
        allocator,
    );
    const primary = select_result.primary;
    var bootstrap_lease = select_result.bootstrap_lease;

    // Apply primary naming (rename to eth0 if needed)
    const final_primary = try applyPrimaryNaming(
        &socket,
        interfaces.items,
        primary,
        &persisted_state,
        allocator,
    );

    // Configure DHCP on primary (or use persisted config if available)
    const dhcp_result = try configurePrimaryDhcp(
        &socket,
        primary,
        final_primary,
        bootstrap_lease,
        &persisted_state,
        allocator,
    );
    var dhcp_lease = dhcp_result.lease;
    defer dhcp_lease.deinit(allocator);

    // Free bootstrap lease only if we didn't reuse it
    if (bootstrap_lease) |*bl| {
        if (!dhcp_result.reused_bootstrap) {
            bl.deinit(allocator);
        }
    }

    // Re-enumerate interfaces after rename
    var final_links = socket.getLinks(allocator) catch {
        std.log.err("failed to get network interfaces after rename", .{});
        return Error.NetlinkError;
    };
    defer final_links.deinit();

    var final_interfaces: std.ArrayListUnmanaged(InterfaceInfo) = .empty;
    defer final_interfaces.deinit(allocator);

    while (final_links.next()) |link| {
        const name = link.name orelse continue;
        try final_interfaces.append(allocator, .{
            .name = name,
            .mac = link.getMacAddress(),
            .ifindex = link.ifindex(),
            .is_virtual = link.isVirtual(),
        });
    }

    // Persist interface state
    try persistInterfaces(allocator, final_interfaces.items, final_primary, &dhcp_lease);

    // Set hostname via IMDS
    setHostname(imds_client, allocator) catch |err| {
        std.log.warn("failed to set hostname: {s}", .{@errorName(err)});
    };
}

fn ensureLoopback(socket: *nlz.Socket, interfaces: []const InterfaceInfo, allocator: Allocator) !void {
    var lo_ifindex: ?u32 = null;
    for (interfaces) |iface| {
        if (std.mem.eql(u8, iface.name, "lo")) {
            lo_ifindex = iface.ifindex;
            break;
        }
    }

    const ifindex = lo_ifindex orelse return;

    // Bring up loopback
    socket.setLinkUp(ifindex, allocator) catch |err| {
        std.log.warn("failed to bring up loopback: {s}", .{@errorName(err)});
        return;
    };

    // Check existing addresses
    var have_v4 = false;
    var have_v6 = false;
    const lo_ipv4 = [4]u8{ 127, 0, 0, 1 };
    const lo_ipv6 = [16]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };

    var addrs = socket.getAddressesFiltered(nlz.AF.UNSPEC, ifindex, allocator) catch return;
    defer addrs.deinit();

    while (addrs.next()) |addr| {
        if (addr.address) |address| {
            if (addr.family() == nlz.AF.INET and address.len >= 4) {
                if (std.mem.eql(u8, address[0..4], &lo_ipv4)) {
                    have_v4 = true;
                }
            } else if (addr.family() == nlz.AF.INET6 and address.len >= 16) {
                if (std.mem.eql(u8, address[0..16], &lo_ipv6)) {
                    have_v6 = true;
                }
            }
        }
    }

    if (!have_v4) {
        std.log.info("adding loopback IPv4 127.0.0.1/8", .{});
        socket.addAddressIPv4(ifindex, lo_ipv4, 8, allocator) catch |err| {
            std.log.warn("failed to add loopback IPv4: {s}", .{@errorName(err)});
        };
    }

    if (!have_v6) {
        std.log.info("adding loopback IPv6 ::1/128", .{});
        socket.addAddressIPv6(ifindex, lo_ipv6, 128, allocator) catch |err| {
            std.log.warn("failed to add loopback IPv6: {s}", .{@errorName(err)});
        };
    }
}

const SelectPrimaryResult = struct {
    primary: InterfaceInfo,
    bootstrap_lease: ?DhcpLease,
    bootstrap_ifindex: ?u32,
};

fn selectPrimaryInterface(
    socket: *nlz.Socket,
    imds_client: *aws_sdk.imds.ImdsClient,
    interfaces: []const InterfaceInfo,
    persisted_state: *const PersistedNetworkState,
    allocator: Allocator,
) !SelectPrimaryResult {
    // Check for persisted primary first
    if (getPersistedPrimaryMac(persisted_state)) |persisted_mac| {
        for (interfaces) |iface| {
            if (iface.mac) |mac| {
                const mac_str = macToString(mac);
                if (std.mem.eql(u8, &mac_str, persisted_mac)) {
                    std.log.info("using persisted primary interface {s}", .{iface.name});
                    return .{ .primary = iface, .bootstrap_lease = null, .bootstrap_ifindex = null };
                }
            }
        }
    }

    // No persisted primary, bootstrap the first one found then verify against IMDS
    const bootstrap_result = try establishBootstrapConnectivity(socket, interfaces, allocator);
    const bootstrap_ifindex = bootstrap_result.ifindex;
    const bootstrap_lease = bootstrap_result.lease;

    // Discover primary MAC from IMDS
    const primary_mac = discoverPrimaryMacViaImds(imds_client, allocator) catch |err| {
        std.log.warn(
            "failed to discover primary MAC from IMDS: {s}, using bootstrap interface",
            .{@errorName(err)},
        );
        // Fall back to bootstrap interface
        for (interfaces) |iface| {
            if (iface.ifindex == bootstrap_ifindex) {
                return .{ .primary = iface, .bootstrap_lease = bootstrap_lease, .bootstrap_ifindex = bootstrap_ifindex };
            }
        }
        return Error.InvalidInterface;
    };
    defer allocator.free(primary_mac);

    // Find interface with primary MAC
    for (interfaces) |iface| {
        if (iface.mac) |mac| {
            const mac_str = macToString(mac);
            if (std.mem.eql(u8, &mac_str, primary_mac)) {
                std.log.info("using discovered primary interface {s}", .{iface.name});
                return .{ .primary = iface, .bootstrap_lease = bootstrap_lease, .bootstrap_ifindex = bootstrap_ifindex };
            }
        }
    }

    std.log.err("failed to find interface with primary MAC {s}", .{primary_mac});
    return Error.InvalidInterface;
}

fn discoverPrimaryMacViaImds(imds_client: *aws_sdk.imds.ImdsClient, allocator: Allocator) ![]const u8 {
    // Get list of MACs
    const macs_list = imds_client.get("/latest/meta-data/network/interfaces/macs/") catch |err| {
        std.log.err("failed to get MAC list from IMDS: {s}", .{@errorName(err)});
        return Error.NetworkInitFailed;
    };
    defer allocator.free(macs_list);

    // Parse and check each MAC for device-number 0
    var it = std.mem.splitScalar(u8, macs_list, '\n');
    while (it.next()) |line| {
        const mac = std.mem.trim(u8, line, " \t\r\n/");
        if (mac.len == 0) continue;

        // Query device number for this MAC
        var path_buf: [128]u8 = undefined;
        const path = std.fmt.bufPrint(
            &path_buf,
            "/latest/meta-data/network/interfaces/macs/{s}/device-number",
            .{mac},
        ) catch continue;

        const devnum = imds_client.get(path) catch continue;
        defer allocator.free(devnum);

        const trimmed = std.mem.trim(u8, devnum, " \t\r\n");
        if (std.mem.eql(u8, trimmed, "0")) {
            std.log.info("discovered primary MAC from IMDS: {s}", .{mac});
            return allocator.dupe(u8, mac) catch return Error.OutOfMemory;
        }
    }

    std.log.err("no interface found in IMDS with device number 0", .{});
    return Error.NetworkInitFailed;
}

const ConfigureDhcpResult = struct {
    lease: DhcpLease,
    reused_bootstrap: bool,
};

fn configurePrimaryDhcp(
    socket: *nlz.Socket,
    original_primary: InterfaceInfo,
    final_primary_name: []const u8,
    bootstrap_lease: ?DhcpLease,
    persisted_state: *const PersistedNetworkState,
    allocator: Allocator,
) !ConfigureDhcpResult {
    // Re-enumerate to get current state after potential rename
    var links = socket.getLinks(allocator) catch return Error.NetlinkError;
    defer links.deinit();

    var current_primary: ?InterfaceInfo = null;
    while (links.next()) |link| {
        const name = link.name orelse continue;
        if (std.mem.eql(u8, name, final_primary_name)) {
            current_primary = .{
                .name = name,
                .mac = link.getMacAddress(),
                .ifindex = link.ifindex(),
                .is_virtual = link.isVirtual(),
            };
            break;
        }
    }

    const primary = current_primary orelse {
        std.log.err("could not find primary interface after rename", .{});
        return Error.InvalidInterface;
    };

    // If bootstrap was on the same interface, reuse the lease
    if (bootstrap_lease) |lease| {
        if (original_primary.ifindex == primary.ifindex) {
            std.log.info("reusing bootstrap DHCP lease on primary", .{});
            return .{ .lease = lease, .reused_bootstrap = true };
        }
        // Bootstrap was on different interface, need to flush and reconfigure
        flushInterface(socket, original_primary.ifindex, allocator);
    } else {
        // No bootstrap (persisted primary) - check for persisted IP configuration
        if (getPersistedPrimaryConfig(persisted_state)) |persisted_config| {
            std.log.info("Using persisted IP configuration", .{});

            // Bring up interface
            socket.setLinkUp(primary.ifindex, allocator) catch |err| {
                std.log.err("failed to bring up primary interface: {s}", .{@errorName(err)});
                return Error.NetlinkError;
            };

            // Flush any existing addresses
            flushInterface(socket, primary.ifindex, allocator);

            // Apply persisted address
            const ip_addr = persisted_config.ip_address.?;
            const prefix_len = persisted_config.prefix_len.?;
            try applyPersistedConfig(
                socket,
                primary.ifindex,
                ip_addr,
                prefix_len,
                persisted_config.gateway,
                allocator,
            );

            // Write resolver config
            if (persisted_state.resolver) |resolver| {
                writeResolverConfig(resolver) catch |err| {
                    std.log.warn("failed to write resolver config: {s}", .{@errorName(err)});
                };
            }

            // Parse gateway if present
            const gw_bytes = if (persisted_config.gateway) |gw|
                parseIpv4Address(gw) catch [4]u8{ 0, 0, 0, 0 }
            else
                [4]u8{ 0, 0, 0, 0 };

            // Parse address
            const addr_bytes = parseIpv4Address(ip_addr) catch {
                std.log.err("invalid persisted IP address: {s}", .{ip_addr});
                return Error.NetworkInitFailed;
            };

            // Return a synthetic lease (resolver is empty since we wrote resolv.conf directly)
            return .{
                .lease = DhcpLease{
                    .address = AddressConfig{
                        .address = addr_bytes,
                        .prefix_len = prefix_len,
                        .gateway = gw_bytes,
                    },
                    .resolver = ResolverConfig{
                        .dns_servers = &.{},
                        .domain_name = null,
                        .search_list = &.{},
                    },
                },
                .reused_bootstrap = false,
            };
        }
    }

    // Bring up and configure primary
    socket.setLinkUp(primary.ifindex, allocator) catch |err| {
        std.log.err("failed to bring up primary interface: {s}", .{@errorName(err)});
        return Error.NetlinkError;
    };

    waitForCarrier(socket, primary.ifindex, 30 * std.time.ns_per_s, allocator) catch |err| {
        std.log.err("no carrier on primary interface: {s}", .{@errorName(err)});
        return err;
    };

    const mac = primary.mac orelse {
        std.log.err("primary interface has no MAC address", .{});
        return Error.InvalidInterface;
    };

    const lease = try runDhcpOnInterface(socket, primary.name, primary.ifindex, mac, allocator);
    return .{ .lease = lease, .reused_bootstrap = false };
}

fn flushInterface(socket: *nlz.Socket, ifindex: u32, allocator: Allocator) void {
    var addrs = socket.getAddressesFiltered(0, ifindex, allocator) catch return;
    defer addrs.deinit();

    while (addrs.next()) |addr| {
        socket.delAddress(addr, allocator) catch |err| {
            std.log.warn("failed to delete address on ifindex {}: {s}", .{ ifindex, @errorName(err) });
        };
    }
}

fn getPersistedPrimaryMac(state: *const PersistedNetworkState) ?[]const u8 {
    for (state.interfaces) |entry| {
        if (entry.primary) {
            return entry.mac;
        }
    }
    return null;
}

/// Get persisted IP configuration for the primary interface.
/// Returns the interface entry if it has a valid IP configuration.
fn getPersistedPrimaryConfig(state: *const PersistedNetworkState) ?InterfaceEntry {
    for (state.interfaces) |entry| {
        if (entry.primary and entry.ip_address != null and entry.prefix_len != null) {
            return entry;
        }
    }
    return null;
}

/// Apply persisted IP configuration to an interface.
fn applyPersistedConfig(
    socket: *nlz.Socket,
    ifindex: u32,
    ip_address: []const u8,
    prefix_len: u8,
    gateway: ?[]const u8,
    allocator: Allocator,
) !void {
    // Parse IP address into bytes
    const addr = parseIpv4Address(ip_address) catch |err| {
        std.log.err("failed to parse persisted IP address {s}: {s}", .{ ip_address, @errorName(err) });
        return Error.NetworkInitFailed;
    };

    // Add address to interface
    socket.addAddressIPv4(ifindex, addr, prefix_len, allocator) catch |err| {
        std.log.err("failed to add persisted address: {s}", .{@errorName(err)});
        return Error.NetlinkError;
    };

    // Add default route if gateway is specified
    if (gateway) |gw| {
        const gw_addr = parseIpv4Address(gw) catch |err| {
            std.log.err("failed to parse persisted gateway {s}: {s}", .{ gw, @errorName(err) });
            return Error.NetworkInitFailed;
        };

        socket.addRouteIPv4(ifindex, .{ 0, 0, 0, 0 }, gw_addr, 0, allocator) catch |err| {
            std.log.err("failed to add persisted default route: {s}", .{@errorName(err)});
            return Error.NetlinkError;
        };
    }
}

/// Parse an IPv4 address string into 4 bytes.
fn parseIpv4Address(ip_str: []const u8) ![4]u8 {
    var result: [4]u8 = undefined;
    var i: usize = 0;
    var it = std.mem.splitScalar(u8, ip_str, '.');
    while (it.next()) |octet_str| {
        if (i >= 4) return error.InvalidAddress;
        result[i] = std.fmt.parseInt(u8, octet_str, 10) catch return error.InvalidAddress;
        i += 1;
    }
    if (i != 4) return error.InvalidAddress;
    return result;
}

/// Write resolver configuration from persisted state.
fn writeResolverConfig(resolver: PersistedResolverConfig) !void {
    const file = std.fs.cwd().createFile("/etc/resolv.conf", .{}) catch |err| {
        std.log.err("failed to create /etc/resolv.conf: {s}", .{@errorName(err)});
        return err;
    };
    defer file.close();

    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    // Write domain
    if (resolver.domain_name) |domain| {
        writer.print("domain {s}\n", .{domain}) catch {};
    }

    // Write search list
    if (resolver.search_list.len > 0) {
        writer.writeAll("search") catch {};
        for (resolver.search_list) |domain| {
            writer.print(" {s}", .{domain}) catch {};
        }
        writer.writeAll("\n") catch {};
    }

    // Write nameservers
    for (resolver.dns_servers) |server| {
        writer.print("nameserver {s}\n", .{server}) catch {};
    }

    // Write buffer to file
    file.writeAll(fbs.getWritten()) catch |err| {
        std.log.err("failed to write resolv.conf: {s}", .{@errorName(err)});
        return err;
    };
}

fn establishBootstrapConnectivity(
    socket: *nlz.Socket,
    interfaces: []const InterfaceInfo,
    allocator: Allocator,
) !struct { ifindex: u32, lease: DhcpLease } {
    const ignored_prefixes = [_][]const u8{
        "lo",   "veth", "docker", "br",      "virbr",
        "vlan", "tun",  "tap",    "macvtap", "bond",
        "team", "wg",   "ppp",    "dummy",
    };

    std.log.info("found {} total interfaces for bootstrap evaluation", .{interfaces.len});

    // Filter and sort candidates
    var candidates: std.ArrayListUnmanaged(InterfaceInfo) = .empty;
    defer candidates.deinit(allocator);

    for (interfaces) |iface| {
        var is_ignored = false;
        for (ignored_prefixes) |prefix| {
            if (std.mem.startsWith(u8, iface.name, prefix)) {
                is_ignored = true;
                break;
            }
        }

        std.log.info("interface {s}: virtual={}, ignored={}", .{
            iface.name,
            iface.is_virtual,
            is_ignored,
        });

        if (!iface.is_virtual and !is_ignored) {
            try candidates.append(allocator, iface);
        }
    }

    std.log.info("found {} candidate interfaces for bootstrap", .{candidates.items.len});

    // Sort by ifindex (hoping first is primary)
    std.mem.sort(InterfaceInfo, candidates.items, {}, struct {
        fn lessThan(_: void, a: InterfaceInfo, b: InterfaceInfo) bool {
            return a.ifindex < b.ifindex;
        }
    }.lessThan);

    for (candidates.items) |iface| {
        std.log.info("attempting bootstrap connectivity on {s}", .{iface.name});

        // Bring interface up
        socket.setLinkUp(iface.ifindex, allocator) catch |err| {
            std.log.warn("failed to bring up {s}: {s}", .{ iface.name, @errorName(err) });
            continue;
        };

        // Wait for carrier
        waitForCarrier(socket, iface.ifindex, 30 * std.time.ns_per_s, allocator) catch |err| {
            std.log.warn("no carrier on {s}: {s}", .{ iface.name, @errorName(err) });
            continue;
        };

        // Try DHCP
        if (iface.mac) |mac| {
            if (runDhcpOnInterface(socket, iface.name, iface.ifindex, mac, allocator)) |lease| {
                std.log.info("bootstrap connectivity established on {s}", .{iface.name});
                return .{ .ifindex = iface.ifindex, .lease = lease };
            } else |_| {
                std.log.warn("DHCP failed on {s}", .{iface.name});
            }
        }
    }

    return Error.DhcpFailed;
}

fn waitForCarrier(
    socket: *nlz.Socket,
    ifindex: u32,
    timeout_ns: u64,
    allocator: Allocator,
) !void {
    const start = std.time.nanoTimestamp();
    var backoff = RetryBackoff.init(500);

    while (true) {
        var links = socket.getLinks(allocator) catch return Error.NetlinkError;
        defer links.deinit();

        while (links.next()) |link| {
            if (link.ifindex() == ifindex and link.hasCarrier()) {
                return;
            }
        }

        const elapsed: u64 = @intCast(std.time.nanoTimestamp() - start);
        if (elapsed >= timeout_ns) {
            return Error.NoCarrier;
        }
        backoff.wait();
    }
}

fn runDhcpOnInterface(
    socket: *nlz.Socket,
    interface: []const u8,
    ifindex: u32,
    mac: [6]u8,
    allocator: Allocator,
) !DhcpLease {
    const timeout_ns: u64 = 30 * std.time.ns_per_s;
    const start = std.time.nanoTimestamp();
    var backoff = RetryBackoff.init(5000);
    var last_error: ?anyerror = null;

    while (true) {
        if (attemptDhcpExchange(socket, interface, ifindex, mac, allocator)) |lease| {
            return lease;
        } else |err| {
            std.log.warn("DHCP attempt failed on {s}: {s}", .{ interface, @errorName(err) });
            last_error = err;
            const elapsed: u64 = @intCast(std.time.nanoTimestamp() - start);
            if (elapsed >= timeout_ns) {
                break;
            }
            backoff.wait();
        }
    }

    if (last_error) |err| {
        return err;
    }
    return Error.DhcpFailed;
}

fn attemptDhcpExchange(
    socket: *nlz.Socket,
    interface: []const u8,
    ifindex: u32,
    mac: [6]u8,
    allocator: Allocator,
) !DhcpLease {
    // Create raw UDP socket for DHCP
    const sock_fd = try createDhcpSocket(interface);
    defer posix.close(sock_fd);

    // Generate transaction ID
    var xid_bytes: [4]u8 = undefined;
    std.crypto.random.bytes(&xid_bytes);
    const xid = std.mem.bytesToValue(u32, &xid_bytes);

    // Send DHCPDISCOVER
    var discover = try dhcpz.v4.createDiscover(allocator, xid, mac);
    defer discover.deinit();

    var discover_buf: [1500]u8 = undefined;
    const discover_len = try discover.encode(&discover_buf);

    const broadcast_addr = posix.sockaddr.in{
        .family = posix.AF.INET,
        .port = std.mem.nativeToBig(u16, dhcpz.v4.SERVER_PORT),
        .addr = 0xFFFFFFFF, // 255.255.255.255
    };

    const sent = posix.sendto(
        sock_fd,
        discover_buf[0..discover_len],
        0,
        @ptrCast(&broadcast_addr),
        @sizeOf(posix.sockaddr.in),
    ) catch |err| {
        std.log.err("failed to send DHCPDISCOVER: {s}", .{@errorName(err)});
        return Error.SocketError;
    };
    std.log.info("sent DHCPDISCOVER ({} bytes) on {s}", .{ sent, interface });

    // Wait for DHCPOFFER
    var offer = try waitForDhcpMessage(sock_fd, xid, .offer, allocator);
    defer offer.deinit();

    const offered_ip = offer.yiaddr;
    const server_id = offer.options.get(.server_identifier) orelse {
        std.log.err("no server ID in DHCPOFFER", .{});
        return Error.DhcpFailed;
    };

    // Send DHCPREQUEST
    var request = try dhcpz.v4.createRequest(allocator, xid, mac, offered_ip, server_id);
    defer request.deinit();

    var request_buf: [1500]u8 = undefined;
    const request_len = try request.encode(&request_buf);

    _ = posix.sendto(
        sock_fd,
        request_buf[0..request_len],
        0,
        @ptrCast(&broadcast_addr),
        @sizeOf(posix.sockaddr.in),
    ) catch |err| {
        std.log.err("failed to send DHCPREQUEST: {s}", .{@errorName(err)});
        return Error.SocketError;
    };
    std.log.info("sent DHCPREQUEST on {s}", .{interface});

    // Wait for DHCPACK
    var ack = try waitForDhcpMessage(sock_fd, xid, .ack, allocator);
    defer ack.deinit();

    // Apply configuration
    return applyDhcpConfig(socket, ifindex, &ack, allocator);
}

fn createDhcpSocket(interface: []const u8) !posix.fd_t {
    const sock_fd = posix.socket(posix.AF.INET, posix.SOCK.DGRAM, posix.IPPROTO.UDP) catch {
        return Error.SocketError;
    };
    errdefer posix.close(sock_fd);

    // Set socket options
    const enable: c_int = 1;
    posix.setsockopt(sock_fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&enable)) catch {};
    posix.setsockopt(sock_fd, posix.SOL.SOCKET, posix.SO.BROADCAST, std.mem.asBytes(&enable)) catch {};

    // Bind to device
    var ifname_buf: [16]u8 = undefined;
    const ifname_len = @min(interface.len, 15);
    @memcpy(ifname_buf[0..ifname_len], interface[0..ifname_len]);
    ifname_buf[ifname_len] = 0;
    posix.setsockopt(sock_fd, posix.SOL.SOCKET, linux.SO.BINDTODEVICE, ifname_buf[0 .. ifname_len + 1]) catch |err| {
        std.log.err("failed to bind socket to {s}: {s}", .{ interface, @errorName(err) });
        return Error.SocketError;
    };

    // Bind to DHCP client port
    const bind_addr = posix.sockaddr.in{
        .family = posix.AF.INET,
        .port = std.mem.nativeToBig(u16, dhcpz.v4.CLIENT_PORT),
        .addr = 0, // INADDR_ANY
    };
    posix.bind(sock_fd, @ptrCast(&bind_addr), @sizeOf(posix.sockaddr.in)) catch |err| {
        std.log.err("failed to bind to port {}: {s}", .{ dhcpz.v4.CLIENT_PORT, @errorName(err) });
        return Error.SocketError;
    };

    // Set receive timeout
    const timeout = posix.timeval{
        .sec = 3,
        .usec = 0,
    };
    posix.setsockopt(sock_fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch {};

    return sock_fd;
}

fn waitForDhcpMessage(
    sock_fd: posix.fd_t,
    xid: u32,
    msg_type: dhcpz.v4.MessageType,
    allocator: Allocator,
) !dhcpz.v4.Message {
    const start = std.time.nanoTimestamp();
    const timeout_ns: u64 = 10 * std.time.ns_per_s;
    var backoff = RetryBackoff.init(1000);

    var buf: [1500]u8 = undefined;

    while (true) {
        const n = posix.recvfrom(sock_fd, &buf, 0, null, null) catch |err| {
            if (err == error.WouldBlock) {
                const elapsed: u64 = @intCast(std.time.nanoTimestamp() - start);
                if (elapsed >= timeout_ns) {
                    return Error.Timeout;
                }
                backoff.wait();
                continue;
            }
            return Error.SocketError;
        };

        if (n == 0) continue;

        var msg = dhcpz.v4.Message.decode(allocator, buf[0..n]) catch {
            continue;
        };

        if (msg.xid == xid) {
            if (msg.options.getMessageType()) |mt| {
                if (mt == msg_type) {
                    return msg;
                }
            }
        }
        msg.deinit();
    }
}

fn applyDhcpConfig(
    socket: *nlz.Socket,
    ifindex: u32,
    ack: *dhcpz.v4.Message,
    allocator: Allocator,
) !DhcpLease {
    const addr = ack.yiaddr;

    const subnet = ack.options.get(.subnet_mask) orelse {
        std.log.err("no subnet mask in DHCPACK", .{});
        return Error.DhcpFailed;
    };
    const prefix_len = subnetMaskToPrefix(subnet);

    const routers = ack.options.get(.router) orelse {
        std.log.err("no router in DHCPACK", .{});
        return Error.DhcpFailed;
    };
    if (routers.len == 0) {
        std.log.err("empty router list in DHCPACK", .{});
        return Error.DhcpFailed;
    }
    const gateway = routers[0];

    // Get DNS servers
    var dns_servers: []const [4]u8 = &.{};
    if (ack.options.get(.domain_name_server)) |servers| {
        dns_servers = try allocator.dupe([4]u8, servers);
    }
    errdefer if (dns_servers.len > 0) allocator.free(dns_servers);

    // Get domain name
    var domain_name: ?[]const u8 = null;
    if (ack.options.get(.domain_name)) |dn| {
        domain_name = try allocator.dupe(u8, dn);
    }
    errdefer if (domain_name) |dn| allocator.free(dn);

    // Get search list
    var search_list: []const []const u8 = &.{};
    if (ack.options.get(.domain_search)) |sl| {
        var list: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer {
            for (list.items) |s| allocator.free(s);
            list.deinit(allocator);
        }
        for (sl) |s| {
            try list.append(allocator, try allocator.dupe(u8, s));
        }
        search_list = try list.toOwnedSlice(allocator);
    }
    errdefer {
        for (search_list) |s| allocator.free(s);
        if (search_list.len > 0) allocator.free(search_list);
    }

    const address_config = AddressConfig{
        .address = addr,
        .prefix_len = prefix_len,
        .gateway = gateway,
    };
    const resolver_config = ResolverConfig{
        .dns_servers = dns_servers,
        .domain_name = domain_name,
        .search_list = search_list,
    };

    // Apply address and route
    try configureAddressAndRoute(socket, ifindex, &address_config, allocator);

    // Write resolv.conf
    if (dns_servers.len > 0) {
        try writeResolvConf(&resolver_config);
    }

    return DhcpLease{
        .address = address_config,
        .resolver = resolver_config,
    };
}

fn configureAddressAndRoute(
    socket: *nlz.Socket,
    ifindex: u32,
    config: *const AddressConfig,
    allocator: Allocator,
) !void {
    socket.addAddressIPv4(ifindex, config.address, config.prefix_len, allocator) catch |err| {
        std.log.err("failed to add IP address: {s}", .{@errorName(err)});
        return Error.NetlinkError;
    };

    socket.addRouteIPv4(ifindex, .{ 0, 0, 0, 0 }, config.gateway, 0, allocator) catch |err| {
        std.log.err("failed to add default route: {s}", .{@errorName(err)});
        return Error.NetlinkError;
    };
}

fn writeResolvConf(config: *const ResolverConfig) !void {
    const file = std.fs.cwd().createFile(constants.FILE_ETC_RESOLV_CONF, .{}) catch |err| {
        std.log.err("failed to create {s}: {s}", .{ constants.FILE_ETC_RESOLV_CONF, @errorName(err) });
        return err;
    };
    defer file.close();

    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    if (config.domain_name) |dn| {
        writer.print("domain {s}\n", .{dn}) catch {};
    }

    if (config.search_list.len > 0) {
        writer.writeAll("search") catch {};
        for (config.search_list) |s| {
            writer.print(" {s}", .{s}) catch {};
        }
        writer.writeAll("\n") catch {};
    }

    for (config.dns_servers) |server| {
        writer.print("nameserver {}.{}.{}.{}\n", .{ server[0], server[1], server[2], server[3] }) catch {};
    }

    file.writeAll(fbs.getWritten()) catch |err| {
        std.log.err("failed to write {s}: {s}", .{ constants.FILE_ETC_RESOLV_CONF, @errorName(err) });
        return err;
    };
}

fn applyPrimaryNaming(
    socket: *nlz.Socket,
    interfaces: []const InterfaceInfo,
    primary: InterfaceInfo,
    persisted_state: *const PersistedNetworkState,
    allocator: Allocator,
) ![]const u8 {
    const desired = desiredNameForPrimary(primary.name) orelse return primary.name;

    if (std.mem.eql(u8, desired, primary.name)) {
        return primary.name;
    }

    // Get family max indices from persisted state
    var family_max_indices = std.StringHashMap(u32).init(allocator);
    defer family_max_indices.deinit();

    for (persisted_state.interfaces) |iface| {
        if (!std.mem.eql(u8, iface.family, "protected") and iface.family.len > 0) {
            if (iface.index) |i| {
                const entry = try family_max_indices.getOrPut(iface.family);
                if (!entry.found_existing or i > entry.value_ptr.*) {
                    entry.value_ptr.* = i;
                }
            }
        }
    }

    try renameInterfaceCollision(
        socket,
        interfaces,
        primary.ifindex,
        desired,
        &family_max_indices,
        allocator,
    );

    return desired;
}

fn renameInterfaceCollision(
    socket: *nlz.Socket,
    interfaces: []const InterfaceInfo,
    primary_index: u32,
    desired: []const u8,
    family_max_indices: *std.StringHashMap(u32),
    allocator: Allocator,
) !void {
    // Check if desired name is in use
    var existing: ?InterfaceInfo = null;
    for (interfaces) |iface| {
        if (std.mem.eql(u8, iface.name, desired)) {
            existing = iface;
            break;
        }
    }

    if (existing) |ex| {
        if (ex.ifindex == primary_index) {
            return; // Already named correctly
        }

        // Collision: move existing interface first
        const family = parseFamily(desired);
        switch (family) {
            .simple => |s| {
                const next_idx = nextFamilyIndex(interfaces, s.prefix, family_max_indices);
                var new_name_buf: [32]u8 = undefined;
                const new_name = std.fmt.bufPrint(
                    &new_name_buf,
                    "{s}{}",
                    .{ s.prefix, next_idx },
                ) catch return Error.InvalidInterface;

                socket.setLinkName(ex.ifindex, new_name, allocator) catch |err| {
                    std.log.err("failed to rename interface: {s}", .{@errorName(err)});
                    return Error.NetlinkError;
                };
            },
            .protected => {
                std.log.err("attempted to rename protected interface {s}", .{desired});
                return Error.InvalidInterface;
            },
        }
    }

    // Now rename primary to desired
    socket.setLinkName(primary_index, desired, allocator) catch |err| {
        std.log.err("failed to rename interface to {s}: {s}", .{ desired, @errorName(err) });
        return Error.NetlinkError;
    };
}

fn nextFamilyIndex(
    interfaces: []const InterfaceInfo,
    prefix: []const u8,
    family_max_indices: *std.StringHashMap(u32),
) u32 {
    var max_idx: u32 = 0;

    for (interfaces) |iface| {
        if (std.mem.startsWith(u8, iface.name, prefix)) {
            const rest = iface.name[prefix.len..];
            if (std.fmt.parseInt(u32, rest, 10)) |n| {
                if (n > max_idx) max_idx = n;
            } else |_| {}
        }
    }

    if (family_max_indices.get(prefix)) |i| {
        if (i > max_idx) max_idx = i;
    }

    return max_idx +| 1;
}

fn setHostname(imds_client: *aws_sdk.imds.ImdsClient, allocator: Allocator) !void {
    const hostname = imds_client.get("/latest/meta-data/local-hostname") catch |err| {
        std.log.err("failed to get hostname from IMDS: {s}", .{@errorName(err)});
        return Error.NetworkInitFailed;
    };
    defer allocator.free(hostname);

    const trimmed = std.mem.trim(u8, hostname, " \t\r\n");
    if (trimmed.len == 0) {
        std.log.warn("IMDS returned empty hostname", .{});
        return;
    }

    std.log.info("setting hostname to: {s}", .{trimmed});

    // Use sethostname syscall
    const result = linux.syscall2(.sethostname, @intFromPtr(trimmed.ptr), trimmed.len);
    const e = posix.errno(result);
    if (e != .SUCCESS) {
        std.log.err("sethostname syscall failed: {}", .{e});
        return Error.NetworkInitFailed;
    }
}

/// Intermediate structure for building persisted entries with owned string buffers.
const PersistedEntryBuilder = struct {
    ip_buf: [16]u8 = undefined,
    ip_len: u8 = 0,
    gw_buf: [16]u8 = undefined,
    gw_len: u8 = 0,
    mac_buf: [17]u8 = undefined,
    has_mac: bool = false,

    fn getIpStr(self: *const PersistedEntryBuilder) ?[]const u8 {
        if (self.ip_len == 0) return null;
        return self.ip_buf[0..self.ip_len];
    }

    fn getGwStr(self: *const PersistedEntryBuilder) ?[]const u8 {
        if (self.gw_len == 0) return null;
        return self.gw_buf[0..self.gw_len];
    }

    fn getMacStr(self: *const PersistedEntryBuilder) ?[]const u8 {
        if (!self.has_mac) return null;
        return &self.mac_buf;
    }
};

fn persistInterfaces(
    allocator: Allocator,
    interfaces: []const InterfaceInfo,
    primary_name: []const u8,
    dhcp_lease: *const DhcpLease,
) !void {
    // Create timestamp
    var timestamp_buf: [32]u8 = undefined;
    const now = std.time.timestamp();
    const timestamp = std.fmt.bufPrint(&timestamp_buf, "{}", .{now}) catch "0";

    // Build entries with owned buffers to avoid lifetime issues
    var builders = try allocator.alloc(PersistedEntryBuilder, interfaces.len);
    defer allocator.free(builders);

    // Initialize all builders to default values (alloc returns uninitialized memory)
    for (builders) |*builder| {
        builder.* = PersistedEntryBuilder{};
    }

    var entries: std.ArrayListUnmanaged(InterfaceEntry) = .empty;
    defer entries.deinit(allocator);

    for (interfaces, 0..) |iface, idx| {
        const family_info_result = familyInfo(iface.name);
        const is_primary = std.mem.eql(u8, iface.name, primary_name);
        var builder = &builders[idx];

        if (is_primary) {
            const ip_result = std.fmt.bufPrint(&builder.ip_buf, "{}.{}.{}.{}", .{
                dhcp_lease.address.address[0],
                dhcp_lease.address.address[1],
                dhcp_lease.address.address[2],
                dhcp_lease.address.address[3],
            });
            if (ip_result) |ip_slice| {
                builder.ip_len = @intCast(ip_slice.len);
            } else |_| {}

            const gw_result = std.fmt.bufPrint(&builder.gw_buf, "{}.{}.{}.{}", .{
                dhcp_lease.address.gateway[0],
                dhcp_lease.address.gateway[1],
                dhcp_lease.address.gateway[2],
                dhcp_lease.address.gateway[3],
            });
            if (gw_result) |gw_slice| {
                builder.gw_len = @intCast(gw_slice.len);
            } else |_| {}
        }

        if (iface.mac) |mac| {
            const mac_formatted = macToString(mac);
            @memcpy(&builder.mac_buf, &mac_formatted);
            builder.has_mac = true;
        }

        try entries.append(allocator, .{
            .iface = iface.name,
            .mac = builder.getMacStr(),
            .family = family_info_result.family,
            .index = family_info_result.index,
            .primary = is_primary,
            .present = true,
            .last_seen = timestamp,
            .ip_address = builder.getIpStr(),
            .prefix_len = if (is_primary) dhcp_lease.address.prefix_len else null,
            .gateway = builder.getGwStr(),
        });
    }

    // Build resolver config - use fixed buffers for DNS server strings
    var dns_bufs: [8][16]u8 = undefined;
    var dns_strs: [8][]const u8 = undefined;
    var dns_count: usize = 0;

    for (dhcp_lease.resolver.dns_servers) |server| {
        if (dns_count >= 8) break;
        const result = std.fmt.bufPrint(&dns_bufs[dns_count], "{}.{}.{}.{}", .{
            server[0], server[1], server[2], server[3],
        });
        if (result) |s| {
            dns_strs[dns_count] = s;
            dns_count += 1;
        } else |_| {}
    }

    const resolver_config = PersistedResolverConfig{
        .dns_servers = dns_strs[0..dns_count],
        .domain_name = dhcp_lease.resolver.domain_name,
        .search_list = dhcp_lease.resolver.search_list,
    };

    const state = PersistedNetworkState{
        .interfaces = entries.items,
        .resolver = resolver_config,
    };

    // Create directory
    mkdir_p(constants.DIR_ET_VAR_LIB, 0o755) catch |err| {
        std.log.err("failed to create {s}: {s}", .{ constants.DIR_ET_VAR_LIB, @errorName(err) });
        return err;
    };

    // Write JSON file
    const path = constants.DIR_ET_VAR_LIB ++ "/" ++ constants.FILE_NETWORK_JSON;
    const file = std.fs.cwd().createFile(path, .{}) catch |err| {
        std.log.err("failed to create {s}: {s}", .{ path, @errorName(err) });
        return err;
    };
    defer file.close();

    // Write JSON to fixed buffer then to file
    var buf: [16384]u8 = undefined;
    var writer = std.io.Writer.fixed(&buf);
    var json_stream = std.json.Stringify{
        .writer = &writer,
        .options = .{ .whitespace = .indent_2 },
    };
    json_stream.write(state) catch |err| {
        std.log.err("failed to serialize network state: {s}", .{@errorName(err)});
        return err;
    };
    file.writeAll(buf[0..writer.end]) catch |err| {
        std.log.err("failed to write {s}: {s}", .{ path, @errorName(err) });
        return err;
    };
}

const ParsedNetworkState = struct {
    parsed: ?std.json.Parsed(PersistedNetworkState),
    contents: ?[]const u8,
    allocator: Allocator,

    pub fn value(self: *const ParsedNetworkState) PersistedNetworkState {
        if (self.parsed) |p| {
            return p.value;
        }
        return PersistedNetworkState{};
    }

    pub fn deinit(self: *ParsedNetworkState) void {
        if (self.parsed) |p| {
            p.deinit();
            self.parsed = null;
        }
        if (self.contents) |c| {
            self.allocator.free(c);
            self.contents = null;
        }
    }
};

fn loadPersistedState(allocator: Allocator) ParsedNetworkState {
    const path = constants.DIR_ET_VAR_LIB ++ "/" ++ constants.FILE_NETWORK_JSON;

    const contents = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch {
        return ParsedNetworkState{ .parsed = null, .contents = null, .allocator = allocator };
    };

    const parsed = std.json.parseFromSlice(PersistedNetworkState, allocator, contents, .{
        .ignore_unknown_fields = true,
    }) catch {
        allocator.free(contents);
        return ParsedNetworkState{ .parsed = null, .contents = null, .allocator = allocator };
    };

    return ParsedNetworkState{ .parsed = parsed, .contents = contents, .allocator = allocator };
}

fn parseFamily(name: []const u8) IfFamily {
    // Find where digits start
    var i = name.len;
    while (i > 0 and std.ascii.isDigit(name[i - 1])) {
        i -= 1;
    }

    if (i == name.len) {
        return .protected;
    }

    const prefix = name[0..i];
    const suffix = name[i..];

    // Check prefix is all alphabetic
    for (prefix) |c| {
        if (!std.ascii.isAlphabetic(c)) {
            return .protected;
        }
    }

    const index = std.fmt.parseInt(u32, suffix, 10) catch {
        return .protected;
    };

    return .{ .simple = .{ .prefix = prefix, .index = index } };
}

fn desiredNameForPrimary(current: []const u8) ?[]const u8 {
    const family = parseFamily(current);
    return switch (family) {
        .simple => |s| blk: {
            // eth5 -> eth0
            if (std.mem.eql(u8, s.prefix, "eth")) {
                break :blk "eth0";
            }
            // For other families, no renaming
            break :blk null;
        },
        .protected => null,
    };
}

fn familyInfo(name: []const u8) struct { family: []const u8, index: ?u32 } {
    const family = parseFamily(name);
    return switch (family) {
        .simple => |s| .{ .family = s.prefix, .index = s.index },
        .protected => .{ .family = "protected", .index = null },
    };
}

pub fn macToString(mac: [6]u8) [17]u8 {
    const hex = "0123456789abcdef";
    var result: [17]u8 = undefined;

    for (mac, 0..) |byte, i| {
        const offset = i * 3;
        result[offset] = hex[byte >> 4];
        result[offset + 1] = hex[byte & 0x0f];
        if (i < 5) {
            result[offset + 2] = ':';
        }
    }

    return result;
}

fn subnetMaskToPrefix(mask: [4]u8) u8 {
    const m: u32 = (@as(u32, mask[0]) << 24) |
        (@as(u32, mask[1]) << 16) |
        (@as(u32, mask[2]) << 8) |
        mask[3];
    return @popCount(m);
}

test "macToString" {
    const mac = [6]u8{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55 };
    const result = macToString(mac);
    try std.testing.expectEqualStrings("00:11:22:33:44:55", &result);
}

test "macToString all ff" {
    const mac = [6]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff };
    const result = macToString(mac);
    try std.testing.expectEqualStrings("ff:ff:ff:ff:ff:ff", &result);
}

test "subnetMaskToPrefix 24" {
    try std.testing.expectEqual(@as(u8, 24), subnetMaskToPrefix(.{ 255, 255, 255, 0 }));
}

test "subnetMaskToPrefix 16" {
    try std.testing.expectEqual(@as(u8, 16), subnetMaskToPrefix(.{ 255, 255, 0, 0 }));
}

test "subnetMaskToPrefix 8" {
    try std.testing.expectEqual(@as(u8, 8), subnetMaskToPrefix(.{ 255, 0, 0, 0 }));
}

test "subnetMaskToPrefix 32" {
    try std.testing.expectEqual(@as(u8, 32), subnetMaskToPrefix(.{ 255, 255, 255, 255 }));
}

test "parseFamily simple eth0" {
    const family = parseFamily("eth0");
    switch (family) {
        .simple => |s| {
            try std.testing.expectEqualStrings("eth", s.prefix);
            try std.testing.expectEqual(@as(u32, 0), s.index);
        },
        .protected => try std.testing.expect(false),
    }
}

test "parseFamily simple eth123" {
    const family = parseFamily("eth123");
    switch (family) {
        .simple => |s| {
            try std.testing.expectEqualStrings("eth", s.prefix);
            try std.testing.expectEqual(@as(u32, 123), s.index);
        },
        .protected => try std.testing.expect(false),
    }
}

test "parseFamily protected lo" {
    const family = parseFamily("lo");
    switch (family) {
        .simple => try std.testing.expect(false),
        .protected => {},
    }
}

test "parseFamily protected docker0bridge" {
    const family = parseFamily("docker0bridge");
    switch (family) {
        .simple => try std.testing.expect(false),
        .protected => {},
    }
}

test "desiredNameForPrimary eth5" {
    const desired = desiredNameForPrimary("eth5");
    try std.testing.expectEqualStrings("eth0", desired.?);
}

test "desiredNameForPrimary eth0" {
    const desired = desiredNameForPrimary("eth0");
    try std.testing.expectEqualStrings("eth0", desired.?);
}

test "desiredNameForPrimary lo" {
    const desired = desiredNameForPrimary("lo");
    try std.testing.expect(desired == null);
}

test "familyInfo eth0" {
    const info = familyInfo("eth0");
    try std.testing.expectEqualStrings("eth", info.family);
    try std.testing.expectEqual(@as(?u32, 0), info.index);
}

test "familyInfo lo" {
    const info = familyInfo("lo");
    try std.testing.expectEqualStrings("protected", info.family);
    try std.testing.expect(info.index == null);
}

// Additional tests for parseIpv4Address
test "parseIpv4Address valid" {
    const addr = try parseIpv4Address("192.168.1.1");
    try std.testing.expectEqual([4]u8{ 192, 168, 1, 1 }, addr);
}

test "parseIpv4Address zeros" {
    const addr = try parseIpv4Address("0.0.0.0");
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, addr);
}

test "parseIpv4Address max values" {
    const addr = try parseIpv4Address("255.255.255.255");
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, addr);
}

test "parseIpv4Address too few octets" {
    try std.testing.expectError(error.InvalidAddress, parseIpv4Address("192.168.1"));
}

test "parseIpv4Address too many octets" {
    try std.testing.expectError(error.InvalidAddress, parseIpv4Address("192.168.1.1.1"));
}

test "parseIpv4Address non-numeric" {
    try std.testing.expectError(error.InvalidAddress, parseIpv4Address("192.168.a.1"));
}

test "parseIpv4Address out of range" {
    try std.testing.expectError(error.InvalidAddress, parseIpv4Address("192.168.256.1"));
}

test "parseIpv4Address empty" {
    try std.testing.expectError(error.InvalidAddress, parseIpv4Address(""));
}

test "parseIpv4Address single octet" {
    try std.testing.expectError(error.InvalidAddress, parseIpv4Address("192"));
}

// Additional tests for macToString
test "macToString all zeros" {
    const mac = [6]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    const result = macToString(mac);
    try std.testing.expectEqualStrings("00:00:00:00:00:00", &result);
}

test "macToString mixed case hex" {
    const mac = [6]u8{ 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f };
    const result = macToString(mac);
    try std.testing.expectEqualStrings("0a:0b:0c:0d:0e:0f", &result);
}

// Additional tests for subnetMaskToPrefix
test "subnetMaskToPrefix zero" {
    try std.testing.expectEqual(@as(u8, 0), subnetMaskToPrefix(.{ 0, 0, 0, 0 }));
}

test "subnetMaskToPrefix 28" {
    try std.testing.expectEqual(@as(u8, 28), subnetMaskToPrefix(.{ 255, 255, 255, 240 }));
}

test "subnetMaskToPrefix 20" {
    try std.testing.expectEqual(@as(u8, 20), subnetMaskToPrefix(.{ 255, 255, 240, 0 }));
}

// Tests for InterfaceInfo.getMacString
test "InterfaceInfo.getMacString with valid MAC" {
    const info = InterfaceInfo{
        .name = "eth0",
        .mac = [6]u8{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55 },
        .ifindex = 1,
        .is_virtual = false,
    };
    const result = info.getMacString();
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("00:11:22:33:44:55", &result.?);
}

test "InterfaceInfo.getMacString with null MAC" {
    const info = InterfaceInfo{
        .name = "lo",
        .mac = null,
        .ifindex = 1,
        .is_virtual = false,
    };
    const result = info.getMacString();
    try std.testing.expect(result == null);
}

// Tests for ResolverConfig.deinit
test "ResolverConfig.deinit frees memory" {
    const allocator = std.testing.allocator;

    var dns_servers = try allocator.alloc([4]u8, 2);
    dns_servers[0] = [4]u8{ 8, 8, 8, 8 };
    dns_servers[1] = [4]u8{ 8, 8, 4, 4 };

    const domain = try allocator.dupe(u8, "example.com");

    var search_list = try allocator.alloc([]const u8, 2);
    search_list[0] = try allocator.dupe(u8, "example.com");
    search_list[1] = try allocator.dupe(u8, "test.com");

    var config = ResolverConfig{
        .dns_servers = dns_servers,
        .domain_name = domain,
        .search_list = search_list,
    };

    config.deinit(allocator);
}

test "ResolverConfig.deinit with empty fields" {
    const allocator = std.testing.allocator;

    var config = ResolverConfig{
        .dns_servers = &.{},
        .domain_name = null,
        .search_list = &.{},
    };

    config.deinit(allocator);
}

// Tests for DhcpLease.deinit
test "DhcpLease.deinit frees resolver" {
    const allocator = std.testing.allocator;

    var dns_servers = try allocator.alloc([4]u8, 1);
    dns_servers[0] = [4]u8{ 8, 8, 8, 8 };

    var lease = DhcpLease{
        .address = AddressConfig{
            .address = [4]u8{ 10, 0, 0, 1 },
            .prefix_len = 24,
            .gateway = [4]u8{ 10, 0, 0, 254 },
        },
        .resolver = ResolverConfig{
            .dns_servers = dns_servers,
            .domain_name = null,
            .search_list = &.{},
        },
    };

    lease.deinit(allocator);
}

// Tests for getPersistedPrimaryMac
test "getPersistedPrimaryMac with primary" {
    const state = PersistedNetworkState{
        .interfaces = &.{
            InterfaceEntry{
                .iface = "eth0",
                .mac = "00:11:22:33:44:55",
                .family = "eth",
                .index = 0,
                .primary = true,
                .present = true,
                .last_seen = "0",
            },
        },
        .resolver = null,
    };
    const mac = getPersistedPrimaryMac(&state);
    try std.testing.expect(mac != null);
    try std.testing.expectEqualStrings("00:11:22:33:44:55", mac.?);
}

test "getPersistedPrimaryMac without primary" {
    const state = PersistedNetworkState{
        .interfaces = &.{
            InterfaceEntry{
                .iface = "eth0",
                .mac = "00:11:22:33:44:55",
                .family = "eth",
                .index = 0,
                .primary = false,
                .present = true,
                .last_seen = "0",
            },
        },
        .resolver = null,
    };
    const mac = getPersistedPrimaryMac(&state);
    try std.testing.expect(mac == null);
}

test "getPersistedPrimaryMac with primary but null MAC" {
    const state = PersistedNetworkState{
        .interfaces = &.{
            InterfaceEntry{
                .iface = "lo",
                .mac = null,
                .family = "protected",
                .index = null,
                .primary = true,
                .present = true,
                .last_seen = "0",
            },
        },
        .resolver = null,
    };
    const mac = getPersistedPrimaryMac(&state);
    try std.testing.expect(mac == null);
}

test "getPersistedPrimaryMac with empty interfaces" {
    const state = PersistedNetworkState{
        .interfaces = &.{},
        .resolver = null,
    };
    const mac = getPersistedPrimaryMac(&state);
    try std.testing.expect(mac == null);
}

// Tests for getPersistedPrimaryConfig
test "getPersistedPrimaryConfig with complete config" {
    const state = PersistedNetworkState{
        .interfaces = &.{
            InterfaceEntry{
                .iface = "eth0",
                .mac = "00:11:22:33:44:55",
                .family = "eth",
                .index = 0,
                .primary = true,
                .present = true,
                .last_seen = "0",
                .ip_address = "10.0.0.1",
                .prefix_len = 24,
                .gateway = "10.0.0.254",
            },
        },
        .resolver = null,
    };
    const config = getPersistedPrimaryConfig(&state);
    try std.testing.expect(config != null);
    try std.testing.expectEqualStrings("10.0.0.1", config.?.ip_address.?);
    try std.testing.expectEqual(@as(u8, 24), config.?.prefix_len.?);
    try std.testing.expectEqualStrings("10.0.0.254", config.?.gateway.?);
}

test "getPersistedPrimaryConfig with missing ip_address" {
    const state = PersistedNetworkState{
        .interfaces = &.{
            InterfaceEntry{
                .iface = "eth0",
                .mac = "00:11:22:33:44:55",
                .family = "eth",
                .index = 0,
                .primary = true,
                .present = true,
                .last_seen = "0",
                .ip_address = null,
                .prefix_len = 24,
                .gateway = "10.0.0.254",
            },
        },
        .resolver = null,
    };
    const config = getPersistedPrimaryConfig(&state);
    try std.testing.expect(config == null);
}

test "getPersistedPrimaryConfig with missing prefix_len" {
    const state = PersistedNetworkState{
        .interfaces = &.{
            InterfaceEntry{
                .iface = "eth0",
                .mac = "00:11:22:33:44:55",
                .family = "eth",
                .index = 0,
                .primary = true,
                .present = true,
                .last_seen = "0",
                .ip_address = "10.0.0.1",
                .prefix_len = null,
                .gateway = "10.0.0.254",
            },
        },
        .resolver = null,
    };
    const config = getPersistedPrimaryConfig(&state);
    try std.testing.expect(config == null);
}

test "getPersistedPrimaryConfig with no primary" {
    const state = PersistedNetworkState{
        .interfaces = &.{
            InterfaceEntry{
                .iface = "eth0",
                .mac = "00:11:22:33:44:55",
                .family = "eth",
                .index = 0,
                .primary = false,
                .present = true,
                .last_seen = "0",
                .ip_address = "10.0.0.1",
                .prefix_len = 24,
                .gateway = "10.0.0.254",
            },
        },
        .resolver = null,
    };
    const config = getPersistedPrimaryConfig(&state);
    try std.testing.expect(config == null);
}

// Tests for nextFamilyIndex
test "nextFamilyIndex with empty interfaces" {
    var map = std.StringHashMap(u32).init(std.testing.allocator);
    defer map.deinit();
    const interfaces: []const InterfaceInfo = &.{};
    const next = nextFamilyIndex(interfaces, "eth", &map);
    try std.testing.expectEqual(@as(u32, 1), next);
}

test "nextFamilyIndex with existing interfaces" {
    var map = std.StringHashMap(u32).init(std.testing.allocator);
    defer map.deinit();
    const interfaces: []const InterfaceInfo = &.{
        InterfaceInfo{ .name = "eth0", .mac = null, .ifindex = 1, .is_virtual = false },
        InterfaceInfo{ .name = "eth2", .mac = null, .ifindex = 3, .is_virtual = false },
    };
    const next = nextFamilyIndex(interfaces, "eth", &map);
    try std.testing.expectEqual(@as(u32, 3), next);
}

test "nextFamilyIndex with persisted max higher" {
    var map = std.StringHashMap(u32).init(std.testing.allocator);
    defer map.deinit();
    try map.put("eth", 5);
    const interfaces: []const InterfaceInfo = &.{
        InterfaceInfo{ .name = "eth0", .mac = null, .ifindex = 1, .is_virtual = false },
    };
    const next = nextFamilyIndex(interfaces, "eth", &map);
    try std.testing.expectEqual(@as(u32, 6), next);
}

test "nextFamilyIndex with persisted max lower" {
    var map = std.StringHashMap(u32).init(std.testing.allocator);
    defer map.deinit();
    try map.put("eth", 1);
    const interfaces: []const InterfaceInfo = &.{
        InterfaceInfo{ .name = "eth5", .mac = null, .ifindex = 6, .is_virtual = false },
    };
    const next = nextFamilyIndex(interfaces, "eth", &map);
    try std.testing.expectEqual(@as(u32, 6), next);
}

test "nextFamilyIndex ignores interfaces with different prefix" {
    var map = std.StringHashMap(u32).init(std.testing.allocator);
    defer map.deinit();
    const interfaces: []const InterfaceInfo = &.{
        InterfaceInfo{ .name = "eth5", .mac = null, .ifindex = 6, .is_virtual = false },
    };
    // eth5 should not affect ens family; with no ens interfaces, max is 0
    const next = nextFamilyIndex(interfaces, "ens", &map);
    const max: u32 = 0;
    try std.testing.expectEqual(max + 1, next);
}

// Tests for parseFamily edge cases
test "parseFamily ens5" {
    const family = parseFamily("ens5");
    switch (family) {
        .simple => |s| {
            try std.testing.expectEqualStrings("ens", s.prefix);
            try std.testing.expectEqual(@as(u32, 5), s.index);
        },
        .protected => try std.testing.expect(false),
    }
}

test "parseFamily empty string" {
    const family = parseFamily("");
    switch (family) {
        .simple => try std.testing.expect(false),
        .protected => {},
    }
}

test "parseFamily digits only" {
    const family = parseFamily("123");
    switch (family) {
        .simple => |s| {
            try std.testing.expectEqualStrings("", s.prefix);
            try std.testing.expectEqual(@as(u32, 123), s.index);
        },
        .protected => try std.testing.expect(false),
    }
}

// Tests for desiredNameForPrimary edge cases
test "desiredNameForPrimary ens5" {
    const desired = desiredNameForPrimary("ens5");
    try std.testing.expect(desired == null);
}

// Tests for familyInfo edge cases
test "familyInfo ens5" {
    const info = familyInfo("ens5");
    try std.testing.expectEqualStrings("ens", info.family);
    try std.testing.expectEqual(@as(?u32, 5), info.index);
}

test "familyInfo empty string" {
    const info = familyInfo("");
    try std.testing.expectEqualStrings("protected", info.family);
    try std.testing.expect(info.index == null);
}

// Tests for ParsedNetworkState
test "ParsedNetworkState.value with null parsed" {
    const state = ParsedNetworkState{
        .parsed = null,
        .contents = null,
        .allocator = std.testing.allocator,
    };
    const value = state.value();
    try std.testing.expectEqual(@as(usize, 0), value.interfaces.len);
    try std.testing.expect(value.resolver == null);
}

test "ParsedNetworkState.deinit with null" {
    var state = ParsedNetworkState{
        .parsed = null,
        .contents = null,
        .allocator = std.testing.allocator,
    };
    state.deinit();
    try std.testing.expect(state.parsed == null);
    try std.testing.expect(state.contents == null);
}

test "ParsedNetworkState.deinit with contents only" {
    const allocator = std.testing.allocator;
    const contents = try allocator.dupe(u8, "test contents");

    var state = ParsedNetworkState{
        .parsed = null,
        .contents = contents,
        .allocator = allocator,
    };
    state.deinit();
    try std.testing.expect(state.contents == null);
}
