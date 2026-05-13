const std = @import("std");
const fs = std.fs;
const linux = std.os.linux;
const posix = std.posix;
const Io = std.Io;

const constants = @import("constants.zig");

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
    try mkdirRecursive(io, path, mode);
    if (uid == null and gid == null) return;

    var start: usize = 0;
    while (start < path.len) {
        const end = std.mem.indexOfScalarPos(u8, path, start + 1, '/') orelse path.len;
        const dir_path = path[0..end];
        if (dir_path.len > 0) {
            var dir = try Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
            defer dir.close(io);
            try dir.setOwner(io, uid, gid);
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

pub fn remountRootReadonly() !void {
    std.log.info("remounting root filesystem as readonly", .{});
    const ret = linux.mount(
        null,
        @ptrCast(constants.dir_root),
        null,
        linux.MS.REMOUNT | linux.MS.RDONLY,
        0,
    );
    const e = posix.errno(ret);
    if (e != .SUCCESS) {
        std.log.err(
            "unable to remount root filesystem as readonly: {s}",
            .{@tagName(e)},
        );
        return error.RemountFailed;
    }
}

/// Unmount all the given mount points. Logs failures but only returns an error if every
/// unmount failed, so a single stuck mount does not block the rest.
pub fn unmountAll(mount_points: []const []const u8) !void {
    var error_count: usize = 0;
    for (mount_points) |mount_point| {
        var path_buf: [posix.PATH_MAX]u8 = undefined;
        if (mount_point.len >= path_buf.len) {
            std.log.err("mount point too long: {s}", .{mount_point});
            error_count += 1;
            continue;
        }
        @memcpy(path_buf[0..mount_point.len], mount_point);
        path_buf[mount_point.len] = 0;
        const e = posix.errno(linux.umount2(@ptrCast(&path_buf), 0));
        if (e != .SUCCESS) {
            std.log.err("unable to unmount {s}: {s}", .{ mount_point, @tagName(e) });
            error_count += 1;
        }
    }

    if (mount_points.len > 0 and error_count == mount_points.len) {
        return error.UnmountFailed;
    }
}

/// Poll /proc/mounts until all of the given paths are missing or the timeout elapses.
pub fn waitForUnmounts(
    allocator: std.mem.Allocator,
    io: Io,
    mount_points: []const []const u8,
    timeout_ms: u64,
) !void {
    const timeout_ns: u64 = timeout_ms * std.time.ns_per_ms;
    const start = Io.Timestamp.now(io, .awake);
    while (true) {
        const mounts = readFileAlloc(io, allocator, "/proc/mounts") catch |err| {
            std.log.err("unable to read /proc/mounts: {s}", .{@errorName(err)});
            return err;
        };
        defer allocator.free(mounts);

        var mounts_remain = false;
        for (mount_points) |mp| {
            if (isMounted(mounts, mp)) {
                mounts_remain = true;
                break;
            }
        }
        if (!mounts_remain) {
            std.log.info("all filesystems unmounted", .{});
            return;
        }

        const elapsed = start.durationTo(Io.Timestamp.now(io, .awake));
        if (@as(u64, @intCast(elapsed.toNanoseconds())) >= timeout_ns) {
            return error.UnmountTimeout;
        }

        Io.sleep(io, Io.Duration.fromNanoseconds(100 * std.time.ns_per_ms), .awake) catch {};
    }
}

fn isMounted(mounts: []const u8, mount_point: []const u8) bool {
    var lines = std.mem.splitScalar(u8, mounts, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, ' ');
        _ = fields.next() orelse continue; // device
        const dest = fields.next() orelse continue;
        if (std.mem.eql(u8, dest, mount_point)) return true;
    }
    return false;
}

test "isMounted finds the given mount point" {
    const mounts =
        \\proc /proc proc rw,relatime 0 0
        \\sysfs /sys sysfs rw,nosuid,nodev,noexec,relatime 0 0
        \\/dev/sda1 /mnt/data ext4 rw,relatime 0 0
        \\
    ;
    try std.testing.expect(isMounted(mounts, "/mnt/data"));
    try std.testing.expect(isMounted(mounts, "/proc"));
    try std.testing.expect(!isMounted(mounts, "/mnt/other"));
    try std.testing.expect(!isMounted(mounts, ""));
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
