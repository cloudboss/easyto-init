const std = @import("std");
const linux = std.os.linux;
const fmt = std.fmt;
const Allocator = std.mem.Allocator;
const testing = std.testing;

const constants = @import("constants.zig");
const nvme = @import("nvme-amz.zig");
const NameValue = @import("vmspec.zig").NameValue;

const SYS_BLOCK_PATH = "/sys/block";

pub fn link_nvme_devices(allocator: Allocator) !void {
    var dir = try std.fs.openDirAbsolute(SYS_BLOCK_PATH, .{ .iterate = true });
    defer dir.close();
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != std.fs.File.Kind.directory) continue;
        const device_name = entry.name;
        var device_dir = try dir.openDir(device_name, .{});
        defer device_dir.close();
        var errno: usize = 0;
        var nvme_info = nvme.Nvme.from_fd(allocator, device_dir.fd, &errno) catch {
            continue;
        };
        defer nvme_info.deinit(allocator);
        const ec2_device_name = try nvme_info.name();
        var buf: [128]u8 = undefined;
        const device_link_path = try fmt.bufPrint(
            &buf,
            "{s}/{s}",
            .{ constants.DIR_DEV, ec2_device_name },
        );
        try std.posix.link(device_name, device_link_path);

        // Link partitions too if they exist.
        var partitions = try disk_partitions(allocator, device_name);
        defer {
            for (partitions.items) |*p| p.deinit(allocator);
            partitions.deinit(allocator);
        }
        for (partitions.items) |*partition| {
            var pt_buf: [128]u8 = undefined;
            const partition_name = if (device_has_numeric_suffix(ec2_device_name))
                try fmt.bufPrint(&pt_buf, "{s}p{s}", .{ ec2_device_name, partition.partition })
            else
                try fmt.bufPrint(&pt_buf, "{s}{s}", .{ ec2_device_name, partition.partition });
            var pt_lnk_buf: [128]u8 = undefined;
            const partition_link_path = try fmt.bufPrint(
                &pt_lnk_buf,
                "{s}/{s}",
                .{ constants.DIR_DEV, partition_name },
            );
            try std.posix.link(partition.device, partition_link_path);
        }
    }
}

pub const PartitionInfo = struct {
    device: []const u8,
    partition: []const u8,

    pub fn deinit(self: *PartitionInfo, allocator: Allocator) void {
        allocator.free(self.partition);
    }
};

pub fn disk_partitions(allocator: Allocator, device: []const u8) !std.ArrayList(PartitionInfo) {
    var buf: [128]u8 = undefined;
    const sys_device_path = try fmt.bufPrint(&buf, "{s}/{s}", .{ SYS_BLOCK_PATH, device });

    var dir = try std.fs.openDirAbsolute(sys_device_path, .{ .iterate = true });
    defer dir.close();
    var iter = dir.iterate();

    var partitions = try std.ArrayList(PartitionInfo).initCapacity(allocator, 10);

    while (try iter.next()) |entry| {
        if (entry.kind != std.fs.File.Kind.directory) continue;
        if (!std.ascii.eqlIgnoreCase(entry.name, device)) continue;
        var pt_buf: [128]u8 = undefined;
        const partition_path = try fmt.bufPrint(&pt_buf, "{s}/partition", .{sys_device_path});
        const partition_file = try dir.openFile(partition_path, .{});
        const partition = try partition_file.readToEndAlloc(allocator, 32);
        try partitions.append(allocator, PartitionInfo{ .device = device, .partition = partition });
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
