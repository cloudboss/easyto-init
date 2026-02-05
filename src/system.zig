const std = @import("std");
const linux = std.os.linux;
const fmt = std.fmt;
const posix = std.posix;
const Allocator = std.mem.Allocator;
const testing = std.testing;

const backoff = @import("backoff.zig");
const constants = @import("constants.zig");
const nvme = @import("nvme-amz.zig");
const NameValue = @import("vmspec.zig").NameValue;

const SYS_BLOCK_PATH = "/sys/block";

pub fn link_nvme_devices(allocator: Allocator) !void {
    var dir = try std.fs.openDirAbsolute(
        SYS_BLOCK_PATH,
        .{ .iterate = true },
    );
    defer dir.close();
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;
        const device_name = entry.name;

        linkNvmeDevice(allocator, device_name, null) catch {};

        var partitions = disk_partitions(
            allocator,
            device_name,
        ) catch continue;
        defer {
            for (partitions.items) |*p| p.deinit(allocator);
            partitions.deinit(allocator);
        }
        for (partitions.items) |partition| {
            linkNvmeDevice(
                allocator,
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
pub fn linkNvmeDevice(allocator: Allocator, device_name: []const u8, part_num: ?[]const u8) !void {
    var dev_path_buf: [128]u8 = undefined;
    const dev_path = try fmt.bufPrint(
        &dev_path_buf,
        "{s}/{s}",
        .{ constants.DIR_DEV, device_name },
    );

    const file = std.fs.openFileAbsolute(dev_path, .{}) catch |err| {
        std.log.err("unable to open {s}: {s}", .{ dev_path, @errorName(err) });
        return err;
    };
    defer file.close();

    var errno: usize = 0;
    var nvme_info = nvme.Nvme.from_fd(allocator, file.handle, &errno) catch {
        return;
    };
    defer nvme_info.deinit(allocator);

    std.log.debug("nvme device: {any}", .{nvme_info});

    const ec2_name = nvme_info.name() catch return;

    var link_name_buf: [128]u8 = undefined;
    const link_name = if (part_num) |pn|
        if (device_has_numeric_suffix(ec2_name))
            try fmt.bufPrint(&link_name_buf, "{s}p{s}", .{ ec2_name, pn })
        else
            try fmt.bufPrint(&link_name_buf, "{s}{s}", .{ ec2_name, pn })
    else
        ec2_name;

    var link_path_buf: [128]u8 = undefined;
    const link_path = try fmt.bufPrint(
        &link_path_buf,
        "{s}/{s}",
        .{ constants.DIR_DEV, link_name },
    );

    std.log.debug("linking {s} to {s}", .{ device_name, link_path });

    std.posix.symlink(device_name, link_path) catch |err| {
        if (err != error.PathAlreadyExists) {
            std.log.err(
                "unable to link {s} to {s}: {s}",
                .{ device_name, link_path, @errorName(err) },
            );
            return err;
        }
    };
}

fn disk_partitions(
    allocator: Allocator,
    device: []const u8,
) !std.ArrayList(PartitionInfo) {
    var path_buf: [128]u8 = undefined;
    const sys_device_path = try fmt.bufPrint(
        &path_buf,
        "{s}/{s}",
        .{ SYS_BLOCK_PATH, device },
    );

    var dir = std.fs.openDirAbsolute(
        sys_device_path,
        .{ .iterate = true },
    ) catch |err| {
        std.log.err(
            "unable to open {s}: {s}",
            .{ sys_device_path, @errorName(err) },
        );
        return err;
    };
    defer dir.close();
    var iter = dir.iterate();

    var partitions: std.ArrayList(PartitionInfo) = .empty;

    while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;
        if (!std.mem.startsWith(u8, entry.name, device)) continue;

        var pt_path_buf: [256]u8 = undefined;
        const pt_path = fmt.bufPrint(
            &pt_path_buf,
            "{s}/partition",
            .{entry.name},
        ) catch continue;

        const pt_file = dir.openFile(pt_path, .{}) catch continue;
        defer pt_file.close();

        const raw = pt_file.readToEndAlloc(allocator, 32) catch continue;
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

pub fn device_has_numeric_suffix(device: []const u8) bool {
    const len = device.len;
    if (len == 0) {
        return false;
    }
    return (device[len - 1] >= '0') and (device[len - 1] <= '9');
}

/// Check if a device has a filesystem using blkid.
/// Returns true if filesystem detected, false if no filesystem.
pub fn deviceHasFilesystem(device: []const u8) !bool {
    const blkid_path = constants.DIR_ET_SBIN ++ "/blkid";

    var child = std.process.Child.init(
        &[_][]const u8{ blkid_path, device },
        std.heap.page_allocator,
    );
    child.stderr_behavior = .Pipe;
    child.stdout_behavior = .Pipe;

    child.spawn() catch |err| {
        std.log.err("failed to run blkid for {s}: {s}", .{ device, @errorName(err) });
        return err;
    };

    const result = child.wait() catch |err| {
        std.log.err("failed to wait for blkid {s}: {s}", .{ device, @errorName(err) });
        return err;
    };

    return switch (result.Exited) {
        0 => true, // Filesystem detected
        2 => false, // No filesystem found
        else => {
            std.log.err("blkid {s} failed with exit code {d}", .{ device, result.Exited });
            return error.BlkidFailed;
        },
    };
}

/// Wait for a device to exist with exponential backoff.
pub fn waitForDevice(device: []const u8, timeout_secs: u64) !void {
    const timeout_ns: u64 = timeout_secs * std.time.ns_per_s;
    const start_time = std.time.nanoTimestamp();

    var retry = backoff.RetryBackoff.init(10000);

    while (true) {
        // Check if device exists
        if (std.fs.accessAbsolute(device, .{})) {
            std.log.debug("device {s} is available", .{device});
            return;
        } else |_| {}

        const elapsed: u64 = @intCast(std.time.nanoTimestamp() - start_time);
        if (elapsed > timeout_ns) {
            std.log.err("timeout waiting for device {s} to exist", .{device});
            return error.DeviceTimeout;
        }

        std.log.debug("waiting for device {s} to exist", .{device});
        retry.wait();
    }
}

/// Create a filesystem on a device if it doesn't have one.
pub fn createFilesystem(device: []const u8, fs_type: []const u8) !void {
    // Check if device already has a filesystem
    const has_fs = deviceHasFilesystem(device) catch |err| {
        std.log.err("unable to check if {s} has a filesystem: {s}", .{ device, @errorName(err) });
        return err;
    };

    if (has_fs) {
        std.log.debug("device {s} already has a filesystem", .{device});
        return;
    }

    // Build mkfs path
    var mkfs_buf: [128]u8 = undefined;
    const mkfs_path = fmt.bufPrint(&mkfs_buf, "{s}/mkfs.{s}", .{ constants.DIR_ET_SBIN, fs_type }) catch {
        std.log.err("mkfs path too long for {s}", .{fs_type});
        return error.PathTooLong;
    };

    // Check if mkfs tool exists
    std.fs.accessAbsolute(mkfs_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            std.log.err("unsupported filesystem {s} for {s}", .{ fs_type, device });
            return error.UnsupportedFilesystem;
        }
        std.log.err("unable to access {s}: {s}", .{ mkfs_path, @errorName(err) });
        return err;
    };

    std.log.info("creating {s} filesystem on {s}", .{ fs_type, device });

    // Create null-terminated path for execve
    var mkfs_z_buf: [129]u8 = undefined;
    @memcpy(mkfs_z_buf[0..mkfs_path.len], mkfs_path);
    mkfs_z_buf[mkfs_path.len] = 0;
    const mkfs_z: [*:0]const u8 = @ptrCast(&mkfs_z_buf);

    // Create null-terminated device path
    var device_z_buf: [256]u8 = undefined;
    @memcpy(device_z_buf[0..device.len], device);
    device_z_buf[device.len] = 0;
    const device_z: [*:0]const u8 = @ptrCast(&device_z_buf);

    // Fork and exec mkfs
    const pid_result = linux.fork();
    const pid_err = posix.errno(pid_result);
    if (pid_err != .SUCCESS) {
        std.log.err("fork failed for mkfs: {s}", .{@tagName(pid_err)});
        return error.ForkFailed;
    }

    const pid: posix.pid_t = @intCast(pid_result);
    if (pid == 0) {
        // Child process - exec mkfs
        const argv = [_:null]?[*:0]const u8{ mkfs_z, device_z };
        const envp = [_:null]?[*:0]const u8{};
        const exec_result = linux.execve(mkfs_z, &argv, &envp);
        const exec_err = posix.errno(exec_result);
        std.log.err("unable to run mkfs: {s}", .{@tagName(exec_err)});
        linux.exit(127);
    }

    // Parent process - wait for child
    var status: u32 = 0;
    while (true) {
        const wait_result = linux.waitpid(pid, &status, 0);
        const wait_err = posix.errno(wait_result);
        if (wait_err == .SUCCESS) break;
        if (wait_err == .INTR) continue;
        std.log.err("waitpid failed for mkfs: {s}", .{@tagName(wait_err)});
        return error.WaitFailed;
    }

    // Check exit status
    if (linux.W.IFEXITED(status)) {
        const exit_code = linux.W.EXITSTATUS(status);
        if (exit_code != 0) {
            std.log.err("mkfs.{s} {s} failed with exit code {d}", .{ fs_type, device, exit_code });
            return error.MkfsFailed;
        }
    } else if (linux.W.IFSIGNALED(status)) {
        const sig = linux.W.TERMSIG(status);
        std.log.err("mkfs.{s} {s} killed by signal {d}", .{ fs_type, device, sig });
        return error.MkfsFailed;
    }

    std.log.info("created {s} filesystem on {s}", .{ fs_type, device });
}

/// Mount a device to a destination.
pub fn mountDevice(device: []const u8, destination: []const u8, fs_type: []const u8) !void {
    const fs_utils = @import("fs.zig");

    // Create mount point if it doesn't exist
    fs_utils.mkdir_p(destination, 0o755) catch |err| {
        std.log.err("failed to create mount point {s}: {s}", .{ destination, @errorName(err) });
        return err;
    };

    // Mount the device
    const ret = linux.mount(
        @ptrCast(device),
        @ptrCast(destination),
        @ptrCast(fs_type),
        0, // No special flags
        0, // No mount data
    );
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

/// Load a kernel module using modprobe.
pub fn loadModule(name: []const u8) !void {
    const modprobe_path = constants.DIR_ET_SBIN ++ "/modprobe";

    var child = std.process.Child.init(
        &[_][]const u8{ modprobe_path, name },
        std.heap.page_allocator,
    );
    child.stderr_behavior = .Pipe;

    child.spawn() catch |err| {
        std.log.err("failed to run modprobe for {s}: {s}", .{ name, @errorName(err) });
        return err;
    };

    const result = child.wait() catch |err| {
        std.log.err("failed to wait for modprobe {s}: {s}", .{ name, @errorName(err) });
        return err;
    };

    if (result.Exited != 0) {
        std.log.err("modprobe {s} failed with exit code {d}", .{ name, result.Exited });
        return error.ModuleLoadFailed;
    }

    std.log.debug("loaded module {s}", .{name});
}

/// Load all kernel modules from the given slice.
pub fn loadModules(modules: ?[]const []const u8) !void {
    const items = modules orelse return;
    for (items) |module| {
        try loadModule(module);
    }
}

/// Run all init scripts in order.
/// Each script is written to a temp file, made executable, run, then removed.
pub fn runInitScripts(scripts: ?[]const []const u8, env: ?[]const NameValue) !void {
    const items = scripts orelse return;
    for (items, 0..) |script, i| {
        try runInitScript(script, i, env);
    }
}

/// Run a single init script.
fn runInitScript(script: []const u8, index: usize, env: ?[]const NameValue) !void {
    _ = env; // Environment passing not yet implemented for init scripts

    // Build script path: /.easyto/run/init-{index}
    var path_buf: [128]u8 = undefined;
    const path_len = fmt.bufPrint(
        &path_buf,
        "{s}/init-{d}",
        .{ constants.DIR_ET_RUN, index },
    ) catch {
        std.log.err("init script path too long", .{});
        return error.PathTooLong;
    };
    const path = path_len;

    std.log.info("running init script {s}", .{path});

    // Write script to file with executable permissions
    const file = std.fs.createFileAbsolute(path, .{ .mode = 0o755 }) catch |err| {
        std.log.err("failed to create init script {s}: {s}", .{ path, @errorName(err) });
        return err;
    };
    file.writeAll(script) catch |err| {
        std.log.err("failed to write init script {s}: {s}", .{ path, @errorName(err) });
        file.close();
        return err;
    };
    file.close();

    // Create null-terminated path for execve
    var path_z_buf: [129]u8 = undefined;
    @memcpy(path_z_buf[0..path.len], path);
    path_z_buf[path.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(&path_z_buf);

    // Execute the script using fork/exec - kernel handles shebang
    const pid_result = linux.fork();
    const pid_err = std.posix.errno(pid_result);
    if (pid_err != .SUCCESS) {
        std.log.err("fork failed for init script: {s}", .{@tagName(pid_err)});
        std.fs.deleteFileAbsolute(path) catch {};
        return error.ForkFailed;
    }

    const pid: std.posix.pid_t = @intCast(pid_result);
    if (pid == 0) {
        // Child process - exec the script directly (kernel handles shebang)
        const argv = [_:null]?[*:0]const u8{path_z};
        const envp = [_:null]?[*:0]const u8{};
        const exec_result = linux.execve(path_z, &argv, &envp);
        const exec_err = std.posix.errno(exec_result);
        std.log.err("unable to run init script: {s}", .{@tagName(exec_err)});
        linux.exit(127);
    }

    // Parent process - wait for child
    var status: u32 = 0;
    while (true) {
        const wait_result = linux.waitpid(pid, &status, 0);
        const wait_err = std.posix.errno(wait_result);
        if (wait_err == .SUCCESS) break;
        if (wait_err == .INTR) continue;
        std.log.err("waitpid failed for init script: {s}", .{@tagName(wait_err)});
        std.fs.deleteFileAbsolute(path) catch {};
        return error.WaitFailed;
    }

    // Remove the script file
    std.fs.deleteFileAbsolute(path) catch |err| {
        std.log.warn("failed to remove init script {s}: {s}", .{ path, @errorName(err) });
    };

    // Check exit status
    if (linux.W.IFEXITED(status)) {
        const exit_code = linux.W.EXITSTATUS(status);
        if (exit_code != 0) {
            std.log.err("init script {s} failed with exit code {d}", .{ path, exit_code });
            return error.InitScriptFailed;
        }
    } else if (linux.W.IFSIGNALED(status)) {
        const sig = linux.W.TERMSIG(status);
        std.log.err("init script {s} killed by signal {d}", .{ path, sig });
        return error.InitScriptFailed;
    }

    std.log.debug("init script {s} completed successfully", .{path});
}

/// Write a sysctl value to /proc/sys.
/// Converts dotted key (e.g., "net.ipv4.ip_forward") to path (/proc/sys/net/ipv4/ip_forward).
pub fn sysctl(key: []const u8, value: []const u8) !void {
    var path_buf: [256]u8 = undefined;
    const path = procPathFromDotted(&path_buf, key) catch |err| {
        std.log.err("sysctl key too long: {s}", .{key});
        return err;
    };

    const file = std.fs.openFileAbsolute(path, .{ .mode = .write_only }) catch |err| {
        std.log.err("failed to open {s}: {s}", .{ path, @errorName(err) });
        return err;
    };
    defer file.close();

    file.writeAll(value) catch |err| {
        std.log.err("failed to write to {s}: {s}", .{ path, @errorName(err) });
        return err;
    };

    std.log.debug("set sysctl {s}={s}", .{ key, value });
}

/// Apply all sysctls from the given slice.
pub fn setSysctls(sysctls: ?[]const NameValue) !void {
    const items = sysctls orelse return;
    for (items) |nv| {
        try sysctl(nv.name, nv.value);
    }
}

/// Convert dotted sysctl key to /proc/sys path.
/// e.g., "net.ipv4.ip_forward" -> "/proc/sys/net/ipv4/ip_forward"
fn procPathFromDotted(buf: []u8, key: []const u8) ![]const u8 {
    const prefix = constants.DIR_PROC ++ "/sys/";
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

test "device_has_numeric_suffix" {
    try testing.expect(device_has_numeric_suffix("") == false);
    try testing.expect(device_has_numeric_suffix("sda") == false);
    try testing.expect(device_has_numeric_suffix("sda1") == true);
    try testing.expect(device_has_numeric_suffix("sda10") == true);
}
