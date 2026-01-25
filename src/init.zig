const std = @import("std");
const fmt = std.fmt;
const mount = std.os.linux.mount;
const ms = std.os.linux.MS;
const Mode = std.fs.File.Mode;
const Allocator = std.mem.Allocator;

const constants = @import("constants.zig");
const container = @import("container.zig");
const mkdir_p = @import("fs.zig").mkdir_p;
const system = @import("system.zig");
const VmSpec = @import("vmspec.zig").VmSpec;

const Error = error{
    MountError,
};

pub const Mount = struct {
    source: []const u8,
    flags: u32 = 0,
    fs_type: []const u8,
    mode: Mode,
    options: ?[]const u8 = null,
    target: []const u8,

    pub fn execute(self: Mount, errno: *usize) !void {
        mkdir_p(self.target, self.mode) catch |err| {
            std.log.err("failed to create directory {s}: {s}", .{ self.target, @errorName(err) });
            return err;
        };
        const ret = mount(
            @ptrCast(self.source),
            @ptrCast(self.target),
            @ptrCast(self.fs_type),
            self.flags,
            @intFromPtr(@as(?[*:0]const u8, @ptrCast(self.options))),
        );
        const e = std.posix.errno(ret);
        switch (e) {
            .SUCCESS => {},
            .BUSY => {
                std.log.warn("mount point {s} already mounted, skipping", .{self.target});
            },
            else => {
                std.log.err("mount {s} on {s} failed: {s}", .{ self.source, self.target, @tagName(e) });
                errno.* = @intFromEnum(e);
                return Error.MountError;
            },
        }
    }
};

const Link = struct {
    path: []const u8,
    target: []const u8,
};

pub fn run(allocator: Allocator) !void {
    try base_mounts();

    try base_links();

    try system.link_nvme_devices(allocator);

    const config_file_path = constants.DIR_ET ++ "/" ++ constants.FILE_METADATA;
    const config_file = try read_metadata(allocator, config_file_path);
    _ = try VmSpec.from_config_file(allocator, &config_file);
}

fn base_mounts() !void {
    const mounts = [_]Mount{
        .{
            .source = "devtmpfs",
            .flags = ms.NOSUID,
            .fs_type = "devtmpfs",
            .mode = 0o755,
            .target = constants.DIR_DEV,
        },
        .{
            .source = "devpts",
            .flags = ms.NOATIME | ms.NOEXEC | ms.NOSUID,
            .fs_type = "devpts",
            .mode = 0o755,
            .options = "mode=0620,gid=5,ptmxmode=666",
            .target = constants.DIR_DEV_PTS,
        },
        .{
            .source = "mqueue",
            .flags = ms.NODEV | ms.NOEXEC | ms.NOSUID,
            .fs_type = "mqueue",
            .mode = 0o755,
            .target = constants.DIR_DEV_MQUEUE,
        },
        .{
            .source = "tmpfs",
            .flags = ms.NODEV | ms.NOSUID,
            .fs_type = "tmpfs",
            .mode = 0o1777,
            .target = constants.DIR_DEV_SHM,
        },
        .{
            .source = "hugetlbfs",
            .flags = ms.RELATIME,
            .fs_type = "hugetlbfs",
            .mode = 0o755,
            .target = constants.DIR_DEV_HUGEPAGES,
        },
        .{
            .source = "proc",
            .flags = ms.NODEV | ms.NOEXEC | ms.RELATIME | ms.NOSUID,
            .fs_type = "proc",
            .mode = 0o555,
            .target = constants.DIR_PROC,
        },
        .{
            .source = "sys",
            .flags = ms.NODEV | ms.NOEXEC | ms.NOSUID,
            .fs_type = "sys",
            .mode = 0o555,
            .target = constants.DIR_SYS,
        },
        .{
            .source = "tmpfs",
            .flags = ms.NODEV | ms.NOSUID,
            .fs_type = "tmpfs",
            .mode = 0o755,
            .options = "mode=0755",
            .target = constants.DIR_ET_RUN,
        },
        .{
            .source = "cgroup2",
            .flags = ms.NODEV | ms.NOEXEC | ms.RELATIME | ms.NOSUID,
            .fs_type = "cgroup2",
            .mode = 0o555,
            .options = "nsdelegate",
            .target = constants.DIR_SYS_FS_CGROUP,
        },
        .{
            .source = "debugfs",
            .flags = ms.NODEV | ms.NOEXEC | ms.RELATIME | ms.NOSUID,
            .fs_type = "debugfs",
            .mode = 0o500,
            .target = constants.DIR_SYS_KERNEL_DEBUG,
        },
    };

    for (mounts) |m| {
        var errno: usize = 0;
        try m.execute(&errno);
    }
}

fn base_links() !void {
    const links = [_]Link{
        .{
            .target = "/proc/self/fd",
            .path = "/dev/fd",
        },
        .{
            .target = "/proc/self/fd/0",
            .path = "/dev/stdin",
        },
        .{
            .target = "/proc/self/fd/1",
            .path = "/dev/stdout",
        },
        .{
            .target = "/proc/self/fd/2",
            .path = "/dev/stderr",
        },
    };

    for (links) |link| {
        std.posix.symlink(link.target, link.path) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };
    }
}

fn read_metadata(allocator: Allocator, path: []const u8) !container.ConfigFile {
    const contents = try std.fs.cwd().readFileAlloc(
        allocator,
        path,
        1073741824,
    );
    const parsed = try std.json.parseFromSlice(
        container.ConfigFile,
        allocator,
        contents,
        .{},
    );
    return parsed.value;
}
