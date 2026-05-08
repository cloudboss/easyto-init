const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const system = @import("system.zig");

const NETLINK_KOBJECT_UEVENT: u32 = 15;

const DeviceEvent = struct {
    name: []const u8,
    part_num: ?[]const u8,
};

const SockaddrNl = extern struct {
    family: u16,
    pad: u16 = 0,
    pid: u32 = 0,
    groups: u32 = 0,
};

pub fn startUeventListener(allocator: Allocator, io: Io) !void {
    const sock_ret = linux.socket(
        posix.AF.NETLINK,
        posix.SOCK.DGRAM,
        NETLINK_KOBJECT_UEVENT,
    );
    const sock_errno = posix.errno(sock_ret);
    if (sock_errno != .SUCCESS) {
        std.log.err("failed to create netlink socket: {s}", .{@tagName(sock_errno)});
        return error.SocketFailed;
    }
    const fd: posix.fd_t = @intCast(sock_ret);

    const addr = SockaddrNl{
        .family = posix.AF.NETLINK,
        .groups = 1,
    };
    const bind_errno = posix.errno(linux.bind(fd, @ptrCast(&addr), @sizeOf(SockaddrNl)));
    if (bind_errno != .SUCCESS) {
        std.log.err("failed to bind netlink socket: {s}", .{@tagName(bind_errno)});
        return error.BindFailed;
    }

    const thread = std.Thread.spawn(
        .{ .stack_size = 1024 * 1024 },
        recvMessages,
        .{ fd, allocator, io },
    ) catch |err| {
        std.log.err("failed to spawn uevent listener thread: {s}", .{@errorName(err)});
        return err;
    };
    thread.detach();
}

fn recvMessages(fd: posix.fd_t, allocator: Allocator, io: Io) void {
    std.log.debug("starting uevent listener", .{});
    var buf: [4096]u8 = undefined;
    while (true) {
        const ret = linux.recvfrom(fd, &buf, buf.len, 0, null, null);
        const e = posix.errno(ret);
        if (e != .SUCCESS) {
            std.log.err("error receiving netlink message: {s}", .{@tagName(e)});
            continue;
        }
        const len: usize = @intCast(ret);
        if (handleMessage(buf[0..len])) |dev| {
            if (dev) |device| {
                system.linkNvmeDevice(allocator, io, device.name, device.part_num) catch |err| {
                    std.log.err("error linking device {s}: {s}", .{ device.name, @errorName(err) });
                };
            }
        } else |err| {
            std.log.err("error handling netlink message: {s}", .{@errorName(err)});
        }
    }
}

fn handleMessage(buf: []const u8) !?DeviceEvent {
    if (buf.len < 4) return error.UnexpectedLength;

    // Only handle "add@" messages.
    if (!std.mem.startsWith(u8, buf, "add@")) return null;

    var devname: ?[]const u8 = null;
    var partn: ?[]const u8 = null;

    var it = std.mem.splitScalar(u8, buf, 0);
    while (it.next()) |field| {
        if (field.len == 0) continue;

        if (std.mem.indexOfScalar(u8, field, '=')) |eq_pos| {
            const key = field[0..eq_pos];
            const value = field[eq_pos + 1 ..];

            if (std.mem.eql(u8, key, "SUBSYSTEM")) {
                if (!std.mem.eql(u8, value, "block")) return null;
            } else if (std.mem.eql(u8, key, "DEVNAME")) {
                devname = value;
            } else if (std.mem.eql(u8, key, "PARTN")) {
                partn = value;
            }
        }
    }

    const name = devname orelse return null;
    return DeviceEvent{
        .name = name,
        .part_num = partn,
    };
}

const testing = std.testing;

test "handleMessage add block device" {
    const msg = "add@/devices/pci/nvme1n1\x00SUBSYSTEM=block\x00DEVNAME=nvme1n1\x00";
    const result = try handleMessage(msg);
    try testing.expect(result != null);
    try testing.expectEqualStrings("nvme1n1", result.?.name);
    try testing.expect(result.?.part_num == null);
}

test "handleMessage add block device with partition" {
    const msg = "add@/devices/pci/nvme1n1p1\x00SUBSYSTEM=block\x00DEVNAME=nvme1n1p1\x00PARTN=1\x00";
    const result = try handleMessage(msg);
    try testing.expect(result != null);
    try testing.expectEqualStrings("nvme1n1p1", result.?.name);
    try testing.expectEqualStrings("1", result.?.part_num.?);
}

test "handleMessage non-add message" {
    const msg = "remove@/devices/pci/nvme1n1\x00SUBSYSTEM=block\x00DEVNAME=nvme1n1\x00";
    const result = try handleMessage(msg);
    try testing.expect(result == null);
}

test "handleMessage non-block subsystem" {
    const msg = "add@/devices/pci/ttyS0\x00SUBSYSTEM=tty\x00DEVNAME=ttyS0\x00";
    const result = try handleMessage(msg);
    try testing.expect(result == null);
}

test "handleMessage short message" {
    const result = handleMessage("ad");
    try testing.expectError(error.UnexpectedLength, result);
}

test "handleMessage no devname" {
    const msg = "add@/devices/pci/nvme1n1\x00SUBSYSTEM=block\x00";
    const result = try handleMessage(msg);
    try testing.expect(result == null);
}

test "handleMessage add@ only" {
    const msg = "add@/devices/pci/nvme1n1\x00";
    const result = try handleMessage(msg);
    try testing.expect(result == null);
}
