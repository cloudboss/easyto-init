const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const linux = std.os.linux;
const posix = std.posix;
const testing = std.testing;

const aws = @import("aws");

const constants = @import("constants.zig");
const fs = @import("fs.zig");
const NameValue = @import("vmspec.zig").NameValue;
const process = @import("process.zig");
const services = @import("services.zig");
const ServiceDef = services.ServiceDef;
const system = @import("system.zig");

// Default value of config ACPI_TINY_POWER_BUTTON_SIGNAL in kernel.
const ACPI_TINY_POWER_BUTTON_SIGNAL: linux.SIG = @enumFromInt(38);
// Identifies a kernel thread, from linux/sched.h.
const PF_KTHREAD: u32 = 0x00200000;

// Wait this many milliseconds before restarting a service that exited.
const restart_delay_ms: i64 = 5_000;

// Upper bound on pollfds enrolled by Supervisor.wait: one for the signalfd
// plus one restart timerfd per service. start() rejects configurations that
// would exceed this.
const max_poll_fds: usize = 16;

/// Block the signals the supervisor consumes via signalfd, and install
/// no-op sigactions so PID 1's SIGNAL_UNKILLABLE protection doesn't drop
/// them. Must be called before any thread is spawned, since sigprocmask
/// is per-thread and children inherit the caller's mask.
pub fn setupSignalHandling() void {
    const sa = posix.Sigaction{
        .handler = .{ .handler = noopSignalHandler },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(linux.SIG.TERM, &sa, null);
    posix.sigaction(linux.SIG.INT, &sa, null);
    posix.sigaction(linux.SIG.CHLD, &sa, null);
    posix.sigaction(ACPI_TINY_POWER_BUTTON_SIGNAL, &sa, null);

    var mask = supervisorSignalMask();
    _ = linux.sigprocmask(linux.SIG.BLOCK, &mask, null);
}

fn supervisorSignalMask() posix.sigset_t {
    var mask = posix.sigemptyset();
    posix.sigaddset(&mask, linux.SIG.TERM);
    posix.sigaddset(&mask, linux.SIG.INT);
    posix.sigaddset(&mask, linux.SIG.CHLD);
    posix.sigaddset(&mask, ACPI_TINY_POWER_BUTTON_SIGNAL);
    return mask;
}

fn noopSignalHandler(_: linux.SIG) callconv(.c) void {}

/// Request a graceful shutdown by signalling PID 1. Safe to call from any
/// thread; the supervisor's signalfd picks it up on the next poll iteration.
pub fn requestShutdown() void {
    _ = linux.kill(1, linux.SIG.TERM);
}

const ServiceState = struct {
    def: ServiceDef,
    pid: ?posix.pid_t = null,
    restart_timerfd: ?posix.fd_t = null,
};

const PollEntry = union(enum) {
    signal,
    service_restart: usize,
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
    signalfd: posix.fd_t = -1,

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
        self.signalfd = try installSignalfd();
        errdefer {
            _ = linux.close(self.signalfd);
            self.signalfd = -1;
        }

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

        if (enabled_services.len + 1 > max_poll_fds) {
            std.log.err(
                "too many services enabled ({d}); max is {d}",
                .{ enabled_services.len, max_poll_fds - 1 },
            );
            return error.TooManyServices;
        }

        if (enabled_services.len > 0) {
            self.service_states = self.allocator.alloc(
                ServiceState,
                enabled_services.len,
            ) catch |err| {
                std.log.warn("failed to allocate service states: {s}", .{@errorName(err)});
                return self.startMainProcess();
            };

            for (enabled_services, 0..) |svc_def, i| {
                self.service_states[i] = ServiceState{ .def = svc_def };
            }

            for (self.service_states) |*svc| {
                self.startService(svc) catch |err| {
                    if (svc.def.optional) {
                        std.log.info(
                            "optional service {s} failed to start: {s}",
                            .{ svc.def.name, @errorName(err) },
                        );
                    } else {
                        std.log.err(
                            "required service {s} failed to start: {s}",
                            .{ svc.def.name, @errorName(err) },
                        );
                        return err;
                    }
                };
            }
        }

        try self.startMainProcess();
    }

    fn startMainProcess(self: *Supervisor) !void {
        if (self.readonly_root_fs) {
            try fs.remountRootReadonly();
        }
        std.log.info("starting main process: {s}", .{self.command[0]});

        const argv = try process.concatArgv(self.allocator, self.command, self.args);
        defer self.allocator.free(argv);

        const pid = try process.spawn(self.allocator, .{
            .argv = argv,
            .env_map = self.env_map,
            .env = self.env orelse &.{},
            .working_dir = self.working_dir,
            .uid = self.uid,
            .gid = self.gid,
        });
        self.main_pid = pid;
        std.log.info("main process started with pid {d}", .{pid});
    }

    fn startService(self: *Supervisor, svc: *ServiceState) !void {
        if (svc.def.init_fn) |init_fn| {
            try init_fn(self.allocator, self.io, svc.def.init_ctx);
        }
        const pid = try process.spawn(self.allocator, .{
            .argv = svc.def.args,
            .env_map = self.env_map,
        });
        svc.pid = pid;
        std.log.debug("started service {s} with pid {d}", .{ svc.def.name, pid });
    }

    pub fn wait(self: *Supervisor) void {
        defer self.cleanup();

        var shutdown_initiated = false;
        var deadline_ms: i64 = -1;
        var sigkill_sent = false;

        while (self.aliveCount() > 0) {
            const timeout_ms: i32 = if (deadline_ms < 0)
                -1
            else
                @intCast(@max(@as(i64, 0), deadline_ms - nowMs()));

            var pollfds_buf: [max_poll_fds]linux.pollfd = undefined;
            var pollmap: [max_poll_fds]PollEntry = undefined;
            const n = self.buildPollSet(&pollfds_buf, &pollmap);

            const rc = linux.poll(&pollfds_buf, n, timeout_ms);
            const e = posix.errno(rc);
            if (e == .INTR) continue;
            if (e != .SUCCESS) {
                std.log.err("poll failed: {s}", .{@tagName(e)});
                return;
            }

            if (rc == 0) {
                if (shutdown_initiated and !sigkill_sent) {
                    std.log.info("grace period expired, sending kill signal to all processes", .{});
                    self.broadcast(linux.SIG.KILL);
                    sigkill_sent = true;
                    deadline_ms = -1;
                }
                continue;
            }

            for (pollfds_buf[0..n], pollmap[0..n]) |pf, entry| {
                if ((pf.revents & @as(i16, linux.POLL.IN)) == 0) continue;
                switch (entry) {
                    .signal => self.handleSignals(&shutdown_initiated, &deadline_ms),
                    .service_restart => |idx| self.handleRestart(idx),
                }
            }
        }
        std.log.info("all processes terminated", .{});
    }

    fn buildPollSet(self: *Supervisor, fds: []linux.pollfd, map: []PollEntry) linux.nfds_t {
        var n: usize = 0;
        fds[n] = .{ .fd = self.signalfd, .events = linux.POLL.IN, .revents = 0 };
        map[n] = .signal;
        n += 1;
        for (self.service_states, 0..) |*svc, idx| {
            if (svc.restart_timerfd) |fd| {
                fds[n] = .{ .fd = fd, .events = linux.POLL.IN, .revents = 0 };
                map[n] = .{ .service_restart = idx };
                n += 1;
            }
        }
        return @intCast(n);
    }

    fn handleSignals(
        self: *Supervisor,
        shutdown_initiated: *bool,
        deadline_ms: *i64,
    ) void {
        var buf: [16]linux.signalfd_siginfo = undefined;
        while (true) {
            const rc = linux.read(self.signalfd, @ptrCast(&buf), @sizeOf(@TypeOf(buf)));
            const e = posix.errno(rc);
            if (e == .AGAIN) return;
            if (e == .INTR) continue;
            if (e != .SUCCESS) {
                std.log.err("signalfd read failed: {s}", .{@tagName(e)});
                return;
            }
            const got = rc / @sizeOf(linux.signalfd_siginfo);
            for (buf[0..got]) |si| {
                const signo: linux.SIG = @enumFromInt(si.signo);
                if (signo == linux.SIG.CHLD) {
                    self.reapChildren(shutdown_initiated.*);
                } else if (signo == linux.SIG.TERM or
                    signo == linux.SIG.INT or
                    signo == ACPI_TINY_POWER_BUTTON_SIGNAL)
                {
                    if (!shutdown_initiated.*) {
                        self.initiateShutdown(shutdown_initiated, deadline_ms);
                    }
                }
            }
        }
    }

    fn reapChildren(self: *Supervisor, shutting_down: bool) void {
        while (true) {
            var status: u32 = 0;
            const r = linux.wait4(-1, &status, linux.W.NOHANG, null);
            const e = posix.errno(r);
            if (e == .CHILD) return;
            if (r == 0) return;
            if (e != .SUCCESS) {
                std.log.err("wait4 failed: {s}", .{@tagName(e)});
                return;
            }
            const reaped: posix.pid_t = @intCast(r);

            if (self.main_pid == reaped) {
                std.log.info("main process exited", .{});
                self.main_pid = null;
                if (!shutting_down) requestShutdown();
            } else if (self.findServiceByPid(reaped)) |svc| {
                svc.pid = null;
                if (shutting_down) {
                    std.log.info("service {s} exited", .{svc.def.name});
                } else {
                    std.log.info("service {s} exited, will restart", .{svc.def.name});
                    svc.restart_timerfd = createRestartTimer(restart_delay_ms) catch |err| blk: {
                        std.log.err(
                            "failed to arm restart timer for {s}: {s}",
                            .{ svc.def.name, @errorName(err) },
                        );
                        break :blk null;
                    };
                }
            }
        }
    }

    fn findServiceByPid(self: *Supervisor, pid: posix.pid_t) ?*ServiceState {
        for (self.service_states) |*svc| {
            if (svc.pid == pid) return svc;
        }
        return null;
    }

    fn handleRestart(self: *Supervisor, idx: usize) void {
        const svc = &self.service_states[idx];
        if (svc.restart_timerfd) |fd| {
            var expirations: u64 = 0;
            _ = linux.read(fd, @ptrCast(&expirations), @sizeOf(u64));
            _ = linux.close(fd);
            svc.restart_timerfd = null;
        }
        self.startService(svc) catch |err| {
            std.log.err("failed to restart {s}: {s}", .{ svc.def.name, @errorName(err) });
        };
    }

    fn initiateShutdown(
        self: *Supervisor,
        shutdown_initiated: *bool,
        deadline_ms: *i64,
    ) void {
        std.log.info("shutdown requested, terminating processes", .{});
        shutdown_initiated.* = true;
        for (self.service_states) |*svc| {
            if (svc.restart_timerfd) |fd| {
                _ = linux.close(fd);
                svc.restart_timerfd = null;
            }
        }
        self.broadcast(linux.SIG.TERM);
        deadline_ms.* = nowMs() + @as(i64, @intCast(self.shutdown_grace_period * 1000));
    }

    fn broadcast(self: *Supervisor, sig: linux.SIG) void {
        const pids = getAllPids(self.allocator, self.io) catch |err| {
            std.log.err("failed to enumerate pids: {s}", .{@errorName(err)});
            return;
        };
        defer self.allocator.free(pids);
        for (pids) |pid| _ = linux.kill(pid, sig);
    }

    fn aliveCount(self: *Supervisor) usize {
        var n: usize = if (self.main_pid != null) 1 else 0;
        for (self.service_states) |svc| {
            if (svc.pid != null) n += 1;
            if (svc.restart_timerfd != null) n += 1;
        }
        return n;
    }

    fn cleanup(self: *Supervisor) void {
        for (self.service_states) |*svc| {
            if (svc.restart_timerfd) |fd| {
                _ = linux.close(fd);
                svc.restart_timerfd = null;
            }
        }
        if (self.service_states.len > 0) {
            self.allocator.free(self.service_states);
            self.service_states = &[_]ServiceState{};
        }
        if (self.signalfd >= 0) {
            _ = linux.close(self.signalfd);
            self.signalfd = -1;
        }
    }
};

fn nowMs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divFloor(@as(i64, ts.nsec), 1_000_000);
}

fn installSignalfd() !posix.fd_t {
    var mask = supervisorSignalMask();
    const flags: u32 = linux.SFD.NONBLOCK | linux.SFD.CLOEXEC;
    const rc = linux.signalfd(-1, &mask, flags);
    const e = posix.errno(rc);
    if (e != .SUCCESS) {
        std.log.err("signalfd failed: {s}", .{@tagName(e)});
        return error.SignalfdFailed;
    }
    return @intCast(rc);
}

fn createRestartTimer(delay_ms: i64) !posix.fd_t {
    const rc = linux.timerfd_create(.MONOTONIC, .{});
    const e = posix.errno(rc);
    if (e != .SUCCESS) return error.TimerfdCreateFailed;

    const fd: posix.fd_t = @intCast(rc);
    errdefer _ = linux.close(fd);

    const spec: linux.itimerspec = .{
        .it_interval = .{ .sec = 0, .nsec = 0 },
        .it_value = .{
            .sec = @intCast(@divFloor(delay_ms, 1000)),
            .nsec = @intCast(@mod(delay_ms, 1000) * 1_000_000),
        },
    };
    const set_rc = linux.timerfd_settime(fd, .{}, &spec, null);
    if (posix.errno(set_rc) != .SUCCESS) return error.TimerfdSettimeFailed;
    return fd;
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

fn getAllPids(allocator: Allocator, io: Io) ![]posix.pid_t {
    var pids = try std.ArrayList(posix.pid_t).initCapacity(allocator, 100);
    errdefer pids.deinit(allocator);

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

        try pids.append(allocator, pid);
    }

    return try pids.toOwnedSlice(allocator);
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
    const pids = try getAllPids(testing.allocator, testing.io);
    defer testing.allocator.free(pids);

    for (pids) |pid| {
        try testing.expect(pid != 1);
    }
}

test "parseKernelThreadStatus with normal process" {
    // Real example from /proc/1/stat - init is not a kernel thread (flags don't have PF_KTHREAD)
    const content = "1 (init) S 0 1 1 0 -1 4194560 1234 0 0 0 10 5 0 0 20 0 1 0 1 12345678 1024 " ++
        "18446744073709551615 0 0 0 0 0 0 0 0 65536 0 0 0 17 0 0 0 0 0 0 0 0 0 0 0 0 0 0";
    const is_kthread = try parseKernelThreadStatus(content);
    try testing.expect(!is_kthread);
}

test "parseKernelThreadStatus with kernel thread" {
    // Kernel thread has PF_KTHREAD (0x00200000 = 2097152) set in flags field
    const content = "2 (kthreadd) S 0 0 0 0 -1 2129984 0 0 0 0 0 0 0 0 20 0 1 0 0 0 0 " ++
        "18446744073709551615 0 0 0 0 0 0 0 2147483647 0 0 0 0 17 0 0 0 0 0 0 0 0 0 0 0 0 0 0";
    const is_kthread = try parseKernelThreadStatus(content);
    try testing.expect(is_kthread);
}

test "parseKernelThreadStatus with process name containing parentheses" {
    // Process names can contain parentheses which makes parsing tricky
    const content = "123 (my (weird) app) S 0 1 1 0 -1 4194560 0 0 0 0 0 0 0 0 20 0 1 0 0 0 " ++
        "0 0 0 0 0 0 0 0 0 0 0 0 0 0 17 0 0 0 0 0 0 0 0 0 0 0 0 0 0";
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
    const content = "123 (myapp) S 0 1 1 0 -1 notanumber 0 0 0 0 0 0 0 0 20 0 1 0 0 0 " ++
        "0 0 0 0 0 0 0 0 0 0 0 0 0 0 17 0 0 0 0 0 0 0 0 0 0 0 0 0 0";
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
