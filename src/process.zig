const std = @import("std");
const Allocator = std.mem.Allocator;
const linux = std.os.linux;
const posix = std.posix;
const testing = std.testing;

const errnoDescription = @import("service.zig").errnoDescription;
const fs = @import("fs.zig");
const NameValue = @import("vmspec.zig").NameValue;

pub const SpawnSpec = struct {
    argv: []const []const u8,
    env_map: ?*const std.process.Environ.Map = null,
    env: []const NameValue = &.{},
    working_dir: ?[]const u8 = null,
    uid: ?u32 = null,
    gid: ?u32 = null,
};

pub const Error = error{
    EmptyArgv,
    NameTooLong,
    ChdirFailed,
    SetgidFailed,
    SetuidFailed,
    ForkFailed,
    ExecveFailed,
    OutOfMemory,
};

/// Fork and exec the given command. Returns the child pid in the parent.
/// Heap-allocates argv and envp; frees them on the parent side after fork.
pub fn spawn(allocator: Allocator, spec: SpawnSpec) Error!posix.pid_t {
    const argv_buf = try buildArgv(allocator, spec.argv);
    defer argv_buf.deinit(allocator);
    const envp_buf = try buildEnvp(allocator, spec.env_map, spec.env);
    defer envp_buf.deinit(allocator);

    const pid_result = linux.fork();
    const pid_err = posix.errno(pid_result);
    if (pid_err != .SUCCESS) {
        std.log.err("fork failed: {s}", .{@tagName(pid_err)});
        return error.ForkFailed;
    }

    const pid: posix.pid_t = @intCast(pid_result);
    if (pid == 0) execChild(spec, argv_buf.argv, envp_buf.envp);
    return pid;
}

/// Replace the current process via execve. Heap-allocates argv and envp.
/// Returns only on failure.
pub fn replace(allocator: Allocator, spec: SpawnSpec) Error!noreturn {
    const argv_buf = try buildArgv(allocator, spec.argv);
    defer argv_buf.deinit(allocator);
    const envp_buf = try buildEnvp(allocator, spec.env_map, spec.env);
    defer envp_buf.deinit(allocator);

    try applyChildIdentity(spec);
    clearSignalMask();
    const exec_result = linux.execve(
        argv_buf.argv[0].?,
        @ptrCast(argv_buf.argv.ptr),
        @ptrCast(envp_buf.envp.ptr),
    );
    const exec_err = posix.errno(exec_result);
    std.log.err("execve failed: {s}", .{errnoDescription(exec_err)});
    return error.ExecveFailed;
}

fn execChild(
    spec: SpawnSpec,
    argv: []?[*:0]const u8,
    envp: []?[*:0]const u8,
) noreturn {
    applyChildIdentity(spec) catch linux.exit(1);
    clearSignalMask();
    const exec_result = linux.execve(
        argv[0].?,
        @ptrCast(argv.ptr),
        @ptrCast(envp.ptr),
    );
    const exec_err = posix.errno(exec_result);
    std.log.err("execve failed: {s}", .{errnoDescription(exec_err)});
    linux.exit(1);
}

/// Restore the default (empty) signal mask before execve so the new
/// process is not born with PID 1's signals blocked. execve resets
/// signal handlers but preserves the mask, so this has to be done by us.
fn clearSignalMask() void {
    const empty = posix.sigemptyset();
    _ = linux.sigprocmask(linux.SIG.SETMASK, &empty, null);
}

const ArgvBuf = struct {
    argv: []?[*:0]const u8,
    arg_strings: [][:0]const u8,

    fn deinit(self: ArgvBuf, allocator: Allocator) void {
        for (self.arg_strings) |s| allocator.free(s);
        allocator.free(self.arg_strings);
        allocator.free(self.argv);
    }
};

const EnvpBuf = struct {
    envp: []?[*:0]const u8,
    env_strings: [][:0]const u8,

    fn deinit(self: EnvpBuf, allocator: Allocator) void {
        for (self.env_strings) |s| allocator.free(s);
        allocator.free(self.env_strings);
        allocator.free(self.envp);
    }
};

/// Concatenate command and optional args into a single argv slice owned by
/// the caller. The slice contains pointers into the input slices, so the
/// inputs must outlive the returned argv.
pub fn concatArgv(
    allocator: Allocator,
    command: []const []const u8,
    args: ?[]const []const u8,
) ![][]const u8 {
    const args_slice = args orelse &[_][]const u8{};
    const argv = try allocator.alloc([]const u8, command.len + args_slice.len);
    @memcpy(argv[0..command.len], command);
    @memcpy(argv[command.len..], args_slice);
    return argv;
}

/// Replace PID 1 with the configured command via execve. Optionally remounts
/// the root filesystem read-only first. Returns only on failure.
pub fn replaceInit(
    allocator: Allocator,
    command: []const []const u8,
    args: ?[]const []const u8,
    env: ?[]const NameValue,
    working_dir: []const u8,
    uid: u32,
    gid: u32,
    readonly_root_fs: bool,
) !noreturn {
    if (command.len == 0) {
        std.log.err("command is empty", .{});
        return error.EmptyCommand;
    }

    if (readonly_root_fs) {
        try fs.remountRootReadonly();
    }

    const argv = try concatArgv(allocator, command, args);
    defer allocator.free(argv);

    std.log.info("execve: {s}", .{command[0]});
    return replace(allocator, .{
        .argv = argv,
        .env = env orelse &.{},
        .working_dir = working_dir,
        .uid = uid,
        .gid = gid,
    });
}

fn buildArgv(allocator: Allocator, argv: []const []const u8) Error!ArgvBuf {
    if (argv.len == 0) return error.EmptyArgv;

    var argv_z = try allocator.alloc(?[*:0]const u8, argv.len + 1);
    errdefer allocator.free(argv_z);

    var arg_strings = try allocator.alloc([:0]const u8, argv.len);
    var count: usize = 0;
    errdefer {
        for (arg_strings[0..count]) |s| allocator.free(s);
        allocator.free(arg_strings);
    }

    for (argv, 0..) |arg, i| {
        arg_strings[i] = try allocator.dupeZ(u8, arg);
        count += 1;
        argv_z[i] = arg_strings[i].ptr;
    }
    argv_z[argv.len] = null;

    return .{ .argv = argv_z, .arg_strings = arg_strings };
}

fn buildEnvp(
    allocator: Allocator,
    env_map: ?*const std.process.Environ.Map,
    overrides: []const NameValue,
) Error!EnvpBuf {
    var merged = std.StringHashMap([]const u8).init(allocator);
    defer merged.deinit();

    if (env_map) |m| {
        var iter = m.iterator();
        while (iter.next()) |entry| {
            try merged.put(entry.key_ptr.*, entry.value_ptr.*);
        }
    }
    for (overrides) |nv| {
        try merged.put(nv.name, nv.value);
    }

    const count = merged.count();
    var envp_z = try allocator.alloc(?[*:0]const u8, count + 1);
    errdefer allocator.free(envp_z);

    var env_strings = try allocator.alloc([:0]const u8, count);
    var written: usize = 0;
    errdefer {
        for (env_strings[0..written]) |s| allocator.free(s);
        allocator.free(env_strings);
    }

    var iter = merged.iterator();
    while (iter.next()) |entry| {
        const formatted = try std.fmt.allocPrint(
            allocator,
            "{s}={s}",
            .{ entry.key_ptr.*, entry.value_ptr.* },
        );
        defer allocator.free(formatted);
        env_strings[written] = try allocator.dupeZ(u8, formatted);
        envp_z[written] = env_strings[written].ptr;
        written += 1;
    }
    envp_z[count] = null;

    return .{ .envp = envp_z, .env_strings = env_strings };
}

fn applyChildIdentity(spec: SpawnSpec) Error!void {
    if (spec.working_dir) |wd| {
        var buf: [posix.PATH_MAX]u8 = undefined;
        if (wd.len >= buf.len) return error.NameTooLong;
        @memcpy(buf[0..wd.len], wd);
        buf[wd.len] = 0;
        const e = posix.errno(linux.chdir(@ptrCast(&buf)));
        if (e != .SUCCESS) {
            std.log.err("chdir to {s} failed: {s}", .{ wd, @tagName(e) });
            return error.ChdirFailed;
        }
    }
    if (spec.gid) |gid| {
        if (gid != 0) {
            const e = posix.errno(linux.setgid(gid));
            if (e != .SUCCESS) {
                std.log.err("setgid({d}) failed: {s}", .{ gid, @tagName(e) });
                return error.SetgidFailed;
            }
        }
    }
    if (spec.uid) |uid| {
        if (uid != 0) {
            const e = posix.errno(linux.setuid(uid));
            if (e != .SUCCESS) {
                std.log.err("setuid({d}) failed: {s}", .{ uid, @tagName(e) });
                return error.SetuidFailed;
            }
        }
    }
}

test "buildArgv produces null-terminated argv with sentinel" {
    const a = testing.allocator;
    const argv = [_][]const u8{ "/bin/echo", "hello", "world" };
    const built = try buildArgv(a, &argv);
    defer built.deinit(a);

    try testing.expectEqual(@as(usize, 4), built.argv.len);
    try testing.expectEqualStrings("/bin/echo", std.mem.span(built.argv[0].?));
    try testing.expectEqualStrings("hello", std.mem.span(built.argv[1].?));
    try testing.expectEqualStrings("world", std.mem.span(built.argv[2].?));
    try testing.expect(built.argv[3] == null);
}

test "buildArgv with single command" {
    const a = testing.allocator;
    const argv = [_][]const u8{"/bin/ls"};
    const built = try buildArgv(a, &argv);
    defer built.deinit(a);

    try testing.expectEqual(@as(usize, 2), built.argv.len);
    try testing.expectEqualStrings("/bin/ls", std.mem.span(built.argv[0].?));
    try testing.expect(built.argv[1] == null);
}

test "buildArgv rejects empty argv" {
    try testing.expectError(error.EmptyArgv, buildArgv(testing.allocator, &.{}));
}

test "buildArgv leaks nothing when a dupeZ fails mid-populate" {
    var failing = std.testing.FailingAllocator.init(
        testing.allocator,
        .{ .fail_index = 3 },
    );
    const argv = [_][]const u8{ "/bin/echo", "hello", "world" };
    try testing.expectError(error.OutOfMemory, buildArgv(failing.allocator(), &argv));
}

test "buildEnvp merges env_map and overrides with override precedence" {
    const a = testing.allocator;
    var env_map = std.process.Environ.Map.init(a);
    defer env_map.deinit();
    try env_map.put("FOO", "from_parent");
    try env_map.put("BAR", "only_parent");

    const overrides = [_]NameValue{
        .{ .name = "FOO", .value = "from_override" },
        .{ .name = "BAZ", .value = "only_override" },
    };

    const built = try buildEnvp(a, &env_map, &overrides);
    defer built.deinit(a);

    try testing.expectEqual(@as(usize, 4), built.envp.len);
    try testing.expect(built.envp[3] == null);

    var saw_foo = false;
    var saw_bar = false;
    var saw_baz = false;
    for (built.env_strings) |s| {
        if (std.mem.startsWith(u8, s, "FOO=")) {
            try testing.expectEqualStrings("FOO=from_override", s);
            saw_foo = true;
        } else if (std.mem.startsWith(u8, s, "BAR=")) {
            try testing.expectEqualStrings("BAR=only_parent", s);
            saw_bar = true;
        } else if (std.mem.startsWith(u8, s, "BAZ=")) {
            try testing.expectEqualStrings("BAZ=only_override", s);
            saw_baz = true;
        }
    }
    try testing.expect(saw_foo and saw_bar and saw_baz);
}

test "buildEnvp with empty inputs produces only sentinel" {
    const a = testing.allocator;
    const built = try buildEnvp(a, null, &.{});
    defer built.deinit(a);

    try testing.expectEqual(@as(usize, 1), built.envp.len);
    try testing.expect(built.envp[0] == null);
}

test "buildEnvp handles 300+ env vars without fixed-size limit" {
    const a = testing.allocator;
    var env_map = std.process.Environ.Map.init(a);
    defer env_map.deinit();

    var name_buf: [32]u8 = undefined;
    for (0..300) |i| {
        const name = try std.fmt.bufPrint(&name_buf, "VAR_{d}", .{i});
        try env_map.put(name, "value");
    }

    const built = try buildEnvp(a, &env_map, &.{});
    defer built.deinit(a);
    try testing.expectEqual(@as(usize, 301), built.envp.len);
}

test "clearSignalMask drops any blocked signals" {
    var saved: posix.sigset_t = undefined;
    _ = linux.sigprocmask(linux.SIG.BLOCK, null, &saved);
    defer _ = linux.sigprocmask(linux.SIG.SETMASK, &saved, null);

    var blocked = posix.sigemptyset();
    posix.sigaddset(&blocked, linux.SIG.TERM);
    posix.sigaddset(&blocked, linux.SIG.USR1);
    _ = linux.sigprocmask(linux.SIG.BLOCK, &blocked, null);

    var current: posix.sigset_t = undefined;
    _ = linux.sigprocmask(linux.SIG.BLOCK, null, &current);
    try testing.expect(posix.sigismember(&current, linux.SIG.TERM));
    try testing.expect(posix.sigismember(&current, linux.SIG.USR1));

    clearSignalMask();

    _ = linux.sigprocmask(linux.SIG.BLOCK, null, &current);
    try testing.expect(!posix.sigismember(&current, linux.SIG.TERM));
    try testing.expect(!posix.sigismember(&current, linux.SIG.USR1));
}

test "buildArgv handles 100+ args without fixed-size limit" {
    const a = testing.allocator;
    const args = try a.alloc([]const u8, 100);
    defer a.free(args);
    for (args) |*slot| slot.* = "arg";

    const built = try buildArgv(a, args);
    defer built.deinit(a);
    try testing.expectEqual(@as(usize, 101), built.argv.len);
}
