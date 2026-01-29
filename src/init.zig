const std = @import("std");
const fmt = std.fmt;
const mount = std.os.linux.mount;
const ms = std.os.linux.MS;
const Mode = std.fs.File.Mode;
const Allocator = std.mem.Allocator;

const aws_sdk = @import("aws_sdk");
const k8s_expand = @import("k8s_expand");

const constants = @import("constants.zig");
const container = @import("container.zig");
const mkdir_p = @import("fs.zig").mkdir_p;
const network = @import("network.zig");
const Supervisor = @import("service.zig").Supervisor;
const system = @import("system.zig");
const vmspec_mod = @import("vmspec.zig");
const VmSpec = vmspec_mod.VmSpec;
const EnvFromSource = vmspec_mod.EnvFromSource;
const NameValue = vmspec_mod.NameValue;

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
    std.log.info("easyto-init started", .{});

    std.log.info("mounting base filesystems", .{});
    try base_mounts();

    try setup_test_mode();

    std.log.info("creating base symlinks", .{});
    try base_links();

    std.log.info("initializing network", .{});
    try network.initializeNetwork(allocator);

    // Fetch user data from IMDS
    std.log.info("fetching user data from IMDS", .{});
    const user_data = fetchUserData(allocator) catch |err| blk: {
        std.log.warn("failed to fetch user data: {s}, continuing without", .{@errorName(err)});
        break :blk null;
    };
    defer if (user_data) |ud| allocator.free(ud);

    std.log.info("linking nvme devices", .{});
    try system.link_nvme_devices(allocator);

    std.log.info("reading metadata", .{});
    const config_file_path = constants.DIR_ET ++ "/" ++ constants.FILE_METADATA;
    var metadata = try read_metadata(allocator, config_file_path);
    defer metadata.deinit();

    std.log.info("parsing vmspec", .{});
    var vmspec = try VmSpec.from_config_file(allocator, &metadata.parsed.value);
    defer vmspec.deinit();

    // Parse and merge user data if available
    if (user_data) |ud| {
        std.log.info("parsing user data YAML", .{});
        if (VmSpec.from_yaml(allocator, ud)) |user_vmspec_opt| {
            if (user_vmspec_opt) |user_vmspec_const| {
                var user_vmspec = user_vmspec_const;
                defer user_vmspec.deinit();
                std.log.info("merging user data into vmspec", .{});
                try vmspec.merge(user_vmspec);
            }
        } else |err| {
            std.log.err("unable to parse user data: {s}", .{@errorName(err)});
            return err;
        }
    }

    // Resolve env-from sources
    if (vmspec.@"env-from") |env_from| {
        std.log.info("resolving env-from sources", .{});
        try resolveEnvFrom(allocator, &vmspec, env_from);
    }

    std.log.info("loading kernel modules", .{});
    try system.loadModules(vmspec.modules);

    std.log.info("applying sysctls", .{});
    try system.setSysctls(vmspec.sysctls);

    std.log.info("running init scripts", .{});
    try system.runInitScripts(vmspec.@"init-scripts", vmspec.env);

    // Expand variables in command and args
    const expanded = try expandCommandAndArgs(allocator, vmspec.full_command(), vmspec.command_args(), vmspec.env);
    defer expanded.deinit(allocator);
    const command = expanded.command;
    const args = expanded.args;
    const uid = vmspec.security.@"run-as-user-id" orelse 0;
    const gid = vmspec.security.@"run-as-group-id" orelse 0;
    const working_dir = vmspec.@"working-dir" orelse "/";
    const shutdown_grace_period = vmspec.@"shutdown-grace-period" orelse 10;
    const replace_init = vmspec.@"replace-init" orelse false;

    if (replace_init) {
        std.log.info("replacing init with command", .{});
        try replaceInit(command, args, vmspec.env, working_dir, uid, gid);
    } else {
        std.log.info("starting supervisor", .{});
        var supervisor = Supervisor.init(
            allocator,
            command,
            args,
            vmspec.env,
            working_dir,
            uid,
            gid,
            shutdown_grace_period,
        );

        try supervisor.start();
        supervisor.wait();

        std.log.info("supervisor finished, shutting down", .{});
    }
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
            .fs_type = "sysfs",
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

fn setup_test_mode() !void {
    _ = std.posix.getenv("EASYTO_TEST_MODE") orelse return;

    const tty_path = "/dev/ttyS0";

    // Make serial console accessible to non-root users
    const tty_fd = std.posix.open(tty_path, .{ .ACCMODE = .WRONLY }, 0) catch |err| {
        std.log.err("unable to open {s}: {s}", .{ tty_path, @errorName(err) });
        return err;
    };

    std.posix.fchmod(tty_fd, 0o666) catch |err| {
        std.log.err("unable to chmod {s}: {s}", .{ tty_path, @errorName(err) });
        return err;
    };

    // Redirect stderr to serial console
    std.posix.dup2(tty_fd, std.posix.STDERR_FILENO) catch |err| {
        std.log.err("unable to dup2 stderr to {s}: {s}", .{ tty_path, @errorName(err) });
        return err;
    };

    std.posix.close(tty_fd);

    std.log.info("test mode enabled", .{});
}

const Metadata = struct {
    contents: []const u8,
    parsed: std.json.Parsed(container.ConfigFile),
    allocator: Allocator,

    fn deinit(self: *Metadata) void {
        self.parsed.deinit();
        self.allocator.free(self.contents);
    }
};

fn read_metadata(allocator: Allocator, path: []const u8) !Metadata {
    const contents = try std.fs.cwd().readFileAlloc(
        allocator,
        path,
        1073741824,
    );
    errdefer allocator.free(contents);
    const parsed = try std.json.parseFromSlice(
        container.ConfigFile,
        allocator,
        contents,
        .{ .ignore_unknown_fields = true },
    );
    return Metadata{
        .contents = contents,
        .parsed = parsed,
        .allocator = allocator,
    };
}

fn fetchUserData(allocator: Allocator) !?[]const u8 {
    var imds_client = aws_sdk.imds.ImdsClient.init(allocator, .{}) catch |err| {
        std.log.err("failed to initialize IMDS client: {s}", .{@errorName(err)});
        return err;
    };
    defer imds_client.deinit();

    // User data endpoint returns 404 if no user data is configured
    const user_data = imds_client.get("/latest/user-data") catch |err| {
        if (err == error.HttpNotFound) {
            std.log.info("no user data configured in IMDS", .{});
            return null;
        }
        std.log.err("failed to fetch user data from IMDS: {s}", .{@errorName(err)});
        return err;
    };

    return user_data;
}

const linux = std.os.linux;
const posix = std.posix;

fn replaceInit(
    command: []const []const u8,
    args: ?[]const []const u8,
    env: ?[]const NameValue,
    working_dir: []const u8,
    uid: u32,
    gid: u32,
) !void {
    if (command.len == 0) {
        std.log.err("command is empty", .{});
        return error.EmptyCommand;
    }

    // Change to working directory
    posix.chdir(working_dir) catch |err| {
        std.log.err("chdir to {s} failed: {s}", .{ working_dir, @errorName(err) });
        return err;
    };

    // Set group ID first (must be done before setuid)
    if (gid != 0) {
        const ret = linux.setgid(gid);
        const e = posix.errno(ret);
        if (e != .SUCCESS) {
            std.log.err("setgid to {d} failed: {s}", .{ gid, @tagName(e) });
            return error.SetgidFailed;
        }
    }

    // Set user ID
    if (uid != 0) {
        const ret = linux.setuid(uid);
        const e = posix.errno(ret);
        if (e != .SUCCESS) {
            std.log.err("setuid to {d} failed: {s}", .{ uid, @tagName(e) });
            return error.SetuidFailed;
        }
    }

    // Build argv with null-terminated strings
    // Using static storage since we're about to execve
    const args_slice = args orelse &[_][]const u8{};
    const total_len = command.len + args_slice.len;

    var argv_buf: [64]?[*:0]const u8 = undefined;
    if (total_len + 1 > argv_buf.len) {
        std.log.err("too many arguments", .{});
        return error.TooManyArguments;
    }

    // Storage for null-terminated argument strings
    var arg_storage: [8192]u8 = undefined;
    var arg_pos: usize = 0;

    var i: usize = 0;
    for (command) |arg| {
        if (arg_pos + arg.len + 1 > arg_storage.len) {
            std.log.err("arguments too large", .{});
            return error.ArgumentsTooLarge;
        }
        @memcpy(arg_storage[arg_pos..][0..arg.len], arg);
        arg_storage[arg_pos + arg.len] = 0;
        argv_buf[i] = @ptrCast(&arg_storage[arg_pos]);
        arg_pos += arg.len + 1;
        i += 1;
    }
    for (args_slice) |arg| {
        if (arg_pos + arg.len + 1 > arg_storage.len) {
            std.log.err("arguments too large", .{});
            return error.ArgumentsTooLarge;
        }
        @memcpy(arg_storage[arg_pos..][0..arg.len], arg);
        arg_storage[arg_pos + arg.len] = 0;
        argv_buf[i] = @ptrCast(&arg_storage[arg_pos]);
        arg_pos += arg.len + 1;
        i += 1;
    }
    argv_buf[i] = null;
    const argv = argv_buf[0 .. total_len + 1];

    // Build envp with null-terminated strings
    const env_slice = env orelse &[_]NameValue{};
    var envp_buf: [256]?[*:0]const u8 = undefined;

    if (env_slice.len + 1 > envp_buf.len) {
        std.log.err("too many environment variables", .{});
        return error.TooManyEnvVars;
    }

    var env_storage: [16384]u8 = undefined;
    var env_pos: usize = 0;

    for (env_slice, 0..) |nv, idx| {
        const needed = nv.name.len + 1 + nv.value.len + 1; // name + '=' + value + '\0'
        if (env_pos + needed > env_storage.len) {
            std.log.err("environment too large", .{});
            return error.EnvironmentTooLarge;
        }

        const start = env_pos;
        @memcpy(env_storage[env_pos..][0..nv.name.len], nv.name);
        env_pos += nv.name.len;
        env_storage[env_pos] = '=';
        env_pos += 1;
        @memcpy(env_storage[env_pos..][0..nv.value.len], nv.value);
        env_pos += nv.value.len;
        env_storage[env_pos] = 0;
        env_pos += 1;

        envp_buf[idx] = @ptrCast(&env_storage[start]);
    }
    envp_buf[env_slice.len] = null;
    const envp = envp_buf[0 .. env_slice.len + 1];

    std.log.info("execve: {s}", .{command[0]});

    const exec_result = linux.execve(
        argv[0].?,
        @ptrCast(argv.ptr),
        @ptrCast(envp.ptr),
    );
    const exec_err = posix.errno(exec_result);
    std.log.err("execve failed: {s}", .{@tagName(exec_err)});
    return error.ExecveFailed;
}

fn resolveEnvFrom(allocator: Allocator, vmspec: *VmSpec, env_from: []const EnvFromSource) !void {
    var imds_client: ?aws_sdk.imds.ImdsClient = null;
    defer if (imds_client) |*c| c.deinit();

    const arena_alloc = vmspec.arena.?.allocator();

    for (env_from) |source| {
        if (source.imds) |imds| {
            // Initialize IMDS client lazily
            if (imds_client == null) {
                imds_client = aws_sdk.imds.ImdsClient.init(allocator, .{}) catch |err| {
                    std.log.err("failed to initialize IMDS client: {s}", .{@errorName(err)});
                    if (imds.optional orelse false) continue;
                    return err;
                };
            }

            // Fetch value from IMDS
            const imds_path = try std.fmt.allocPrint(allocator, "/latest/meta-data/{s}", .{imds.path});
            defer allocator.free(imds_path);

            const value = imds_client.?.get(imds_path) catch |err| {
                if (imds.optional orelse false) {
                    std.log.info("optional IMDS path {s} not found, skipping", .{imds.path});
                    continue;
                }
                std.log.err("failed to fetch IMDS path {s}: {s}", .{ imds.path, @errorName(err) });
                return err;
            };
            defer allocator.free(value);

            // Trim whitespace from the value
            const trimmed = std.mem.trim(u8, value, " \t\r\n");

            // Add to environment
            try addEnvVar(arena_alloc, vmspec, imds.name, trimmed);
            std.log.info("resolved env {s} from IMDS path {s}", .{ imds.name, imds.path });
        }

        // S3, SSM, and Secrets Manager will be implemented in Phase 4
        if (source.s3 != null) {
            std.log.warn("S3 env-from not yet implemented", .{});
        }
        if (source.ssm != null) {
            std.log.warn("SSM env-from not yet implemented", .{});
        }
        if (source.@"secrets-manager" != null) {
            std.log.warn("Secrets Manager env-from not yet implemented", .{});
        }
    }
}

fn addEnvVar(allocator: Allocator, vmspec: *VmSpec, name: []const u8, value: []const u8) !void {
    const new_nv = NameValue{
        .name = try allocator.dupe(u8, name),
        .value = try allocator.dupe(u8, value),
    };

    if (vmspec.env) |existing_env| {
        // Check if the variable already exists
        for (existing_env, 0..) |nv, i| {
            if (std.mem.eql(u8, nv.name, name)) {
                // Replace existing value
                var env_copy = try allocator.alloc(NameValue, existing_env.len);
                @memcpy(env_copy, existing_env);
                env_copy[i] = new_nv;
                vmspec.env = env_copy;
                return;
            }
        }
        // Append new variable
        var new_env = try allocator.alloc(NameValue, existing_env.len + 1);
        @memcpy(new_env[0..existing_env.len], existing_env);
        new_env[existing_env.len] = new_nv;
        vmspec.env = new_env;
    } else {
        // Create new env array
        var new_env = try allocator.alloc(NameValue, 1);
        new_env[0] = new_nv;
        vmspec.env = new_env;
    }
}

const ExpandedCommand = struct {
    command: []const []const u8,
    args: ?[]const []const u8,

    fn deinit(self: ExpandedCommand, allocator: Allocator) void {
        for (self.command) |s| allocator.free(s);
        allocator.free(self.command);
        if (self.args) |args| {
            for (args) |s| allocator.free(s);
            allocator.free(args);
        }
    }
};

fn expandCommandAndArgs(
    allocator: Allocator,
    command: []const []const u8,
    args: ?[]const []const u8,
    env: ?[]const NameValue,
) !ExpandedCommand {
    // Build mapping from env
    var mapping = std.StringHashMap([]const u8).init(allocator);
    defer mapping.deinit();

    if (env) |env_slice| {
        for (env_slice) |nv| {
            try mapping.put(nv.name, nv.value);
        }
    }

    // Create context as array of pointers to hash maps
    const context = [_]*const std.StringHashMap([]const u8){&mapping};

    // Expand command
    var expanded_command = try allocator.alloc([]const u8, command.len);
    for (command, 0..) |arg, i| {
        expanded_command[i] = try k8s_expand.expand(allocator, arg, &context);
    }

    // Expand args if present
    var expanded_args: ?[]const []const u8 = null;
    if (args) |args_slice| {
        var exp_args = try allocator.alloc([]const u8, args_slice.len);
        for (args_slice, 0..) |arg, i| {
            exp_args[i] = try k8s_expand.expand(allocator, arg, &context);
        }
        expanded_args = exp_args;
    }

    return ExpandedCommand{
        .command = expanded_command,
        .args = expanded_args,
    };
}
