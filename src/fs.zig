const std = @import("std");
const fs = std.fs;
const posix = std.posix;
const Mode = fs.File.Mode;

pub fn mkdir_p(path: []const u8, mode: Mode) !void {
    // Build list of directories from root to target
    var start: usize = 0;
    while (start < path.len) {
        // Find next path separator
        const end = std.mem.indexOfScalarPos(u8, path, start + 1, '/') orelse path.len;
        const dir_path = path[0..end];

        // Skip empty path (leading slash)
        if (dir_path.len > 0) {
            // Try to create directory
            posix.mkdirat(fs.cwd().fd, dir_path, mode) catch |err| {
                if (err != error.PathAlreadyExists) {
                    return err;
                }
            };
        }

        start = end;
    }
}

test "mkdir_p" {
    try mkdir_p("a/b/c", 0o1777);
}
