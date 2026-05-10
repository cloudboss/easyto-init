const std = @import("std");
const fs = std.fs;
const linux = std.os.linux;
const posix = std.posix;
const Io = std.Io;

pub fn mkdirRecursive(io: Io, path: []const u8, mode: posix.mode_t) !void {
    try mkdirRecursiveAt(io, Io.Dir.cwd(), path, mode);
}

fn mkdirRecursiveAt(io: Io, dir: Io.Dir, path: []const u8, mode: posix.mode_t) !void {
    if (path.len == 0 or std.mem.eql(u8, path, "/")) return;
    _ = try dir.createDirPathStatus(io, path, .fromMode(mode));
}

/// Create directories recursively with specified ownership. Each intermediate
/// component is chowned individually; `mkdirRecursive` is preferred when ownership
/// is not needed.
pub fn mkdirRecursiveOwn(
    io: Io,
    path: []const u8,
    mode: posix.mode_t,
    uid: ?u32,
    gid: ?u32,
) !void {
    var start: usize = 0;
    while (start < path.len) {
        const end = std.mem.indexOfScalarPos(u8, path, start + 1, '/') orelse path.len;
        const dir_path = path[0..end];

        if (dir_path.len > 0) {
            Io.Dir.cwd().createDir(io, dir_path, .fromMode(mode)) catch |err| {
                if (err != error.PathAlreadyExists) return err;
            };

            if (uid != null or gid != null) {
                var dir = try Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
                defer dir.close(io);
                try dir.setOwner(io, uid, gid);
            }
        }

        start = end;
    }
}

/// Write content to a file, creating parent directories as needed.
pub fn writeFile(
    io: Io,
    path: []const u8,
    content: []const u8,
    file_mode: posix.mode_t,
    dir_mode: posix.mode_t,
    uid: ?u32,
    gid: ?u32,
) !void {
    // Create parent directories
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |last_slash| {
        if (last_slash > 0) {
            try mkdirRecursiveOwn(io, path[0..last_slash], dir_mode, uid, gid);
        }
    }

    // Open and write file
    const file = Io.Dir.cwd().createFile(io, path, .{
        .permissions = .fromMode(file_mode),
    }) catch |err| {
        std.log.err("failed to create file {s}: {s}", .{ path, @errorName(err) });
        return err;
    };
    defer file.close(io);

    file.writeStreamingAll(io, content) catch |err| {
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
pub fn atomicWriteFile(io: Io, path: []const u8, content: []const u8, mode: posix.mode_t) !void {
    try atomicWriteFileAt(io, Io.Dir.cwd(), path, content, mode);
}

pub fn atomicWriteFileAt(
    io: Io,
    dir: Io.Dir,
    path: []const u8,
    content: []const u8,
    mode: posix.mode_t,
) !void {
    const basename = fs.path.basename(path);
    if (basename.len == 0) return error.InvalidPath;
    const dirname_opt = fs.path.dirname(path);

    var tmp_buf: [fs.max_path_bytes]u8 = undefined;
    const tmp_path = if (dirname_opt) |d|
        try std.fmt.bufPrint(&tmp_buf, "{s}/.{s}.tmp", .{ d, basename })
    else
        try std.fmt.bufPrint(&tmp_buf, ".{s}.tmp", .{basename});

    const file = try dir.createFile(io, tmp_path, .{
        .permissions = .fromMode(mode),
        .truncate = true,
    });
    {
        errdefer dir.deleteFile(io, tmp_path) catch {};
        defer file.close(io);
        try file.writeStreamingAll(io, content);
        try file.sync(io);
    }

    dir.rename(tmp_path, dir, path, io) catch |err| {
        dir.deleteFile(io, tmp_path) catch {};
        return err;
    };

    const parent_path: []const u8 = dirname_opt orelse ".";
    var parent_dir = try dir.openDir(io, parent_path, .{ .iterate = true });
    defer parent_dir.close(io);
    syncFd(parent_dir.handle) catch |err| {
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

fn chownFd(fd: posix.fd_t, uid: ?u32, gid: ?u32) !void {
    const e = posix.errno(linux.fchown(
        fd,
        uid orelse std.math.maxInt(posix.uid_t),
        gid orelse std.math.maxInt(posix.gid_t),
    ));
    if (e != .SUCCESS) {
        std.log.err("fchown failed: {s}", .{@tagName(e)});
        return error.ChownFailed;
    }
}

/// Read an entire file.
pub fn readFileAlloc(io: Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);
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

test "mkdirRecursiveAt creates nested directories" {
    const io = std.testing.io;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const sub_path = "a/b/c";
    try mkdirRecursiveAt(io, tmp_dir.dir, sub_path, 0o755);

    var dir = try tmp_dir.dir.openDir(io, sub_path, .{});
    dir.close(io);
}

test "mkdirRecursiveAt succeeds when path already exists" {
    const io = std.testing.io;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const sub_path = "existing/path";
    try mkdirRecursiveAt(io, tmp_dir.dir, sub_path, 0o755);

    // Call again - should not fail
    try mkdirRecursiveAt(io, tmp_dir.dir, sub_path, 0o755);

    var dir = try tmp_dir.dir.openDir(io, sub_path, .{});
    dir.close(io);
}

test "mkdirRecursiveAt with single component path" {
    const io = std.testing.io;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const sub_path = "single";
    try mkdirRecursiveAt(io, tmp_dir.dir, sub_path, 0o755);

    var dir = try tmp_dir.dir.openDir(io, sub_path, .{});
    dir.close(io);
}

test "mkdirRecursiveAt with trailing slash" {
    const io = std.testing.io;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const sub_path = "trailing/slash/";
    try mkdirRecursiveAt(io, tmp_dir.dir, sub_path, 0o755);

    var dir = try tmp_dir.dir.openDir(io, "trailing/slash", .{});
    dir.close(io);
}

test "mkdirRecursiveAt with empty path is a no-op" {
    const io = std.testing.io;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try mkdirRecursiveAt(io, tmp_dir.dir, "", 0o755);
}

test "mkdirRecursiveAt with root path is a no-op" {
    const io = std.testing.io;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try mkdirRecursiveAt(io, tmp_dir.dir, "/", 0o755);
}

test "atomicWriteFile creates file with content and mode" {
    const io = std.testing.io;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try atomicWriteFileAt(io, tmp_dir.dir, "out.txt", "hello", 0o600);

    const file = try tmp_dir.dir.openFile(io, "out.txt", .{});
    defer file.close(io);

    var read_buf: [32]u8 = undefined;
    var rbuf: [64]u8 = undefined;
    var reader = file.reader(io, &rbuf);
    const n = try reader.interface.readSliceShort(&read_buf);
    try std.testing.expectEqualStrings("hello", read_buf[0..n]);

    const stat = try file.stat(io);
    try std.testing.expectEqual(@as(posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);
}

test "atomicWriteFile overwrites existing file" {
    const io = std.testing.io;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try atomicWriteFileAt(io, tmp_dir.dir, "out.txt", "first", 0o644);
    try atomicWriteFileAt(io, tmp_dir.dir, "out.txt", "second content", 0o644);

    const file = try tmp_dir.dir.openFile(io, "out.txt", .{});
    defer file.close(io);

    var read_buf: [64]u8 = undefined;
    var rbuf: [128]u8 = undefined;
    var reader = file.reader(io, &rbuf);
    const n = try reader.interface.readSliceShort(&read_buf);
    try std.testing.expectEqualStrings("second content", read_buf[0..n]);
}

test "atomicWriteFile does not leave tmp file behind" {
    const io = std.testing.io;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try atomicWriteFileAt(io, tmp_dir.dir, "out.txt", "data", 0o644);

    try std.testing.expectError(error.FileNotFound, tmp_dir.dir.openFile(io, ".out.txt.tmp", .{}));
}

test "atomicWriteFile errors when parent dir does not exist" {
    const io = std.testing.io;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try std.testing.expectError(
        error.FileNotFound,
        atomicWriteFileAt(io, tmp_dir.dir, "missing/out.txt", "data", 0o644),
    );
}

test "atomicWriteFile works with nested existing dir" {
    const io = std.testing.io;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(io, "sub");
    try atomicWriteFileAt(io, tmp_dir.dir, "sub/out.txt", "nested", 0o644);

    const file = try tmp_dir.dir.openFile(io, "sub/out.txt", .{});
    defer file.close(io);

    var read_buf: [32]u8 = undefined;
    var rbuf: [64]u8 = undefined;
    var reader = file.reader(io, &rbuf);
    const n = try reader.interface.readSliceShort(&read_buf);
    try std.testing.expectEqualStrings("nested", read_buf[0..n]);

    try std.testing.expectError(
        error.FileNotFound,
        tmp_dir.dir.openFile(io, "sub/.out.txt.tmp", .{}),
    );
}
