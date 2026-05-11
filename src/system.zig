const std = @import("std");
const linux = std.os.linux;
const fmt = std.fmt;
const Io = std.Io;
const posix = std.posix;
const Allocator = std.mem.Allocator;
const testing = std.testing;

const GptContext = @import("zgpt").GptContext;
const GptEntry = @import("zgpt").gpt.GptEntry;
const resizePartition = @import("zblkpg").resizePartition;

const backoff = @import("backoff.zig");
const constants = @import("constants.zig");
const NameValue = @import("vmspec.zig").NameValue;
const nvme = @import("nvme-amz.zig");
const process = @import("process.zig");

const sys_block_path = "/sys/block";

pub fn linkNvmeDevices(allocator: Allocator, io: Io) !void {
    var dir = Io.Dir.openDirAbsolute(
        io,
        sys_block_path,
        .{ .iterate = true },
    ) catch |err| {
        std.log.err(
            "unable to open {s}: {s}",
            .{ sys_block_path, @errorName(err) },
        );
        return err;
    };
    defer dir.close(io);
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        const device_name = entry.name;
        std.log.debug("found block device: {s}", .{device_name});

        linkNvmeDevice(allocator, io, device_name, null) catch {};

        var partitions = diskPartitions(
            allocator,
            io,
            device_name,
        ) catch continue;
        defer {
            for (partitions.items) |*p| p.deinit(allocator);
            partitions.deinit(allocator);
        }
        for (partitions.items) |partition| {
            linkNvmeDevice(
                allocator,
                io,
                partition.name,
                partition.part_num,
            ) catch {};
        }
    }
}

const PartitionInfo = struct {
    name: []const u8,
    part_num: []const u8,

    fn deinit(self: *PartitionInfo, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.part_num);
    }
};

/// Link a single device to its EC2 device name via symlink.
/// Used by the uevent listener for hotplugged NVMe devices.
pub fn linkNvmeDevice(
    allocator: Allocator,
    io: Io,
    device_name: []const u8,
    part_num: ?[]const u8,
) !void {
    var dev_path_buf: [128]u8 = undefined;
    const dev_path = try fmt.bufPrint(
        &dev_path_buf,
        "{s}/{s}",
        .{ constants.dir_dev, device_name },
    );

    const file = Io.Dir.openFileAbsolute(io, dev_path, .{}) catch |err| {
        std.log.err("unable to open {s}: {s}", .{ dev_path, @errorName(err) });
        return err;
    };
    defer file.close(io);

    var errno: usize = 0;
    var nvme_info = nvme.Nvme.fromFd(allocator, file.handle, &errno) catch |err| {
        std.log.debug(
            "skipping {s}: not an Amazon NVMe device: {s}",
            .{ device_name, @errorName(err) },
        );
        return;
    };
    defer nvme_info.deinit(allocator);

    std.log.debug("nvme device: {any}", .{nvme_info});

    const ec2_name = nvme_info.name() catch |err| {
        std.log.debug(
            "skipping {s}: no device name: {s}",
            .{ device_name, @errorName(err) },
        );
        return;
    };

    var link_name_buf: [128]u8 = undefined;
    const link_name = if (part_num) |pn|
        if (deviceHasNumericSuffix(ec2_name))
            try fmt.bufPrint(&link_name_buf, "{s}p{s}", .{ ec2_name, pn })
        else
            try fmt.bufPrint(&link_name_buf, "{s}{s}", .{ ec2_name, pn })
    else
        ec2_name;

    var link_path_buf: [128]u8 = undefined;
    const link_path = try fmt.bufPrint(
        &link_path_buf,
        "{s}/{s}",
        .{ constants.dir_dev, link_name },
    );

    std.log.debug("linking {s} to {s}", .{ device_name, link_path });

    var device_z_buf: [posix.PATH_MAX]u8 = undefined;
    var link_z_buf: [posix.PATH_MAX]u8 = undefined;
    if (device_name.len >= device_z_buf.len or link_path.len >= link_z_buf.len) {
        return error.NameTooLong;
    }
    @memcpy(device_z_buf[0..device_name.len], device_name);
    device_z_buf[device_name.len] = 0;
    @memcpy(link_z_buf[0..link_path.len], link_path);
    link_z_buf[link_path.len] = 0;
    const sym_errno = posix.errno(linux.symlink(@ptrCast(&device_z_buf), @ptrCast(&link_z_buf)));
    if (sym_errno != .SUCCESS and sym_errno != .EXIST) {
        std.log.err(
            "unable to link {s} to {s}: {s}",
            .{ device_name, link_path, @tagName(sym_errno) },
        );
        return error.SymlinkFailed;
    }
}

fn diskPartitions(
    allocator: Allocator,
    io: Io,
    device: []const u8,
) !std.ArrayList(PartitionInfo) {
    var path_buf: [128]u8 = undefined;
    const sys_device_path = try fmt.bufPrint(
        &path_buf,
        "{s}/{s}",
        .{ sys_block_path, device },
    );

    var dir = Io.Dir.openDirAbsolute(
        io,
        sys_device_path,
        .{ .iterate = true },
    ) catch |err| {
        std.log.err(
            "unable to open {s}: {s}",
            .{ sys_device_path, @errorName(err) },
        );
        return err;
    };
    defer dir.close(io);
    var iter = dir.iterate();

    var partitions: std.ArrayList(PartitionInfo) = .empty;

    while (try iter.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (!std.mem.startsWith(u8, entry.name, device)) continue;

        var pt_path_buf: [256]u8 = undefined;
        const pt_path = fmt.bufPrint(
            &pt_path_buf,
            "{s}/partition",
            .{entry.name},
        ) catch continue;

        const raw = dir.readFileAlloc(io, pt_path, allocator, .limited(32)) catch continue;
        const part_num = std.mem.trim(u8, raw, " \t\r\n");
        // Dupe the trimmed slice so we can free the raw buffer.
        const pn = allocator.dupe(u8, part_num) catch {
            allocator.free(raw);
            continue;
        };
        allocator.free(raw);

        const name = allocator.dupe(u8, entry.name) catch {
            allocator.free(pn);
            continue;
        };

        partitions.append(allocator, PartitionInfo{
            .name = name,
            .part_num = pn,
        }) catch {
            allocator.free(name);
            allocator.free(pn);
            continue;
        };
    }

    return partitions;
}

pub fn deviceHasNumericSuffix(device: []const u8) bool {
    const len = device.len;
    if (len == 0) {
        return false;
    }
    return (device[len - 1] >= '0') and (device[len - 1] <= '9');
}

/// Check if a device has a filesystem using blkid.
/// Returns true if filesystem detected, false if no filesystem.
pub fn deviceHasFilesystem(io: Io, device: []const u8) !bool {
    const blkid_path = constants.dir_et_sbin ++ "/blkid";

    var child = std.process.spawn(io, .{
        .argv = &[_][]const u8{ blkid_path, device },
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |err| {
        std.log.err("failed to spawn blkid for {s}: {s}", .{ device, @errorName(err) });
        return err;
    };

    const result = child.wait(io) catch |err| {
        std.log.err("failed to wait for blkid {s}: {s}", .{ device, @errorName(err) });
        return err;
    };

    return switch (result.exited) {
        0 => true, // Filesystem detected
        2 => false, // No filesystem found
        else => {
            std.log.err("blkid {s} failed with exit code {d}", .{ device, result.exited });
            return error.BlkidFailed;
        },
    };
}

/// Wait for a device to exist with exponential backoff.
pub fn waitForDevice(io: Io, device: []const u8, timeout_secs: u64) !void {
    const timeout_ns: u64 = timeout_secs * std.time.ns_per_s;
    const start_time = Io.Timestamp.now(io, .awake);

    var retry = backoff.RetryBackoff.init(10000);

    while (true) {
        // Check if device exists
        if (Io.Dir.accessAbsolute(io, device, .{})) {
            std.log.debug("device {s} is available", .{device});
            return;
        } else |_| {}

        const elapsed_dur = start_time.durationTo(Io.Timestamp.now(io, .awake));
        const elapsed: u64 = @intCast(elapsed_dur.toNanoseconds());
        if (elapsed > timeout_ns) {
            std.log.err("timeout waiting for device {s} to exist", .{device});
            return error.DeviceTimeout;
        }

        std.log.debug("waiting for device {s} to exist", .{device});
        retry.wait(io);
    }
}

/// Create a filesystem on a device if it doesn't have one.
pub fn createFilesystem(io: Io, device: []const u8, fs_type: []const u8) !void {
    // Check if device already has a filesystem
    const has_fs = deviceHasFilesystem(io, device) catch |err| {
        std.log.err("unable to check if {s} has a filesystem: {s}", .{ device, @errorName(err) });
        return err;
    };

    if (has_fs) {
        std.log.debug("device {s} already has a filesystem", .{device});
        return;
    }

    // Build mkfs path
    var mkfs_buf: [128]u8 = undefined;
    const mkfs_path = fmt.bufPrint(
        &mkfs_buf,
        "{s}/mkfs.{s}",
        .{ constants.dir_et_sbin, fs_type },
    ) catch {
        std.log.err("mkfs path too long for {s}", .{fs_type});
        return error.PathTooLong;
    };

    // Check if mkfs tool exists
    Io.Dir.accessAbsolute(io, mkfs_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            std.log.err("unsupported filesystem {s} for {s}", .{ fs_type, device });
            return error.UnsupportedFilesystem;
        }
        std.log.err("unable to access {s}: {s}", .{ mkfs_path, @errorName(err) });
        return err;
    };

    std.log.info("creating {s} filesystem on {s}", .{ fs_type, device });

    var child = std.process.spawn(io, .{
        .argv = &[_][]const u8{ mkfs_path, device },
    }) catch |err| {
        std.log.err("unable to spawn {s}: {s}", .{ mkfs_path, @errorName(err) });
        return err;
    };

    const result = child.wait(io) catch |err| {
        std.log.err("failed to wait for {s}: {s}", .{ mkfs_path, @errorName(err) });
        return err;
    };

    if (result.exited != 0) {
        std.log.err(
            "mkfs.{s} {s} failed with exit code {d}",
            .{ fs_type, device, result.exited },
        );
        return error.MkfsFailed;
    }

    std.log.info("created {s} filesystem on {s}", .{ fs_type, device });
}

/// Mount a device to a destination.
pub fn mountDevice(io: Io, device: []const u8, destination: []const u8, fs_type: []const u8) !void {
    const fs_utils = @import("fs.zig");

    // Create mount point if it doesn't exist
    fs_utils.mkdirRecursive(io, destination, 0o755) catch |err| {
        std.log.err("failed to create mount point {s}: {s}", .{ destination, @errorName(err) });
        return err;
    };

    // Create null-terminated copies for the mount syscall.
    var dev_buf: [256]u8 = undefined;
    var dest_buf: [256]u8 = undefined;
    var fs_buf: [64]u8 = undefined;
    const dev_z = fmt.bufPrintZ(&dev_buf, "{s}", .{device}) catch {
        std.log.err("device path too long: {s}", .{device});
        return error.PathTooLong;
    };
    const dest_z = fmt.bufPrintZ(&dest_buf, "{s}", .{destination}) catch {
        std.log.err("mount destination too long: {s}", .{destination});
        return error.PathTooLong;
    };
    const fs_z = fmt.bufPrintZ(&fs_buf, "{s}", .{fs_type}) catch {
        std.log.err("fs type too long: {s}", .{fs_type});
        return error.PathTooLong;
    };

    const ret = linux.mount(dev_z, dest_z, fs_z, 0, 0);
    const e = posix.errno(ret);
    if (e != .SUCCESS) {
        std.log.err("mount {s} on {s} failed: {s}", .{ device, destination, @tagName(e) });
        return error.MountFailed;
    }

    std.log.info("mounted {s} on {s}", .{ device, destination });
}

pub fn poweroff() void {
    const MAGIC1 = linux.LINUX_REBOOT.MAGIC1.MAGIC1;
    const MAGIC2 = linux.LINUX_REBOOT.MAGIC2.MAGIC2;
    const POWER_OFF = linux.LINUX_REBOOT.CMD.POWER_OFF;
    const ret = linux.reboot(MAGIC1, MAGIC2, POWER_OFF, null);
    const e = std.posix.errno(ret);
    if (e != .SUCCESS) {
        std.log.err("failed to power off: {s}", .{@tagName(e)});
    }
}

/// Search each colon-separated directory in `path_var` for `executable`.
/// Returns an allocated absolute path for the first executable match, or
/// null if none is found. Caller owns the returned slice.
pub fn findExecutableInPath(
    allocator: Allocator,
    io: Io,
    path_var: []const u8,
    executable: []const u8,
) !?[]u8 {
    var iter = std.mem.splitScalar(u8, path_var, ':');
    while (iter.next()) |dir| {
        if (dir.len == 0) continue;
        const candidate = try fmt.allocPrint(allocator, "{s}/{s}", .{ dir, executable });
        errdefer allocator.free(candidate);
        const st = Io.Dir.cwd().statFile(io, candidate, .{}) catch {
            allocator.free(candidate);
            continue;
        };
        if (st.kind == .directory) {
            allocator.free(candidate);
            continue;
        }
        if (st.permissions.toMode() & 0o111 == 0) {
            allocator.free(candidate);
            continue;
        }
        return candidate;
    }
    return null;
}

/// Load a kernel module using modprobe.
pub fn loadModule(io: Io, name: []const u8) !void {
    const modprobe_path = constants.dir_et_sbin ++ "/modprobe";

    var child = std.process.spawn(io, .{
        .argv = &[_][]const u8{ modprobe_path, name },
        .stderr = .pipe,
    }) catch |err| {
        std.log.err("failed to spawn modprobe for {s}: {s}", .{ name, @errorName(err) });
        return err;
    };

    const result = child.wait(io) catch |err| {
        std.log.err("failed to wait for modprobe {s}: {s}", .{ name, @errorName(err) });
        return err;
    };

    if (result.exited != 0) {
        std.log.err("modprobe {s} failed with exit code {d}", .{ name, result.exited });
        return error.ModuleLoadFailed;
    }

    std.log.debug("loaded module {s}", .{name});
}

/// Load all kernel modules from the given slice.
pub fn loadModules(io: Io, modules: ?[]const []const u8) !void {
    const items = modules orelse return;
    for (items) |module| {
        try loadModule(io, module);
    }
}

/// Run all init scripts in order.
/// Each script is written to a temp file, made executable, run, then removed.
pub fn runInitScripts(
    allocator: Allocator,
    io: Io,
    scripts: ?[]const []const u8,
    env: ?[]const NameValue,
) !void {
    const items = scripts orelse return;
    for (items, 0..) |script, i| {
        try runInitScript(allocator, io, script, i, env);
    }
}

/// Run a single init script.
fn runInitScript(
    allocator: Allocator,
    io: Io,
    script: []const u8,
    index: usize,
    env: ?[]const NameValue,
) !void {
    var path_buf: [128]u8 = undefined;
    const path = fmt.bufPrint(
        &path_buf,
        "{s}/init-{d}",
        .{ constants.dir_et_run, index },
    ) catch {
        std.log.err("init script path too long", .{});
        return error.PathTooLong;
    };

    std.log.info("running init script {s}", .{path});

    const file = Io.Dir.createFileAbsolute(io, path, .{
        .permissions = .fromMode(0o755),
    }) catch |err| {
        std.log.err(
            "failed to create init script {s}: {s}",
            .{ path, @errorName(err) },
        );
        return err;
    };
    file.writeStreamingAll(io, script) catch |err| {
        std.log.err(
            "failed to write init script {s}: {s}",
            .{ path, @errorName(err) },
        );
        file.close(io);
        return err;
    };
    file.close(io);

    const argv = [_][]const u8{path};
    const pid = process.spawn(allocator, .{
        .argv = &argv,
        .env = env orelse &.{},
    }) catch |err| {
        Io.Dir.deleteFileAbsolute(io, path) catch {};
        return err;
    };

    // Parent process - wait for child
    var status: u32 = 0;
    while (true) {
        const wait_result = linux.waitpid(pid, &status, 0);
        const wait_err = std.posix.errno(wait_result);
        if (wait_err == .SUCCESS) break;
        if (wait_err == .INTR) continue;
        std.log.err("waitpid failed for init script: {s}", .{@tagName(wait_err)});
        Io.Dir.deleteFileAbsolute(io, path) catch {};
        return error.WaitFailed;
    }

    // Remove the script file
    Io.Dir.deleteFileAbsolute(io, path) catch |err| {
        std.log.warn("failed to remove init script {s}: {s}", .{ path, @errorName(err) });
    };

    if (linux.W.IFEXITED(status)) {
        const exit_code = linux.W.EXITSTATUS(status);
        if (exit_code != 0) {
            std.log.err(
                "unable to run init script {s}: exited with code {d}",
                .{ path, exit_code },
            );
            return error.InitScriptFailed;
        }
    } else if (linux.W.IFSIGNALED(status)) {
        const sig = linux.W.TERMSIG(status);
        std.log.err("unable to run init script {s}: killed by signal {d}", .{ path, sig });
        return error.InitScriptFailed;
    }

    std.log.debug("init script {s} completed successfully", .{path});
}

/// Write a sysctl value to /proc/sys.
/// Converts dotted key (e.g., "net.ipv4.ip_forward") to path (/proc/sys/net/ipv4/ip_forward).
pub fn sysctl(io: Io, key: []const u8, value: []const u8) !void {
    var path_buf: [256]u8 = undefined;
    const path = procPathFromDotted(&path_buf, key) catch |err| {
        std.log.err("sysctl key too long: {s}", .{key});
        return err;
    };

    const file = Io.Dir.openFileAbsolute(io, path, .{ .mode = .write_only }) catch |err| {
        std.log.err("failed to open {s}: {s}", .{ path, @errorName(err) });
        return err;
    };
    defer file.close(io);

    file.writeStreamingAll(io, value) catch |err| {
        std.log.err("failed to write to {s}: {s}", .{ path, @errorName(err) });
        return err;
    };

    std.log.debug("set sysctl {s}={s}", .{ key, value });
}

/// Apply all sysctls from the given slice.
pub fn setSysctls(io: Io, sysctls: ?[]const NameValue) !void {
    const items = sysctls orelse return;
    for (items) |nv| {
        try sysctl(io, nv.name, nv.value);
    }
}

/// Convert dotted sysctl key to /proc/sys path.
/// e.g., "net.ipv4.ip_forward" -> "/proc/sys/net/ipv4/ip_forward"
fn procPathFromDotted(buf: []u8, key: []const u8) ![]const u8 {
    const prefix = constants.dir_proc ++ "/sys/";
    if (prefix.len + key.len > buf.len) return error.BufferTooSmall;

    @memcpy(buf[0..prefix.len], prefix);
    var pos: usize = prefix.len;

    for (key) |c| {
        if (c == '.') {
            buf[pos] = '/';
        } else {
            buf[pos] = c;
        }
        pos += 1;
    }

    return buf[0..pos];
}

const RootDevices = struct {
    partition: []const u8,
    disk: []const u8,
};

/// Resize root EBS volume partition and filesystem if the
/// underlying disk was expanded. Gracefully skips if no block
/// device is found (e.g., when booting from initramfs).
pub fn resizeRootVolume(allocator: Allocator, io: Io) void {
    resizeRootVolumeImpl(allocator, io) catch |err| {
        std.log.debug(
            "skipping root volume resize: {s}",
            .{@errorName(err)},
        );
    };
}

fn resizeRootVolumeImpl(allocator: Allocator, io: Io) !void {
    var part_buf: [64]u8 = undefined;
    var disk_buf: [64]u8 = undefined;
    const devices = try findRootDevices(
        io,
        &part_buf,
        &disk_buf,
    );

    var disk_path_buf: [128]u8 = undefined;
    const disk_path = try fmt.bufPrint(
        &disk_path_buf,
        "{s}/{s}",
        .{ constants.dir_dev, devices.disk },
    );
    std.log.debug(
        "root disk device path: {s}",
        .{disk_path},
    );

    var gpt_ctx = GptContext.init(
        allocator,
        io,
        disk_path,
    ) catch |err| {
        std.log.err(
            "unable to open {s} for resize: {s}",
            .{ disk_path, @errorName(err) },
        );
        return err;
    };
    defer gpt_ctx.deinit();

    try gpt_ctx.load();

    const header = gpt_ctx.primary_header orelse
        return error.InvalidState;
    const first_usable: i64 = @intCast(
        header.getFirstUsableLba(),
    );
    std.log.debug(
        "first usable sector: {d}",
        .{first_usable},
    );

    const disk_sectors = try diskSectors(io, devices.disk);

    // Calculate last usable sector from actual disk size.
    // Formula from growpart: accounts for backup GPT
    // and alignment.
    const alignment: i64 = 2048;
    const gpt_len = first_usable - 2;
    const last_usable: u64 = @intCast(
        @divTrunc(
            disk_sectors - gpt_len - 1,
            alignment,
        ) * alignment,
    );
    std.log.debug(
        "last usable sector: {d}",
        .{last_usable},
    );

    const entries = gpt_ctx.partition_entries orelse
        return error.InvalidState;
    var root_entry: ?*GptEntry = null;
    var part_num: u32 = 0;
    for (entries, 0..) |*entry, i| {
        if (entry.isEmpty()) continue;
        const name = entry.getName(
            allocator,
        ) catch continue;
        defer allocator.free(name);
        if (std.mem.eql(u8, name, "root")) {
            root_entry = entry;
            part_num = @intCast(i + 1);
            break;
        }
    }
    const entry = root_entry orelse {
        std.log.err("root partition not found", .{});
        return error.PartitionNotFound;
    };

    // Don't resize if within 1 MiB of max (a la growpart).
    const fudge: u64 = 1024 * 1024 / 512;
    if (entry.getEndLba() >= last_usable -| fudge) {
        std.log.debug(
            "root partition already at maximum size",
            .{},
        );
        return;
    }

    const first_lba = entry.getStartLba();
    std.log.info(
        "resizing partition from sector {d} to {d}",
        .{ entry.getEndLba(), last_usable },
    );

    entry.setLbaRange(first_lba, last_usable);

    // Update header for expanded disk.
    gpt_ctx.primary_header.?.last_usable_lba =
        std.mem.nativeToLittle(u64, last_usable);
    gpt_ctx.primary_header.?.alternate_lba =
        std.mem.nativeToLittle(
            u64,
            @as(u64, @intCast(disk_sectors)) - 1,
        );

    try gpt_ctx.save();

    resizePartition(
        gpt_ctx.device_file.handle,
        @intCast(part_num),
        @intCast(first_lba),
        @intCast(last_usable),
        512,
    ) catch |err| {
        std.log.err(
            "unable to reread partition table: {s}",
            .{@errorName(err)},
        );
        return err;
    };

    var part_path_buf: [128]u8 = undefined;
    const part_path = try fmt.bufPrint(
        &part_path_buf,
        "{s}/{s}",
        .{ constants.dir_dev, devices.partition },
    );
    std.log.debug("growing root filesystem", .{});
    try growFilesystem(io, part_path);
}

fn findRootDevices(
    io: Io,
    part_buf: []u8,
    disk_buf: []u8,
) !RootDevices {
    const mounts_path = constants.dir_proc ++ "/mounts";
    const file = Io.Dir.openFileAbsolute(
        io,
        mounts_path,
        .{},
    ) catch |err| {
        std.log.err(
            "unable to open {s}: {s}",
            .{ mounts_path, @errorName(err) },
        );
        return err;
    };
    defer file.close(io);

    var read_buf: [8192]u8 = undefined;
    var rbuf: [4096]u8 = undefined;
    var reader = file.reader(io, &rbuf);
    const bytes_read = try reader.interface.readSliceShort(&read_buf);
    const content = read_buf[0..bytes_read];

    var partition_name: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(
            u8,
            line,
            ' ',
        );
        const device = fields.next() orelse continue;
        const mount_point = fields.next() orelse
            continue;

        if (!std.mem.eql(u8, mount_point, "/")) continue;
        if (!std.mem.startsWith(u8, device, "/dev/"))
            continue;

        const pname = device[5..];
        if (pname.len > part_buf.len) continue;
        @memcpy(part_buf[0..pname.len], pname);
        partition_name = part_buf[0..pname.len];
        break;
    }

    const part_name = partition_name orelse {
        return error.RootDeviceNotFound;
    };
    std.log.debug("root partition: {s}", .{part_name});

    var dir = Io.Dir.openDirAbsolute(
        io,
        sys_block_path,
        .{ .iterate = true },
    ) catch |err| {
        std.log.err(
            "unable to open {s}: {s}",
            .{ sys_block_path, @errorName(err) },
        );
        return err;
    };
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |dir_entry| {
        var abs_buf: [384]u8 = undefined;
        const abs_path = fmt.bufPrint(
            &abs_buf,
            "{s}/{s}/{s}",
            .{
                sys_block_path,
                dir_entry.name,
                part_name,
            },
        ) catch continue;

        Io.Dir.accessAbsolute(
            io,
            abs_path,
            .{},
        ) catch continue;

        const dn = dir_entry.name;
        if (dn.len > disk_buf.len) continue;
        @memcpy(disk_buf[0..dn.len], dn);
        return RootDevices{
            .partition = part_name,
            .disk = disk_buf[0..dn.len],
        };
    }

    return error.ParentDiskNotFound;
}

fn diskSectors(io: Io, device: []const u8) !i64 {
    var path_buf: [256]u8 = undefined;
    const path = try fmt.bufPrint(
        &path_buf,
        "{s}/{s}/size",
        .{ sys_block_path, device },
    );
    return intFromFile(io, path);
}

fn intFromFile(io: Io, path: []const u8) !i64 {
    const file = Io.Dir.openFileAbsolute(
        io,
        path,
        .{},
    ) catch |err| {
        std.log.err(
            "unable to open {s}: {s}",
            .{ path, @errorName(err) },
        );
        return err;
    };
    defer file.close(io);

    var buf: [64]u8 = undefined;
    var rbuf: [128]u8 = undefined;
    var reader = file.reader(io, &rbuf);
    const bytes_read = try reader.interface.readSliceShort(&buf);
    const content = std.mem.trim(
        u8,
        buf[0..bytes_read],
        " \t\r\n",
    );
    return std.fmt.parseInt(i64, content, 10) catch |err| {
        std.log.err(
            "unable to parse contents of {s}: {s}",
            .{ path, @errorName(err) },
        );
        return err;
    };
}

fn growFilesystem(io: Io, device_path: []const u8) !void {
    const resize2fs =
        constants.dir_et_sbin ++ "/resize2fs";

    var child = std.process.spawn(io, .{
        .argv = &[_][]const u8{ resize2fs, device_path },
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |err| {
        std.log.err(
            "failed to spawn resize2fs for {s}: {s}",
            .{ device_path, @errorName(err) },
        );
        return err;
    };

    const result = child.wait(io) catch |err| {
        std.log.err(
            "failed to wait for resize2fs {s}: {s}",
            .{ device_path, @errorName(err) },
        );
        return err;
    };

    if (result.exited != 0) {
        std.log.err(
            "resize2fs {s} failed with exit code {d}",
            .{ device_path, result.exited },
        );
        return error.ResizeFsFailed;
    }
}

test "procPathFromDotted" {
    var buf: [256]u8 = undefined;
    const result = try procPathFromDotted(&buf, "net.ipv4.ip_forward");
    try testing.expectEqualStrings("/proc/sys/net/ipv4/ip_forward", result);
}

test "procPathFromDotted single component" {
    var buf: [256]u8 = undefined;
    const result = try procPathFromDotted(&buf, "hostname");
    try testing.expectEqualStrings("/proc/sys/hostname", result);
}

test "deviceHasNumericSuffix" {
    try testing.expect(deviceHasNumericSuffix("") == false);
    try testing.expect(deviceHasNumericSuffix("sda") == false);
    try testing.expect(deviceHasNumericSuffix("sda1") == true);
    try testing.expect(deviceHasNumericSuffix("sda10") == true);
}

test "findExecutableInPath finds executable in first matching dir" {
    const allocator = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var bin_dir = try tmp.dir.createDirPathOpen(io, "bin", .{});
    defer bin_dir.close(io);
    const f = try bin_dir.createFile(io, "myprog", .{
        .permissions = .fromMode(0o755),
    });
    f.close(io);

    var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    const bin_abs_len = try tmp.dir.realPathFile(io, "bin", &abs_buf);
    const bin_abs = abs_buf[0..bin_abs_len];

    const path_var = try fmt.allocPrint(allocator, "/nonexistent:{s}", .{bin_abs});
    defer allocator.free(path_var);

    const result = try findExecutableInPath(allocator, io, path_var, "myprog");
    try testing.expect(result != null);
    defer allocator.free(result.?);

    const expected = try fmt.allocPrint(allocator, "{s}/myprog", .{bin_abs});
    defer allocator.free(expected);
    try testing.expectEqualStrings(expected, result.?);
}

test "findExecutableInPath returns null when not found" {
    const allocator = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_abs_len = try tmp.dir.realPathFile(io, ".", &abs_buf);
    const tmp_abs = abs_buf[0..tmp_abs_len];

    const result = try findExecutableInPath(allocator, io, tmp_abs, "nothere_xyzzy_12345");
    try testing.expect(result == null);
}

test "findExecutableInPath rejects non-executable files" {
    const allocator = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile(io, "notexe", .{
        .permissions = .fromMode(0o644),
    });
    f.close(io);

    var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_abs_len = try tmp.dir.realPathFile(io, ".", &abs_buf);
    const tmp_abs = abs_buf[0..tmp_abs_len];

    const result = try findExecutableInPath(allocator, io, tmp_abs, "notexe");
    try testing.expect(result == null);
}
