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

/// Atomically write content to `path`: write to a sibling tmp file, fsync it,
/// rename into place, then fsync the parent directory. Does not create parent
/// directories — caller is responsible. Mirrors the Rust port's `atomic_write`
/// semantics in `easyto-init/src/fs.rs`.
pub fn atomicWriteFile(path: []const u8, content: []const u8, mode: Mode) !void {
    try atomicWriteFileAt(fs.cwd(), path, content, mode);
}

pub fn atomicWriteFileAt(dir: fs.Dir, path: []const u8, content: []const u8, mode: Mode) !void {
    const basename = fs.path.basename(path);
    if (basename.len == 0) return error.InvalidPath;
    const dirname_opt = fs.path.dirname(path);

    var tmp_buf: [fs.max_path_bytes]u8 = undefined;
    const tmp_path = if (dirname_opt) |d|
        try std.fmt.bufPrint(&tmp_buf, "{s}/.{s}.tmp", .{ d, basename })
    else
        try std.fmt.bufPrint(&tmp_buf, ".{s}.tmp", .{basename});

    const file = try dir.createFile(tmp_path, .{ .mode = mode, .truncate = true });
    {
        errdefer dir.deleteFile(tmp_path) catch {};
        defer file.close();
        try file.writeAll(content);
        try file.sync();
    }

    dir.rename(tmp_path, path) catch |err| {
        dir.deleteFile(tmp_path) catch {};
        return err;
    };

    const parent_path: []const u8 = dirname_opt orelse ".";
    var parent_dir = try dir.openDir(parent_path, .{ .iterate = true });
    defer parent_dir.close();
    syncFd(parent_dir.fd) catch |err| {
        std.log.warn("fsync parent dir of {s}: {s}", .{ path, @errorName(err) });
    };
}

fn syncFd(fd: posix.fd_t) !void {
    const ret = linux.fsync(fd);
    switch (posix.errno(ret)) {
        .SUCCESS => return,
        .INVAL => return error.NotSupported,
        .IO => return error.InputOutput,
        .NOSPC => return error.NoSpaceLeft,
        .DQUOT => return error.DiskQuota,
        .ROFS => return error.ReadOnlyFileSystem,
        .BADF => return error.InvalidFileDescriptor,
        else => |e| return posix.unexpectedErrno(e),
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

test "atomicWriteFile creates file with content and mode" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try atomicWriteFileAt(tmp_dir.dir, "out.txt", "hello", 0o600);

    const file = try tmp_dir.dir.openFile("out.txt", .{});
    defer file.close();

    var buf: [32]u8 = undefined;
    const n = try file.readAll(&buf);
    try std.testing.expectEqualStrings("hello", buf[0..n]);

    const stat = try file.stat();
    try std.testing.expectEqual(@as(Mode, 0o600), stat.mode & 0o777);
}

test "atomicWriteFile overwrites existing file" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try atomicWriteFileAt(tmp_dir.dir, "out.txt", "first", 0o644);
    try atomicWriteFileAt(tmp_dir.dir, "out.txt", "second content", 0o644);

    const file = try tmp_dir.dir.openFile("out.txt", .{});
    defer file.close();

    var buf: [64]u8 = undefined;
    const n = try file.readAll(&buf);
    try std.testing.expectEqualStrings("second content", buf[0..n]);
}

test "atomicWriteFile does not leave tmp file behind" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try atomicWriteFileAt(tmp_dir.dir, "out.txt", "data", 0o644);

    try std.testing.expectError(error.FileNotFound, tmp_dir.dir.openFile(".out.txt.tmp", .{}));
}

test "atomicWriteFile errors when parent dir does not exist" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try std.testing.expectError(
        error.FileNotFound,
        atomicWriteFileAt(tmp_dir.dir, "missing/out.txt", "data", 0o644),
    );
}

test "atomicWriteFile works with nested existing dir" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.makePath("sub");
    try atomicWriteFileAt(tmp_dir.dir, "sub/out.txt", "nested", 0o644);

    const file = try tmp_dir.dir.openFile("sub/out.txt", .{});
    defer file.close();

    var buf: [32]u8 = undefined;
    const n = try file.readAll(&buf);
    try std.testing.expectEqualStrings("nested", buf[0..n]);

    try std.testing.expectError(error.FileNotFound, tmp_dir.dir.openFile("sub/.out.txt.tmp", .{}));
}
