const std = @import("std");
const fs = std.fs;
const Mode = fs.File.Mode;

pub fn mkdir_p(path: []const u8, mode: Mode) !void {
    const cwd = fs.cwd();
    try cwd.makePath(path);

    var buf: [fs.max_path_bytes]u8 = undefined;
    const realpath = try cwd.realpath(path, &buf);

    var new_dir = try std.fs.openDirAbsolute(realpath, .{ .iterate = true });
    defer new_dir.close();

    return new_dir.chmod(mode);
}

test "mkdir_p" {
    try mkdir_p("a/b/c", 0o1777);
}
