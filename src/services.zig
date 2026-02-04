const std = @import("std");
const Allocator = std.mem.Allocator;

const constants = @import("constants.zig");
const fs_utils = @import("fs.zig");
const login = @import("login.zig");

pub const ServiceDef = struct {
    name: []const u8,
    args: []const []const u8,
    optional: bool = false,
    init_fn: ?*const fn (Allocator) anyerror!void = null,
};

/// Initialize the chrony service.
/// Creates the run directory and sets ownership to the chrony user.
pub fn initChrony(allocator: Allocator) !void {
    std.log.info("initializing chrony", .{});

    const passwd_contents = fs_utils.readFileAlloc(allocator, constants.FILE_ETC_PASSWD) catch |err| {
        std.log.err("failed to read {s}: {s}", .{ constants.FILE_ETC_PASSWD, @errorName(err) });
        return err;
    };
    defer allocator.free(passwd_contents);

    const uid = login.user_group_id(passwd_contents, constants.USER_NAME_CHRONY) catch |err| {
        std.log.err("user {s} not found: {s}", .{ constants.USER_NAME_CHRONY, @errorName(err) });
        return err;
    };

    const group_contents = fs_utils.readFileAlloc(allocator, constants.FILE_ETC_GROUP) catch |err| {
        std.log.err("failed to read {s}: {s}", .{ constants.FILE_ETC_GROUP, @errorName(err) });
        return err;
    };
    defer allocator.free(group_contents);

    const gid = login.user_group_id(group_contents, constants.USER_NAME_CHRONY) catch uid;

    // Create chrony run directory with correct ownership
    const chrony_run_path = constants.DIR_ET_RUN ++ "/chrony";
    try fs_utils.mkdir_p_own(chrony_run_path, 0o750, uid, gid);
}

/// Chrony service definition
pub const chrony_service = ServiceDef{
    .name = "chrony",
    .args = &[_][]const u8{ constants.DIR_ET_SBIN ++ "/chronyd", "-d" },
    .init_fn = initChrony,
};

/// Find enabled services by scanning the services directory.
pub fn findEnabledServices(
    allocator: Allocator,
    disable_services: ?[]const []const u8,
) ![]const ServiceDef {
    var enabled = try std.ArrayList(ServiceDef).initCapacity(allocator, 4);
    errdefer enabled.deinit(allocator);

    var dir = std.fs.openDirAbsolute(constants.DIR_ET_SERVICES, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) {
            std.log.info("no services directory found, skipping service discovery", .{});
            return try enabled.toOwnedSlice(allocator);
        }
        std.log.err("failed to open services directory: {s}", .{@errorName(err)});
        return err;
    };
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory and entry.kind != .file) continue;
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;

        // Check if service is disabled
        if (isServiceDisabled(entry.name, disable_services)) {
            std.log.info("disabling service {s}", .{entry.name});
            continue;
        }

        // Match known services
        if (std.mem.eql(u8, entry.name, "chrony")) {
            try enabled.append(allocator, chrony_service);
        } else {
            std.log.warn("unknown service {s}", .{entry.name});
        }
    }

    return try enabled.toOwnedSlice(allocator);
}

fn isServiceDisabled(name: []const u8, disable_services: ?[]const []const u8) bool {
    const disabled = disable_services orelse return false;
    for (disabled) |disabled_name| {
        if (std.mem.eql(u8, name, disabled_name)) {
            return true;
        }
    }
    return false;
}

const testing = std.testing;

test "isServiceDisabled returns false for null list" {
    try testing.expect(!isServiceDisabled("chrony", null));
}

test "isServiceDisabled returns false when not in list" {
    const disabled = [_][]const u8{ "ssh", "network" };
    try testing.expect(!isServiceDisabled("chrony", &disabled));
}

test "isServiceDisabled returns true when in list" {
    const disabled = [_][]const u8{ "ssh", "chrony", "network" };
    try testing.expect(isServiceDisabled("chrony", &disabled));
}

test "isServiceDisabled returns true for exact match" {
    const disabled = [_][]const u8{"chrony"};
    try testing.expect(isServiceDisabled("chrony", &disabled));
    try testing.expect(!isServiceDisabled("chrony2", &disabled));
}
