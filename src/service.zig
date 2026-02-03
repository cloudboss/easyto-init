const std = @import("std");
const Allocator = std.mem.Allocator;
const linux = std.os.linux;
const posix = std.posix;
const testing = std.testing;

const constants = @import("constants.zig");
const vmspec = @import("vmspec.zig");
const NameValue = vmspec.NameValue;

const SIGPOWEROFF: u6 = 38;
const PF_KTHREAD: u32 = 0x00200000;
const FLAGS_FIELD_INDEX: usize = 8;

var shutdown_requested = std.atomic.Value(bool).init(false);

/// Request a graceful shutdown. Called by spot termination monitor.
pub fn requestShutdown() void {
    shutdown_requested.store(true, .release);
}

/// Check if shutdown has been requested.
pub fn isShutdownRequested() bool {
    return shutdown_requested.load(.acquire);
}

pub const Supervisor = struct {
    allocator: Allocator,
    command: []const []const u8,
    args: ?[]const []const u8,
    env: ?[]const NameValue,
    working_dir: []const u8,
    uid: u32,
    gid: u32,
    shutdown_grace_period: u64,
    main_pid: ?posix.pid_t = null,

    pub fn init(
        allocator: Allocator,
        command: []const []const u8,
        args: ?[]const []const u8,
        env: ?[]const NameValue,
        working_dir: []const u8,
        uid: u32,
        gid: u32,
        shutdown_grace_period: u64,
    ) Supervisor {
        return Supervisor{
            .allocator = allocator,
            .command = command,
            .args = args,
            .env = env,
            .working_dir = working_dir,
            .uid = uid,
            .gid = gid,
            .shutdown_grace_period = shutdown_grace_period,
        };
    }

    pub fn start(self: *Supervisor) !void {
        setup_signal_handlers();

        std.log.info("starting main process: {s}", .{self.command[0]});

        const pid = try self.spawn_process();
        self.main_pid = pid;
        std.log.info("main process started with pid {d}", .{pid});
    }

    pub fn wait(self: *Supervisor) void {
        var main_exited = false;

        while (true) {
            if (shutdown_requested.load(.acquire) and !main_exited) {
                std.log.info("shutdown requested, terminating processes", .{});
                self.graceful_shutdown();
                return;
            }

            var status: u32 = 0;
            const result = linux.wait4(-1, &status, linux.W.NOHANG, null);
            const e = posix.errno(result);

            if (result > 0) {
                const reaped_pid: posix.pid_t = @intCast(result);
                std.log.debug("reaped process {d}", .{reaped_pid});
                if (self.main_pid != null and reaped_pid == self.main_pid.?) {
                    std.log.info("main process exited", .{});
                    main_exited = true;
                    self.graceful_shutdown();
                    return;
                }
            } else if (e == .CHILD) {
                if (main_exited) {
                    std.log.info("all processes exited", .{});
                    return;
                }
                std.Thread.sleep(10 * std.time.ns_per_ms);
            } else if (result == 0) {
                std.Thread.sleep(10 * std.time.ns_per_ms);
            }

            if (shutdown_requested.load(.acquire) and !main_exited) {
                std.log.info("shutdown requested, terminating processes", .{});
                self.graceful_shutdown();
                return;
            }
        }
    }

    fn graceful_shutdown(self: *Supervisor) void {
        std.log.info("sending SIGTERM to all processes", .{});
        self.signal_all(posix.SIG.TERM);

        const grace_ns = self.shutdown_grace_period * std.time.ns_per_s;
        const start_time = std.time.nanoTimestamp();

        while (true) {
            const elapsed: u64 = @intCast(std.time.nanoTimestamp() - start_time);
            if (elapsed >= grace_ns) {
                break;
            }

            var status: u32 = 0;
            const result = linux.wait4(-1, &status, linux.W.NOHANG, null);
            const e = posix.errno(result);

            if (e == .CHILD) {
                std.log.info("all processes exited during grace period", .{});
                return;
            }

            if (result == 0) {
                std.Thread.sleep(100 * std.time.ns_per_ms);
            }
        }

        std.log.info("grace period expired, sending SIGKILL to all processes", .{});
        self.signal_all(posix.SIG.KILL);

        while (true) {
            var status: u32 = 0;
            const result = linux.wait4(-1, &status, 0, null);
            const e = posix.errno(result);
            if (e == .CHILD) {
                break;
            }
        }
        std.log.info("all processes terminated", .{});
    }

    fn signal_all(self: *Supervisor, sig: u6) void {
        _ = self;
        const pids = get_all_pids() catch |err| {
            std.log.err("failed to enumerate pids: {s}", .{@errorName(err)});
            return;
        };
        defer std.heap.page_allocator.free(pids);

        for (pids) |pid| {
            _ = linux.kill(pid, sig);
        }
    }

    fn spawn_process(self: *Supervisor) !posix.pid_t {
        const command_len = self.command.len;
        const args_len = if (self.args) |a| a.len else 0;
        const total_len = command_len + args_len;

        var argv = try self.allocator.alloc(?[*:0]const u8, total_len + 1);
        defer self.allocator.free(argv);

        var arg_strings = try self.allocator.alloc([:0]const u8, total_len);
        var arg_strings_count: usize = 0;
        errdefer {
            for (arg_strings[0..arg_strings_count]) |s| self.allocator.free(s);
            self.allocator.free(arg_strings);
        }
        defer {
            for (arg_strings) |s| self.allocator.free(s);
            self.allocator.free(arg_strings);
        }

        for (self.command, 0..) |arg, i| {
            arg_strings[i] = try self.allocator.dupeZ(u8, arg);
            arg_strings_count += 1;
            argv[i] = arg_strings[i].ptr;
        }
        if (self.args) |args| {
            for (args, 0..) |arg, i| {
                arg_strings[command_len + i] = try self.allocator.dupeZ(u8, arg);
                arg_strings_count += 1;
                argv[command_len + i] = arg_strings[command_len + i].ptr;
            }
        }
        argv[total_len] = null;

        // Build environment: inherit from parent (kernel cmdline vars) + vmspec.env
        const env_result = try self.buildEnvironment();
        const envp = env_result.envp;
        const env_strings = env_result.env_strings;
        defer {
            for (env_strings) |s| self.allocator.free(s);
            self.allocator.free(env_strings);
            self.allocator.free(envp);
        }

        const pid_result = linux.fork();
        const pid_err = posix.errno(pid_result);
        if (pid_err != .SUCCESS) {
            std.log.err("fork failed: {s}", .{@tagName(pid_err)});
            return error.ForkFailed;
        }

        const pid: posix.pid_t = @intCast(pid_result);
        if (pid == 0) {
            self.exec_child(argv, envp);
        }

        return pid;
    }

    fn exec_child(self: *Supervisor, argv: []?[*:0]const u8, envp: []?[*:0]const u8) noreturn {
        posix.chdir(self.working_dir) catch |err| {
            std.log.err("chdir to {s} failed: {s}", .{ self.working_dir, @errorName(err) });
            linux.exit(1);
        };

        if (self.gid != 0) {
            const ret = linux.setgid(self.gid);
            const e = posix.errno(ret);
            if (e != .SUCCESS) {
                std.log.err("setgid({d}) failed: {s}", .{ self.gid, @tagName(e) });
                linux.exit(1);
            }
        }

        if (self.uid != 0) {
            const ret = linux.setuid(self.uid);
            const e = posix.errno(ret);
            if (e != .SUCCESS) {
                std.log.err("setuid({d}) failed: {s}", .{ self.uid, @tagName(e) });
                linux.exit(1);
            }
        }

        const exec_result = linux.execve(
            argv[0].?,
            @ptrCast(argv.ptr),
            @ptrCast(envp.ptr),
        );
        const exec_err = posix.errno(exec_result);
        std.log.err("execve failed: {s}", .{errnoDescription(exec_err)});
        linux.exit(1);
    }

    const EnvResult = struct {
        envp: []?[*:0]const u8,
        env_strings: [][:0]const u8,
    };

    /// Build environment by merging parent environment with vmspec.env.
    /// vmspec.env values take precedence over parent environment.
    fn buildEnvironment(self: *Supervisor) !EnvResult {
        // Use a map to merge environments (vmspec.env overrides parent)
        var env_map = std.StringHashMap([]const u8).init(self.allocator);
        defer env_map.deinit();

        // First, add all parent environment variables
        const parent_env = std.os.environ;
        for (parent_env) |env_ptr| {
            const env_str = std.mem.span(env_ptr);
            if (std.mem.indexOf(u8, env_str, "=")) |eq_pos| {
                const name = env_str[0..eq_pos];
                const value = env_str[eq_pos + 1 ..];
                try env_map.put(name, value);
            }
        }

        // Override with vmspec.env values
        if (self.env) |env| {
            for (env) |nv| {
                try env_map.put(nv.name, nv.value);
            }
        }

        // Build the envp array
        const env_count = env_map.count();
        var envp = try self.allocator.alloc(?[*:0]const u8, env_count + 1);
        errdefer self.allocator.free(envp);
        var env_strings = try self.allocator.alloc([:0]const u8, env_count);
        errdefer self.allocator.free(env_strings);

        var idx: usize = 0;
        var iter = env_map.iterator();
        while (iter.next()) |entry| {
            const env_str = try std.fmt.allocPrint(self.allocator, "{s}={s}", .{ entry.key_ptr.*, entry.value_ptr.* });
            defer self.allocator.free(env_str);
            env_strings[idx] = try self.allocator.dupeZ(u8, env_str);
            envp[idx] = env_strings[idx].ptr;
            idx += 1;
        }
        envp[env_count] = null;

        return .{ .envp = envp, .env_strings = env_strings };
    }

    /// Build argv array from command and args slices. Exported for testing.
    pub fn buildArgv(self: *const Supervisor) !struct { argv: []?[*:0]const u8, arg_strings: [][:0]const u8 } {
        const command_len = self.command.len;
        const args_len = if (self.args) |a| a.len else 0;
        const total_len = command_len + args_len;

        var argv = try self.allocator.alloc(?[*:0]const u8, total_len + 1);
        errdefer self.allocator.free(argv);

        var arg_strings = try self.allocator.alloc([:0]const u8, total_len);
        var arg_strings_count: usize = 0;
        errdefer {
            for (arg_strings[0..arg_strings_count]) |s| self.allocator.free(s);
            self.allocator.free(arg_strings);
        }

        for (self.command, 0..) |arg, i| {
            arg_strings[i] = try self.allocator.dupeZ(u8, arg);
            arg_strings_count += 1;
            argv[i] = arg_strings[i].ptr;
        }
        if (self.args) |args| {
            for (args, 0..) |arg, i| {
                arg_strings[command_len + i] = try self.allocator.dupeZ(u8, arg);
                arg_strings_count += 1;
                argv[command_len + i] = arg_strings[command_len + i].ptr;
            }
        }
        argv[total_len] = null;

        return .{ .argv = argv, .arg_strings = arg_strings };
    }
};

fn setup_signal_handlers() void {
    const handler = posix.Sigaction{
        .handler = .{ .handler = signal_handler },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };

    posix.sigaction(posix.SIG.TERM, &handler, null);
    posix.sigaction(posix.SIG.INT, &handler, null);
    posix.sigaction(SIGPOWEROFF, &handler, null);
}

fn signal_handler(sig: c_int) callconv(.c) void {
    _ = sig;
    shutdown_requested.store(true, .release);
}

fn get_all_pids() ![]posix.pid_t {
    var pids = std.ArrayList(posix.pid_t).initCapacity(std.heap.page_allocator, 100) catch {
        return error.OutOfMemory;
    };
    errdefer pids.deinit(std.heap.page_allocator);

    var dir = std.fs.openDirAbsolute(constants.DIR_PROC, .{ .iterate = true }) catch |err| {
        std.log.err("failed to open {s}: {s}", .{ constants.DIR_PROC, @errorName(err) });
        return err;
    };
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;

        const pid = std.fmt.parseInt(posix.pid_t, entry.name, 10) catch continue;
        if (pid == 1) continue;
        if (is_kernel_thread(pid)) continue;

        try pids.append(std.heap.page_allocator, pid);
    }

    return try pids.toOwnedSlice(std.heap.page_allocator);
}

/// Parse /proc/[pid]/stat content and determine if the process is a kernel thread.
/// Returns error if the content is malformed, otherwise returns true if kernel thread.
fn parseKernelThreadStatus(content: []const u8) !bool {
    const paren_end = std.mem.lastIndexOf(u8, content, ")") orelse return error.InvalidFormat;
    const after_comm = content[paren_end + 1 ..];

    var iter = std.mem.tokenizeScalar(u8, after_comm, ' ');
    var field_index: usize = 2;

    while (iter.next()) |field| {
        if (field_index == FLAGS_FIELD_INDEX) {
            const flags = std.fmt.parseInt(u32, field, 10) catch return error.InvalidFlags;
            return (flags & PF_KTHREAD) != 0;
        }
        field_index += 1;
    }

    return error.FieldNotFound;
}

pub fn errnoDescription(err: posix.E) []const u8 {
    return switch (err) {
        .NOENT => "No such file or directory",
        .ACCES => "Permission denied",
        .PERM => "Operation not permitted",
        .IO => "Input/output error",
        .NOTDIR => "Not a directory",
        .ISDIR => "Is a directory",
        .NOEXEC => "Exec format error",
        .TXTBSY => "Text file busy",
        .NOMEM => "Cannot allocate memory",
        .FAULT => "Bad address",
        .NAMETOOLONG => "File name too long",
        .LOOP => "Too many levels of symbolic links",
        else => @tagName(err),
    };
}

fn is_kernel_thread(pid: posix.pid_t) bool {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/stat", .{pid}) catch return true;

    const file = std.fs.openFileAbsolute(path, .{}) catch return true;
    defer file.close();

    var buf: [512]u8 = undefined;
    const bytes_read = file.read(&buf) catch return true;
    const content = buf[0..bytes_read];

    return parseKernelThreadStatus(content) catch true;
}

test "is_kernel_thread returns false for init process" {
    try testing.expect(!is_kernel_thread(1));
}

test "get_all_pids does not include pid 1" {
    const pids = try get_all_pids();
    defer std.heap.page_allocator.free(pids);

    for (pids) |pid| {
        try testing.expect(pid != 1);
    }
}

// Test parseKernelThreadStatus with realistic /proc/[pid]/stat content
test "parseKernelThreadStatus with normal process" {
    // Real example from /proc/1/stat - init is not a kernel thread (flags don't have PF_KTHREAD)
    const content = "1 (init) S 0 1 1 0 -1 4194560 1234 0 0 0 10 5 0 0 20 0 1 0 1 12345678 1024 18446744073709551615 0 0 0 0 0 0 0 0 65536 0 0 0 17 0 0 0 0 0 0 0 0 0 0 0 0 0 0";
    const is_kthread = try parseKernelThreadStatus(content);
    try testing.expect(!is_kthread);
}

test "parseKernelThreadStatus with kernel thread" {
    // Kernel thread has PF_KTHREAD (0x00200000 = 2097152) set in flags field
    const content = "2 (kthreadd) S 0 0 0 0 -1 2129984 0 0 0 0 0 0 0 0 20 0 1 0 0 0 0 18446744073709551615 0 0 0 0 0 0 0 2147483647 0 0 0 0 17 0 0 0 0 0 0 0 0 0 0 0 0 0 0";
    const is_kthread = try parseKernelThreadStatus(content);
    try testing.expect(is_kthread);
}

test "parseKernelThreadStatus with process name containing parentheses" {
    // Process names can contain parentheses which makes parsing tricky
    const content = "123 (my (weird) app) S 0 1 1 0 -1 4194560 0 0 0 0 0 0 0 0 20 0 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 17 0 0 0 0 0 0 0 0 0 0 0 0 0 0";
    const is_kthread = try parseKernelThreadStatus(content);
    try testing.expect(!is_kthread);
}

test "parseKernelThreadStatus error on missing closing paren" {
    const content = "123 (myapp S 0 1 1 0 -1 4194560";
    try testing.expectError(error.InvalidFormat, parseKernelThreadStatus(content));
}

test "parseKernelThreadStatus error on missing fields" {
    const content = "123 (myapp) S 0 1";
    try testing.expectError(error.FieldNotFound, parseKernelThreadStatus(content));
}

test "parseKernelThreadStatus error on non-numeric flags" {
    const content = "123 (myapp) S 0 1 1 0 -1 notanumber 0 0 0 0 0 0 0 0 20 0 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 17 0 0 0 0 0 0 0 0 0 0 0 0 0 0";
    try testing.expectError(error.InvalidFlags, parseKernelThreadStatus(content));
}

test "Supervisor.init creates supervisor with correct fields" {
    const allocator = testing.allocator;
    var command = [_][]const u8{"/bin/echo"};
    var args = [_][]const u8{ "hello", "world" };
    var env = [_]NameValue{
        .{ .name = "FOO", .value = "bar" },
    };

    const supervisor = Supervisor.init(
        allocator,
        &command,
        &args,
        &env,
        "/tmp",
        1000,
        1000,
        30,
    );

    try testing.expectEqual(allocator, supervisor.allocator);
    try testing.expectEqual(@as(usize, 1), supervisor.command.len);
    try testing.expectEqualStrings("/bin/echo", supervisor.command[0]);
    try testing.expect(supervisor.args != null);
    try testing.expectEqual(@as(usize, 2), supervisor.args.?.len);
    try testing.expect(supervisor.env != null);
    try testing.expectEqual(@as(usize, 1), supervisor.env.?.len);
    try testing.expectEqualStrings("/tmp", supervisor.working_dir);
    try testing.expectEqual(@as(u32, 1000), supervisor.uid);
    try testing.expectEqual(@as(u32, 1000), supervisor.gid);
    try testing.expectEqual(@as(u64, 30), supervisor.shutdown_grace_period);
    try testing.expect(supervisor.main_pid == null);
}

test "Supervisor.init with null args" {
    const allocator = testing.allocator;
    var command = [_][]const u8{"/bin/sh"};

    const supervisor = Supervisor.init(
        allocator,
        &command,
        null,
        null,
        "/",
        0,
        0,
        10,
    );

    try testing.expect(supervisor.args == null);
    try testing.expect(supervisor.env == null);
}

test "Supervisor.buildArgv with command only" {
    const allocator = testing.allocator;
    var command = [_][]const u8{ "/bin/echo", "hello" };

    var supervisor = Supervisor.init(
        allocator,
        &command,
        null,
        null,
        "/",
        0,
        0,
        10,
    );

    const result = try supervisor.buildArgv();
    defer {
        for (result.arg_strings) |s| allocator.free(s);
        allocator.free(result.arg_strings);
        allocator.free(result.argv);
    }

    try testing.expectEqual(@as(usize, 3), result.argv.len);
    try testing.expectEqualStrings("/bin/echo", std.mem.span(result.argv[0].?));
    try testing.expectEqualStrings("hello", std.mem.span(result.argv[1].?));
    try testing.expect(result.argv[2] == null);
}

test "Supervisor.buildArgv with command and args" {
    const allocator = testing.allocator;
    var command = [_][]const u8{"/bin/sh"};
    var args = [_][]const u8{ "-c", "echo test" };

    var supervisor = Supervisor.init(
        allocator,
        &command,
        &args,
        null,
        "/",
        0,
        0,
        10,
    );

    const result = try supervisor.buildArgv();
    defer {
        for (result.arg_strings) |s| allocator.free(s);
        allocator.free(result.arg_strings);
        allocator.free(result.argv);
    }

    try testing.expectEqual(@as(usize, 4), result.argv.len);
    try testing.expectEqualStrings("/bin/sh", std.mem.span(result.argv[0].?));
    try testing.expectEqualStrings("-c", std.mem.span(result.argv[1].?));
    try testing.expectEqualStrings("echo test", std.mem.span(result.argv[2].?));
    try testing.expect(result.argv[3] == null);
}

test "Supervisor.buildArgv with empty args" {
    const allocator = testing.allocator;
    var command = [_][]const u8{"/bin/ls"};
    var args = [_][]const u8{};

    var supervisor = Supervisor.init(
        allocator,
        &command,
        &args,
        null,
        "/",
        0,
        0,
        10,
    );

    const result = try supervisor.buildArgv();
    defer {
        for (result.arg_strings) |s| allocator.free(s);
        allocator.free(result.arg_strings);
        allocator.free(result.argv);
    }

    try testing.expectEqual(@as(usize, 2), result.argv.len);
    try testing.expectEqualStrings("/bin/ls", std.mem.span(result.argv[0].?));
    try testing.expect(result.argv[1] == null);
}

test "shutdown_requested atomic operations" {
    // Reset state
    shutdown_requested.store(false, .release);
    try testing.expect(!shutdown_requested.load(.acquire));

    shutdown_requested.store(true, .release);
    try testing.expect(shutdown_requested.load(.acquire));

    // Reset for other tests
    shutdown_requested.store(false, .release);
}
