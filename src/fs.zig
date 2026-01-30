const std = @import("std");
const fs = std.fs;
const posix = std.posix;
const Mode = fs.File.Mode;

pub fn mkdir_p(path: []const u8, mode: Mode) !void {
    try mkdir_p_at(fs.cwd().fd, path, mode);
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
