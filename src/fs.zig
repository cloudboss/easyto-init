const std = @import("std");
const fs = std.fs;
const linux = std.os.linux;
const posix = std.posix;
const Mode = fs.File.Mode;

pub fn mkdir_p(path: []const u8, mode: Mode) !void {
    try mkdir_p_at(fs.cwd().fd, path, mode);
}

/// Create directories recursively with specified ownership.
pub fn mkdir_p_own(path: []const u8, mode: Mode, uid: ?u32, gid: ?u32) !void {
    try mkdir_p_own_at(fs.cwd().fd, path, mode, uid, gid);
}

fn mkdir_p_own_at(dir_fd: posix.fd_t, path: []const u8, mode: Mode, uid: ?u32, gid: ?u32) !void {
    var start: usize = 0;
    while (start < path.len) {
        const end = std.mem.indexOfScalarPos(u8, path, start + 1, '/') orelse path.len;
        const dir_path = path[0..end];

        if (dir_path.len > 0) {
            posix.mkdirat(dir_fd, dir_path, mode) catch |err| {
                if (err != error.PathAlreadyExists) {
                    return err;
                }
            };

            // Set ownership if specified
            if (uid != null or gid != null) {
                try chownPath(dir_path, uid, gid);
            }
        }

        start = end;
    }
}

/// Write content to a file, creating parent directories as needed.
pub fn writeFile(
    path: []const u8,
    content: []const u8,
    file_mode: Mode,
    dir_mode: Mode,
    uid: ?u32,
    gid: ?u32,
) !void {
    // Create parent directories
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |last_slash| {
        if (last_slash > 0) {
            try mkdir_p_own(path[0..last_slash], dir_mode, uid, gid);
        }
    }

    // Open and write file
    const file = fs.cwd().createFile(path, .{ .mode = file_mode }) catch |err| {
        std.log.err("failed to create file {s}: {s}", .{ path, @errorName(err) });
        return err;
    };
    defer file.close();

    file.writeAll(content) catch |err| {
        std.log.err("failed to write to {s}: {s}", .{ path, @errorName(err) });
        return err;
    };

    // Set ownership if specified
    if (uid != null or gid != null) {
        try chownFd(file.handle, uid, gid);
    }
}

fn chownPath(path: []const u8, uid: ?u32, gid: ?u32) !void {
    // Need null-terminated path for syscall
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= path_buf.len) {
        return error.NameTooLong;
    }
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;

    const ret = linux.syscall3(
        .chown,
        @intFromPtr(&path_buf),
        uid orelse @as(u32, 0xffffffff),
        gid orelse @as(u32, 0xffffffff),
    );
    const e = posix.errno(ret);
    if (e != .SUCCESS) {
        std.log.err("chown failed for {s}: {s}", .{ path, @tagName(e) });
        return error.ChownFailed;
    }
}

fn chownFd(fd: posix.fd_t, uid: ?u32, gid: ?u32) !void {
    posix.fchown(fd, uid, gid) catch |err| {
        std.log.err("fchown failed: {s}", .{@errorName(err)});
        return error.ChownFailed;
    };
}

/// Read an entire file.
pub fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    var buf: [4096]u8 = undefined;
    var reader = file.reader(&buf);
    return try reader.interface.allocRemaining(allocator, .unlimited);
}

/// Join a base path with a relative path, handling leading slashes.
pub fn joinPath(allocator: std.mem.Allocator, base: []const u8, relative: []const u8) ![]const u8 {
    // Strip leading slashes from relative path
    var rel = relative;
    while (rel.len > 0 and rel[0] == '/') {
        rel = rel[1..];
    }

    // Strip trailing slashes from base path
    var b = base;
    while (b.len > 0 and b[b.len - 1] == '/') {
        b = b[0 .. b.len - 1];
    }

    if (b.len == 0) {
        return try allocator.dupe(u8, rel);
    }
    if (rel.len == 0) {
        return try allocator.dupe(u8, b);
    }

    return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ b, rel });
}

fn mkdir_p_at(dir_fd: posix.fd_t, path: []const u8, mode: Mode) !void {
    var start: usize = 0;
    while (start < path.len) {
        const end = std.mem.indexOfScalarPos(u8, path, start + 1, '/') orelse path.len;
        const dir_path = path[0..end];

        if (dir_path.len > 0) {
            posix.mkdirat(dir_fd, dir_path, mode) catch |err| {
                if (err != error.PathAlreadyExists) {
                    return err;
                }
            };
        }

        start = end;
    }
}

test "mkdir_p creates nested directories" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const sub_path = "a/b/c";
    try mkdir_p_at(tmp_dir.dir.fd, sub_path, 0o755);

    // Verify each directory was created
    var dir = try tmp_dir.dir.openDir(sub_path, .{});
    dir.close();
}

test "mkdir_p succeeds when path already exists" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const sub_path = "existing/path";
    try mkdir_p_at(tmp_dir.dir.fd, sub_path, 0o755);

    // Call again - should not fail
    try mkdir_p_at(tmp_dir.dir.fd, sub_path, 0o755);

    // Verify directory still exists
    var dir = try tmp_dir.dir.openDir(sub_path, .{});
    dir.close();
}

test "mkdir_p with single component path" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const sub_path = "single";
    try mkdir_p_at(tmp_dir.dir.fd, sub_path, 0o755);

    var dir = try tmp_dir.dir.openDir(sub_path, .{});
    dir.close();
}

test "mkdir_p with trailing slash" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const sub_path = "trailing/slash/";
    try mkdir_p_at(tmp_dir.dir.fd, sub_path, 0o755);

    // Verify the directories exist (without trailing slash)
    var dir = try tmp_dir.dir.openDir("trailing/slash", .{});
    dir.close();
}

test "mkdir_p with empty path is a no-op" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Empty path should not create anything and should not error
    try mkdir_p_at(tmp_dir.dir.fd, "", 0o755);
}
