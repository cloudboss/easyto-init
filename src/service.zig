const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const linux = std.os.linux;
const posix = std.posix;
const testing = std.testing;

const aws = @import("aws");

const constants = @import("constants.zig");
const NameValue = @import("vmspec.zig").NameValue;
const services = @import("services.zig");
const ServiceDef = services.ServiceDef;
const system = @import("system.zig");

// Default value of config ACPI_TINY_POWER_BUTTON_SIGNAL in kernel.
const ACPI_TINY_POWER_BUTTON_SIGNAL: posix.SIG = @enumFromInt(38);
// Identifies a kernel thread, from linux/sched.h.
const PF_KTHREAD: u32 = 0x00200000;

var shutdown_requested = std.atomic.Value(bool).init(false);

fn ioSleep(io: Io, nanoseconds: u64) void {
    Io.sleep(io, Io.Duration.fromNanoseconds(@intCast(nanoseconds)), .awake) catch {};
}

/// Request a graceful shutdown.
pub fn requestShutdown() void {
    shutdown_requested.store(true, .release);
}

/// Check if shutdown has been requested.
pub fn isShutdownRequested() bool {
    return shutdown_requested.load(.acquire);
}

const ServiceState = struct {
    def: ServiceDef,
    pid: ?posix.pid_t = null,
    thread: ?std.Thread = null,
};

pub const Supervisor = struct {
    allocator: Allocator,
    io: Io,
    env_map: *const std.process.Environ.Map,
    command: []const []const u8,
    args: ?[]const []const u8,
    env: ?[]const NameValue,
    working_dir: []const u8,
    uid: u32,
    gid: u32,
    shutdown_grace_period: u64,
    readonly_root_fs: bool,
    main_pid: ?posix.pid_t = null,
    disable_services: ?[]const []const u8,
    imds_client: ?*aws.ImdsClient,
    service_states: []ServiceState = &[_]ServiceState{},

    pub fn init(
        allocator: Allocator,
        io: Io,
        env_map: *const std.process.Environ.Map,
        command: []const []const u8,
        args: ?[]const []const u8,
        env: ?[]const NameValue,
        working_dir: []const u8,
        uid: u32,
        gid: u32,
        shutdown_grace_period: u64,
        disable_services: ?[]const []const u8,
        imds_client: ?*aws.ImdsClient,
        readonly_root_fs: bool,
    ) Supervisor {
        return Supervisor{
            .allocator = allocator,
            .io = io,
            .env_map = env_map,
            .command = command,
            .args = args,
            .env = env,
            .working_dir = working_dir,
            .uid = uid,
            .gid = gid,
            .shutdown_grace_period = shutdown_grace_period,
            .readonly_root_fs = readonly_root_fs,
            .disable_services = disable_services,
            .imds_client = imds_client,
        };
    }

    pub fn start(self: *Supervisor) !void {
        setupSignalHandlers();

        const enabled_services = services.findEnabledServices(
            self.allocator,
            self.io,
            self.disable_services,
            self.imds_client,
        ) catch |err| {
            std.log.warn("failed to discover services: {s}", .{@errorName(err)});
            return self.startMainProcess();
        };
        defer self.allocator.free(enabled_services);

        if (enabled_services.len > 0) {
            self.service_states = self.allocator.alloc(ServiceState, enabled_services.len) catch |err| {
                std.log.warn("failed to allocate service states: {s}", .{@errorName(err)});
                return self.startMainProcess();
            };

            for (enabled_services, 0..) |svc_def, i| {
                self.service_states[i] = ServiceState{ .def = svc_def };
            }

            for (self.service_states) |*svc| {
                self.startService(svc) catch |err| {
                    if (svc.def.optional) {
                        std.log.info("optional service {s} failed to start: {s}", .{ svc.def.name, @errorName(err) });
                    } else {
                        std.log.err("required service {s} failed to start: {s}", .{ svc.def.name, @errorName(err) });
                        return err;
                    }
                };
            }
        }

        try self.startMainProcess();
    }

    fn startMainProcess(self: *Supervisor) !void {
        if (self.readonly_root_fs) {
            try system.remountRootReadonly();
        }

        std.log.info("starting main process: {s}", .{self.command[0]});

        const pid = try self.spawnProcess();
        self.main_pid = pid;
        std.log.info("main process started with pid {d}", .{pid});
    }

    fn startService(self: *Supervisor, svc: *ServiceState) !void {
        if (svc.def.init_fn) |init_fn| {
            try init_fn(self.allocator, self.io);
        }

        const thread = try std.Thread.spawn(.{}, serviceLoop, .{ self, svc });
        svc.thread = thread;
    }

    fn serviceLoop(self: *Supervisor, svc: *ServiceState) void {
        const io = self.io;
        var first_start = true;

        while (!shutdown_requested.load(.acquire)) {
            if (!first_start) {
                ioSleep(io, 5 * std.time.ns_per_s);
                if (shutdown_requested.load(.acquire)) return;
            }
            first_start = false;

            const pid = spawnServiceProcess(self.env_map, svc.def.args) catch |err| {
                std.log.err("failed to spawn {s}: {s}", .{ svc.def.name, @errorName(err) });
                continue;
            };

            svc.pid = pid;
            std.log.debug("started service {s} with pid {d}", .{ svc.def.name, pid });

            while (!shutdown_requested.load(.acquire)) {
                var status: u32 = 0;
                const result = linux.wait4(pid, &status, linux.W.NOHANG, null);
                const e = posix.errno(result);

                if (result > 0) {
                    svc.pid = null;
                    if (!shutdown_requested.load(.acquire)) {
                        std.log.info("service {s} exited, will restart", .{svc.def.name});
                    }
                    break;
                } else if (e == .CHILD) {
                    svc.pid = null;
                    break;
                }

                ioSleep(io, 100 * std.time.ns_per_ms);
            }
        }
    }

    pub fn wait(self: *Supervisor) void {
        var main_exited = false;

        while (true) {
            if (shutdown_requested.load(.acquire) and !main_exited) {
                std.log.info("shutdown requested, terminating processes", .{});
                self.gracefulShutdown();
                self.waitServiceThreads();
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
                    // Signal service threads to stop restarting
                    requestShutdown();
                    self.gracefulShutdown();
                    self.waitServiceThreads();
                    return;
                }
            } else if (e == .CHILD) {
                if (main_exited) {
                    std.log.info("all processes exited", .{});
                    self.waitServiceThreads();
                    return;
                }
                ioSleep(self.io, 10 * std.time.ns_per_ms);
            } else if (result == 0) {
                ioSleep(self.io, 10 * std.time.ns_per_ms);
            }

            if (shutdown_requested.load(.acquire) and !main_exited) {
                std.log.info("shutdown requested, terminating processes", .{});
                self.gracefulShutdown();
                self.waitServiceThreads();
                return;
            }
        }
    }

    fn waitServiceThreads(self: *Supervisor) void {
        for (self.service_states) |svc| {
            if (svc.thread) |thread| {
                thread.join();
            }
        }
        if (self.service_states.len > 0) {
            self.allocator.free(self.service_states);
            self.service_states = &[_]ServiceState{};
        }
        // Clean up global service state
        services.deinit();
    }

    fn gracefulShutdown(self: *Supervisor) void {
        std.log.info("sending SIGTERM to all processes", .{});
        self.signalAll(posix.SIG.TERM);

        const grace_ns = self.shutdown_grace_period * std.time.ns_per_s;
        const start_time = Io.Timestamp.now(self.io, .awake);

        while (true) {
            const elapsed_dur = start_time.durationTo(Io.Timestamp.now(self.io, .awake));
            const elapsed_ns: u64 = @intCast(elapsed_dur.toNanoseconds());
            if (elapsed_ns >= grace_ns) {
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
                ioSleep(self.io, 100 * std.time.ns_per_ms);
            }
        }

        std.log.info("grace period expired, sending SIGKILL to all processes", .{});
        self.signalAll(posix.SIG.KILL);

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

    fn signalAll(self: *Supervisor, sig: posix.SIG) void {
        const pids = getAllPids(self.io) catch |err| {
            std.log.err("failed to enumerate pids: {s}", .{@errorName(err)});
            return;
        };
        defer std.heap.page_allocator.free(pids);

        for (pids) |pid| {
            _ = linux.kill(pid, sig);
        }
    }

    fn spawnProcess(self: *Supervisor) !posix.pid_t {
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
            self.execChild(argv, envp);
        }

        return pid;
    }

    fn execChild(self: *Supervisor, argv: []?[*:0]const u8, envp: []?[*:0]const u8) noreturn {
        var wd_buf: [posix.PATH_MAX]u8 = undefined;
        if (self.working_dir.len >= wd_buf.len) {
            std.log.err("working_dir too long", .{});
            linux.exit(1);
        }
        @memcpy(wd_buf[0..self.working_dir.len], self.working_dir);
        wd_buf[self.working_dir.len] = 0;
        const chdir_e = posix.errno(linux.chdir(@ptrCast(&wd_buf)));
        if (chdir_e != .SUCCESS) {
            std.log.err("chdir to {s} failed: {s}", .{ self.working_dir, @tagName(chdir_e) });
            linux.exit(1);
        }

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
        var parent_iter = self.env_map.iterator();
        while (parent_iter.next()) |entry| {
            try env_map.put(entry.key_ptr.*, entry.value_ptr.*);
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
        var env_strings_count: usize = 0;
        errdefer {
            for (env_strings[0..env_strings_count]) |s| self.allocator.free(s);
            self.allocator.free(env_strings);
        }

        var iter = env_map.iterator();
        while (iter.next()) |entry| {
            const env_str = try std.fmt.allocPrint(
                self.allocator,
                "{s}={s}",
                .{ entry.key_ptr.*, entry.value_ptr.* },
            );
            defer self.allocator.free(env_str);
            env_strings[env_strings_count] = try self.allocator.dupeZ(u8, env_str);
            envp[env_strings_count] = env_strings[env_strings_count].ptr;
            env_strings_count += 1;
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

fn spawnServiceProcess(
    env_map: *const std.process.Environ.Map,
    args: []const []const u8,
) !posix.pid_t {
    const pid_result = linux.fork();
    const pid_err = posix.errno(pid_result);
    if (pid_err != .SUCCESS) {
        return error.ForkFailed;
    }

    const pid: posix.pid_t = @intCast(pid_result);
    if (pid == 0) {
        execServiceProcess(env_map, args);
    }

    return pid;
}

fn execServiceProcess(
    env_map: *const std.process.Environ.Map,
    args: []const []const u8,
) noreturn {
    var argv_buf: [16]?[*:0]const u8 = undefined;
    var arg_storage: [2048]u8 = undefined;
    var arg_pos: usize = 0;

    for (args, 0..) |arg, i| {
        if (arg_pos + arg.len + 1 > arg_storage.len or i >= argv_buf.len - 1) {
            std.log.err("arguments too large for service", .{});
            linux.exit(1);
        }
        @memcpy(arg_storage[arg_pos..][0..arg.len], arg);
        arg_storage[arg_pos + arg.len] = 0;
        argv_buf[i] = @ptrCast(&arg_storage[arg_pos]);
        arg_pos += arg.len + 1;
    }
    argv_buf[args.len] = null;

    var envp_buf: [256]?[*:0]const u8 = undefined;
    var env_storage: [16384]u8 = undefined;
    var env_pos: usize = 0;
    var env_count: usize = 0;
    var iter = env_map.iterator();
    while (iter.next()) |entry| : (env_count += 1) {
        if (env_count + 1 >= envp_buf.len) {
            std.log.err("too many environment variables for service", .{});
            linux.exit(1);
        }
        const needed = entry.key_ptr.*.len + 1 + entry.value_ptr.*.len + 1;
        if (env_pos + needed > env_storage.len) {
            std.log.err("environment too large for service", .{});
            linux.exit(1);
        }
        const start = env_pos;
        @memcpy(env_storage[env_pos..][0..entry.key_ptr.*.len], entry.key_ptr.*);
        env_pos += entry.key_ptr.*.len;
        env_storage[env_pos] = '=';
        env_pos += 1;
        @memcpy(env_storage[env_pos..][0..entry.value_ptr.*.len], entry.value_ptr.*);
        env_pos += entry.value_ptr.*.len;
        env_storage[env_pos] = 0;
        env_pos += 1;
        envp_buf[env_count] = @ptrCast(&env_storage[start]);
    }
    envp_buf[env_count] = null;

    const exec_result = linux.execve(
        argv_buf[0].?,
        @ptrCast(&argv_buf),
        @ptrCast(&envp_buf),
    );
    const exec_err = posix.errno(exec_result);
    std.log.err("execve failed: {s}", .{errnoDescription(exec_err)});
    linux.exit(1);
}

fn setupSignalHandlers() void {
    const handler = posix.Sigaction{
        .handler = .{ .handler = signalHandler },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };

    posix.sigaction(posix.SIG.TERM, &handler, null);
    posix.sigaction(posix.SIG.INT, &handler, null);
    posix.sigaction(ACPI_TINY_POWER_BUTTON_SIGNAL, &handler, null);
}

fn signalHandler(sig: posix.SIG) callconv(.c) void {
    _ = sig;
    shutdown_requested.store(true, .release);
}

fn getAllPids(io: Io) ![]posix.pid_t {
    var pids = std.ArrayList(posix.pid_t).initCapacity(std.heap.page_allocator, 100) catch {
        return error.OutOfMemory;
    };
    errdefer pids.deinit(std.heap.page_allocator);

    var dir = Io.Dir.openDirAbsolute(io, constants.dir_proc, .{ .iterate = true }) catch |err| {
        std.log.err("failed to open {s}: {s}", .{ constants.dir_proc, @errorName(err) });
        return err;
    };
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .directory) continue;

        const pid = std.fmt.parseInt(posix.pid_t, entry.name, 10) catch continue;
        if (pid == 1) continue;
        if (isKernelThread(io, pid)) continue;

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
    const field_index_flags: usize = 8;

    while (iter.next()) |field| {
        if (field_index == field_index_flags) {
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

fn isKernelThread(io: Io, pid: posix.pid_t) bool {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/stat", .{pid}) catch return true;

    const file = Io.Dir.openFileAbsolute(io, path, .{}) catch return true;
    defer file.close(io);

    var buf: [512]u8 = undefined;
    var rbuf: [1024]u8 = undefined;
    var reader = file.reader(io, &rbuf);
    const bytes_read = reader.interface.readSliceShort(&buf) catch return true;
    const content = buf[0..bytes_read];

    return parseKernelThreadStatus(content) catch true;
}

test "isKernelThread returns false for init process" {
    try testing.expect(!isKernelThread(testing.io, 1));
}

test "getAllPids does not include pid 1" {
    const pids = try getAllPids(testing.io);
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

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    const supervisor = Supervisor.init(
        allocator,
        testing.io,
        &env_map,
        &command,
        &args,
        &env,
        "/tmp",
        1000,
        1000,
        30,
        null,
        null,
        false,
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

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    const supervisor = Supervisor.init(
        allocator,
        testing.io,
        &env_map,
        &command,
        null,
        null,
        "/",
        0,
        0,
        10,
        null,
        null,
        false,
    );

    try testing.expect(supervisor.args == null);
    try testing.expect(supervisor.env == null);
}

test "Supervisor.buildArgv with command only" {
    const allocator = testing.allocator;
    var command = [_][]const u8{ "/bin/echo", "hello" };

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    var supervisor = Supervisor.init(
        allocator,
        testing.io,
        &env_map,
        &command,
        null,
        null,
        "/",
        0,
        0,
        10,
        null,
        null,
        false,
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

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    var supervisor = Supervisor.init(
        allocator,
        testing.io,
        &env_map,
        &command,
        &args,
        null,
        "/",
        0,
        0,
        10,
        null,
        null,
        false,
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

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    var supervisor = Supervisor.init(
        allocator,
        testing.io,
        &env_map,
        &command,
        &args,
        null,
        "/",
        0,
        0,
        10,
        null,
        null,
        false,
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
