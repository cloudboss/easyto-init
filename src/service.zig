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

var shutdown_requested: bool = false;

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
            if (shutdown_requested and !main_exited) {
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

            if (shutdown_requested and !main_exited) {
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
        defer {
            for (arg_strings) |s| self.allocator.free(s);
            self.allocator.free(arg_strings);
        }

        for (self.command, 0..) |arg, i| {
            arg_strings[i] = try self.allocator.dupeZ(u8, arg);
            argv[i] = arg_strings[i].ptr;
        }
        if (self.args) |args| {
            for (args, 0..) |arg, i| {
                arg_strings[command_len + i] = try self.allocator.dupeZ(u8, arg);
                argv[command_len + i] = arg_strings[command_len + i].ptr;
            }
        }
        argv[total_len] = null;

        const env_len = if (self.env) |e| e.len else 0;
        var envp = try self.allocator.alloc(?[*:0]const u8, env_len + 1);
        defer self.allocator.free(envp);

        var env_strings = try self.allocator.alloc([:0]const u8, env_len);
        defer {
            for (env_strings) |s| self.allocator.free(s);
            self.allocator.free(env_strings);
        }

        if (self.env) |env| {
            for (env, 0..) |nv, i| {
                const env_str = try std.fmt.allocPrint(self.allocator, "{s}={s}", .{ nv.name, nv.value });
                const env_str_z = try self.allocator.dupeZ(u8, env_str);
                self.allocator.free(env_str);
                env_strings[i] = env_str_z;
                envp[i] = env_str_z.ptr;
            }
        }
        envp[env_len] = null;

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
        std.log.err("execve failed: {s}", .{@tagName(exec_err)});
        linux.exit(1);
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
    shutdown_requested = true;
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

fn is_kernel_thread(pid: posix.pid_t) bool {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/stat", .{pid}) catch return true;

    const file = std.fs.openFileAbsolute(path, .{}) catch return true;
    defer file.close();

    var buf: [512]u8 = undefined;
    const bytes_read = file.read(&buf) catch return true;
    const content = buf[0..bytes_read];

    const paren_end = std.mem.lastIndexOf(u8, content, ")") orelse return true;
    const after_comm = content[paren_end + 1 ..];

    var iter = std.mem.tokenizeScalar(u8, after_comm, ' ');
    var field_index: usize = 2;

    while (iter.next()) |field| {
        if (field_index == FLAGS_FIELD_INDEX) {
            const flags = std.fmt.parseInt(u32, field, 10) catch return true;
            return (flags & PF_KTHREAD) != 0;
        }
        field_index += 1;
    }

    return true;
}

test "is_kernel_thread" {
    try testing.expect(!is_kernel_thread(1));
}

test "get_all_pids does not include pid 1" {
    const pids = try get_all_pids();
    defer std.heap.page_allocator.free(pids);

    for (pids) |pid| {
        try testing.expect(pid != 1);
    }
}
