const std = @import("std");
const fmt = std.fmt;
const mount = std.os.linux.mount;
const ms = std.os.linux.MS;
const Mode = std.fs.File.Mode;
const Allocator = std.mem.Allocator;
const linux = std.os.linux;
const posix = std.posix;
const testing = std.testing;

const aws_sdk = @import("aws_sdk");
const k8s_expand = @import("k8s_expand");

const asm_mod = @import("aws/asm.zig");
const AwsContext = @import("aws/context.zig").AwsContext;
const s3_mod = @import("aws/s3.zig");
const ssm_mod = @import("aws/ssm.zig");
const constants = @import("constants.zig");
const container = @import("container.zig");
const fs_utils = @import("fs.zig");
const log_level = @import("log_level.zig");
const mkdir_p = fs_utils.mkdir_p;
const network = @import("network.zig");
const service = @import("service.zig");
const Supervisor = service.Supervisor;
const spot = @import("spot.zig");
const system = @import("system.zig");
const uevent = @import("uevent.zig");
const vmspec_mod = @import("vmspec.zig");
const VmSpec = vmspec_mod.VmSpec;
const EbsVolumeSource = vmspec_mod.EbsVolumeSource;
const EnvFromSource = vmspec_mod.EnvFromSource;
const NameValue = vmspec_mod.NameValue;
const Volume = vmspec_mod.Volume;
const S3VolumeSource = vmspec_mod.S3VolumeSource;
const SsmVolumeSource = vmspec_mod.SsmVolumeSource;
const SecretsManagerVolumeSource = vmspec_mod.SecretsManagerVolumeSource;

const Error = error{
    MountError,
    S3VolumeEmpty,
    ParameterNotFound,
    SecretNotFound,
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

    std.log.info("initializing AWS context", .{});
    var aws_ctx = try AwsContext.init(allocator);
    defer aws_ctx.deinit();

    std.log.info("initializing network", .{});
    try network.initializeNetwork(allocator, aws_ctx.getImds());

    // Fetch user data from IMDS
    std.log.info("fetching user data from IMDS", .{});
    const user_data = fetchUserData(&aws_ctx) catch |err| blk: {
        std.log.warn("failed to fetch user data: {s}, continuing without", .{@errorName(err)});
        break :blk null;
    };
    defer if (user_data) |ud| allocator.free(ud);

    // Parse user data early so we can enable debug logging before
    // NVMe linking and other operations.
    var user_vmspec_parsed: ?VmSpec = null;
    if (user_data) |ud| {
        std.log.info("parsing user data YAML", .{});
        if (VmSpec.from_yaml(allocator, ud)) |user_vmspec_opt| {
            user_vmspec_parsed = user_vmspec_opt;
        } else |err| {
            std.log.err("unable to parse user data: {s}", .{@errorName(err)});
            return err;
        }
    }
    defer if (user_vmspec_parsed) |*uv| uv.deinit();

    if (user_vmspec_parsed) |uv| {
        if (uv.debug != null and uv.debug.?) {
            log_level.setLevel(.debug);
            std.log.debug("debug logging enabled", .{});
        }
    }

    std.log.info("starting uevent listener", .{});
    try uevent.startUeventListener(allocator);

    std.log.info("linking nvme devices", .{});
    try system.link_nvme_devices(allocator);

    std.log.info("reading metadata", .{});
    const config_file_path = constants.DIR_ET ++ "/" ++ constants.FILE_METADATA;
    var metadata = try read_metadata(allocator, config_file_path);
    defer metadata.deinit();

    std.log.info("parsing vmspec", .{});
    var vmspec = try VmSpec.from_config_file(allocator, &metadata.parsed.value);
    defer vmspec.deinit();

    // Merge user data if available
    if (user_vmspec_parsed) |user_vmspec| {
        std.log.info("merging user data into vmspec", .{});
        try vmspec.merge(user_vmspec);
    }

    // Resolve env-from sources
    if (vmspec.@"env-from") |env_from| {
        std.log.info("resolving env-from sources", .{});
        resolveEnvFrom(allocator, &aws_ctx, &vmspec, env_from) catch |err| {
            std.log.err("unable to resolve environment variables from external sources", .{});
            return err;
        };
    }

    // Expand variable references in env values (e.g., $(VAR) syntax)
    if (vmspec.env) |env| {
        try expandEnvValues(allocator, &vmspec, env);
    }

    std.log.info("loading kernel modules", .{});
    try system.loadModules(vmspec.modules);

    std.log.info("applying sysctls", .{});
    try system.setSysctls(vmspec.sysctls);

    std.log.info("resizing root volume", .{});
    system.resizeRootVolume(allocator);

    // Process volumes
    if (vmspec.volumes) |volumes| {
        std.log.info("processing volumes", .{});
        try processVolumes(&aws_ctx, volumes);
    }

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

    const readonly_root_fs = vmspec.security.@"readonly-root-fs" orelse false;

    if (replace_init) {
        std.log.info("replacing init with command", .{});
        try replaceInit(
            command,
            args,
            vmspec.env,
            working_dir,
            uid,
            gid,
            readonly_root_fs,
        );
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
            vmspec.@"disable-services",
            aws_ctx.getImds(),
            readonly_root_fs,
        );

        try supervisor.start();
        spot.startSpotTerminationMonitor();
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

fn fetchUserData(aws_ctx: *AwsContext) !?[]const u8 {
    const imds_client = aws_ctx.getImds();

    const user_data = imds_client.get("/latest/user-data") catch |err| {
        if (err == error.HttpNotFound) {
            return null;
        }
        std.log.err("failed to fetch user data from IMDS: {s}", .{@errorName(err)});
        return err;
    };

    return user_data;
}

fn replaceInit(
    command: []const []const u8,
    args: ?[]const []const u8,
    env: ?[]const NameValue,
    working_dir: []const u8,
    uid: u32,
    gid: u32,
    readonly_root_fs: bool,
) !void {
    if (command.len == 0) {
        std.log.err("command is empty", .{});
        return error.EmptyCommand;
    }

    if (readonly_root_fs) {
        try system.remountRootReadonly();
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
    std.log.err("execve failed: {s}", .{service.errnoDescription(exec_err)});
    return error.ExecveFailed;
}

fn resolveEnvFrom(
    allocator: Allocator,
    aws_ctx: *AwsContext,
    vmspec: *VmSpec,
    env_from: []const EnvFromSource,
) !void {
    const arena_alloc = vmspec.arena.?.allocator();

    for (env_from) |source| {
        if (source.imds) |imds| {
            const imds_client = aws_ctx.getImds();

            // Fetch value from IMDS
            const imds_path = try std.fmt.allocPrint(allocator, "/latest/meta-data/{s}", .{imds.path});
            defer allocator.free(imds_path);

            const value = imds_client.get(imds_path) catch |err| {
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

        if (source.s3) |s3| {
            const s3_client = try aws_ctx.getS3();

            if (s3.name) |name| {
                // Single value with explicit name
                const value = s3_client.getObject(s3.bucket, s3.key) catch |err| {
                    if (s3.optional orelse false) {
                        std.log.info(
                            "optional S3 object s3://{s}/{s} not found, skipping",
                            .{ s3.bucket, s3.key },
                        );
                        continue;
                    }
                    std.log.err(
                        "failed to fetch S3 object s3://{s}/{s}: {s}",
                        .{ s3.bucket, s3.key, @errorName(err) },
                    );
                    return err;
                };
                defer allocator.free(value);

                // Trim whitespace from the value
                const trimmed = std.mem.trim(u8, value, " \t\r\n");

                try addEnvVar(arena_alloc, vmspec, name, trimmed);
                std.log.info("resolved env {s} from S3 s3://{s}/{s}", .{ name, s3.bucket, s3.key });
            } else {
                // JSON map expanded to multiple env vars
                var env_map = s3_client.getObjectMap(s3.bucket, s3.key) catch |err| {
                    if (s3.optional orelse false) {
                        std.log.info(
                            "optional S3 object s3://{s}/{s} not found, skipping",
                            .{ s3.bucket, s3.key },
                        );
                        continue;
                    }
                    std.log.err(
                        "failed to fetch S3 object map s3://{s}/{s}: {s}",
                        .{ s3.bucket, s3.key, @errorName(err) },
                    );
                    return err;
                };
                defer {
                    var it = env_map.iterator();
                    while (it.next()) |entry| {
                        allocator.free(entry.key_ptr.*);
                        allocator.free(entry.value_ptr.*);
                    }
                    env_map.deinit();
                }

                var map_it = env_map.iterator();
                while (map_it.next()) |entry| {
                    try addEnvVar(arena_alloc, vmspec, entry.key_ptr.*, entry.value_ptr.*);
                    std.log.info(
                        "resolved env {s} from S3 s3://{s}/{s}",
                        .{ entry.key_ptr.*, s3.bucket, s3.key },
                    );
                }
            }
        }

        if (source.ssm) |ssm| {
            const ssm_client = try aws_ctx.getSsm();

            if (ssm.name) |name| {
                // Single value with explicit name
                const value = ssm_client.getParameter(ssm.path) catch |err| {
                    if (ssm.optional orelse false) {
                        std.log.info("optional SSM parameter {s} not found, skipping", .{ssm.path});
                        continue;
                    }
                    std.log.err("failed to fetch SSM parameter {s}: {s}", .{ ssm.path, @errorName(err) });
                    return err;
                };
                defer allocator.free(value);

                // Trim whitespace from the value
                const trimmed = std.mem.trim(u8, value, " \t\r\n");

                try addEnvVar(arena_alloc, vmspec, name, trimmed);
                std.log.info("resolved env {s} from SSM parameter {s}", .{ name, ssm.path });
            } else {
                // JSON map expanded to multiple env vars
                var env_map = ssm_client.getParameterMap(ssm.path) catch |err| {
                    if (ssm.optional orelse false) {
                        std.log.info("optional SSM parameter {s} not found, skipping", .{ssm.path});
                        continue;
                    }
                    std.log.err("failed to fetch SSM parameter map {s}: {s}", .{ ssm.path, @errorName(err) });
                    return err;
                };
                defer {
                    var it = env_map.iterator();
                    while (it.next()) |entry| {
                        allocator.free(entry.key_ptr.*);
                        allocator.free(entry.value_ptr.*);
                    }
                    env_map.deinit();
                }

                var map_it = env_map.iterator();
                while (map_it.next()) |entry| {
                    try addEnvVar(arena_alloc, vmspec, entry.key_ptr.*, entry.value_ptr.*);
                    std.log.info("resolved env {s} from SSM parameter {s}", .{ entry.key_ptr.*, ssm.path });
                }
            }
        }

        if (source.@"secrets-manager") |sm| {
            const sm_client = try aws_ctx.getSecretsManager();

            if (sm.name) |name| {
                // Single value with explicit name
                const value = sm_client.getSecretValue(sm.@"secret-id") catch |err| {
                    if (sm.optional orelse false) {
                        std.log.info("optional secret {s} not found, skipping", .{sm.@"secret-id"});
                        continue;
                    }
                    std.log.err("failed to fetch secret {s}: {s}", .{ sm.@"secret-id", @errorName(err) });
                    return err;
                };
                defer allocator.free(value);

                // Trim whitespace from the value
                const trimmed = std.mem.trim(u8, value, " \t\r\n");

                try addEnvVar(arena_alloc, vmspec, name, trimmed);
                std.log.info("resolved env {s} from secret {s}", .{ name, sm.@"secret-id" });
            } else {
                // JSON map expanded to multiple env vars
                var env_map = sm_client.getSecretMap(sm.@"secret-id") catch |err| {
                    if (sm.optional orelse false) {
                        std.log.info("optional secret {s} not found, skipping", .{sm.@"secret-id"});
                        continue;
                    }
                    std.log.err("failed to fetch secret map {s}: {s}", .{ sm.@"secret-id", @errorName(err) });
                    return err;
                };
                defer {
                    var it = env_map.iterator();
                    while (it.next()) |entry| {
                        allocator.free(entry.key_ptr.*);
                        allocator.free(entry.value_ptr.*);
                    }
                    env_map.deinit();
                }

                var map_it = env_map.iterator();
                while (map_it.next()) |entry| {
                    try addEnvVar(arena_alloc, vmspec, entry.key_ptr.*, entry.value_ptr.*);
                    std.log.info("resolved env {s} from secret {s}", .{ entry.key_ptr.*, sm.@"secret-id" });
                }
            }
        }
    }
}

fn expandEnvValues(allocator: Allocator, vmspec: *VmSpec, env: []const NameValue) !void {
    const arena_alloc = vmspec.arena.?.allocator();

    // Build mapping from current env
    var mapping = std.StringHashMap([]const u8).init(allocator);
    defer mapping.deinit();

    for (env) |nv| {
        try mapping.put(nv.name, nv.value);
    }

    const context = [_]*const std.StringHashMap([]const u8){&mapping};

    // Expand values and update env
    var new_env = try arena_alloc.alloc(NameValue, env.len);
    for (env, 0..) |nv, i| {
        const expanded_value = try k8s_expand.expand(allocator, nv.value, &context);
        defer allocator.free(expanded_value);

        new_env[i] = NameValue{
            .name = nv.name,
            .value = if (!std.mem.eql(u8, expanded_value, nv.value))
                try arena_alloc.dupe(u8, expanded_value)
            else
                nv.value,
        };
    }
    vmspec.env = new_env;
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

fn processVolumes(aws_ctx: *AwsContext, volumes: []const Volume) !void {
    for (volumes) |volume| {
        if (volume.s3) |s3| {
            try handleS3Volume(aws_ctx, &s3);
        }
        if (volume.ssm) |ssm| {
            try handleSsmVolume(aws_ctx, &ssm);
        }
        if (volume.@"secrets-manager") |sm| {
            try handleSecretsManagerVolume(aws_ctx, &sm);
        }
        if (volume.ebs) |ebs| {
            try handleEbsVolume(aws_ctx, &ebs);
        }
    }
}

fn handleSsmVolume(aws_ctx: *AwsContext, volume: *const SsmVolumeSource) !void {
    const path = volume.path;
    const destination = volume.mount.destination;
    const optional = volume.optional orelse false;

    std.log.info("processing SSM volume {s} -> {s}", .{ path, destination });

    const ssm_client = try aws_ctx.getSsm();

    const result = ssm_client.downloadPathToDir(path, destination, .{
        .uid = volume.mount.@"user-id",
        .gid = volume.mount.@"group-id",
    }) catch |err| {
        if (optional) {
            std.log.info("optional SSM volume {s} failed, skipping: {s}", .{ path, @errorName(err) });
            return;
        }
        std.log.err("failed to download SSM volume {s}: {s}", .{ path, @errorName(err) });
        return err;
    };

    if (result.files_written == 0) {
        if (optional) {
            std.log.info("no parameters found at {s}, skipping (optional)", .{path});
            return;
        }
        std.log.err("no SSM parameters found at {s}", .{path});
        return error.ParameterNotFound;
    }

    std.log.info("SSM volume {s} mounted to {s} ({d} files)", .{ path, destination, result.files_written });
}

fn handleS3Volume(aws_ctx: *AwsContext, volume: *const S3VolumeSource) !void {
    const bucket = volume.bucket;
    const key_prefix = volume.@"key-prefix";
    const destination = volume.mount.destination;
    const optional = volume.optional orelse false;

    std.log.info("processing S3 volume s3://{s}/{s} -> {s}", .{ bucket, key_prefix, destination });

    const s3_client = try aws_ctx.getS3();

    const result = s3_client.downloadPrefixToDir(bucket, key_prefix, destination, .{
        .uid = volume.mount.@"user-id",
        .gid = volume.mount.@"group-id",
    }) catch |err| {
        if (optional) {
            std.log.info("optional S3 volume s3://{s}/{s} failed, skipping: {s}", .{ bucket, key_prefix, @errorName(err) });
            return;
        }
        std.log.err("failed to download S3 volume s3://{s}/{s}: {s}", .{ bucket, key_prefix, @errorName(err) });
        return err;
    };

    if (result.files_written == 0) {
        if (optional) {
            std.log.info("no objects found in s3://{s}/{s}, skipping (optional)", .{ bucket, key_prefix });
            return;
        }
        std.log.err("no S3 objects found at s3://{s}/{s}", .{ bucket, key_prefix });
        return error.S3VolumeEmpty;
    }

    std.log.info("S3 volume s3://{s}/{s} mounted to {s} ({d} files)", .{ bucket, key_prefix, destination, result.files_written });
}

fn handleSecretsManagerVolume(aws_ctx: *AwsContext, volume: *const SecretsManagerVolumeSource) !void {
    const secret_id = volume.@"secret-id";
    const destination = volume.mount.destination;
    const optional = volume.optional orelse false;

    std.log.info("processing Secrets Manager volume {s} -> {s}", .{ secret_id, destination });

    const sm_client = try aws_ctx.getSecretsManager();

    sm_client.downloadSecretToFile(secret_id, destination, .{
        .uid = volume.mount.@"user-id",
        .gid = volume.mount.@"group-id",
    }) catch |err| {
        if (optional) {
            std.log.info("optional secret {s} failed, skipping: {s}", .{ secret_id, @errorName(err) });
            return;
        }
        std.log.err("failed to download secret {s}: {s}", .{ secret_id, @errorName(err) });
        return err;
    };

    std.log.info("Secrets Manager secret {s} mounted to {s}", .{ secret_id, destination });
}

fn handleEbsVolume(aws_ctx: *AwsContext, volume: *const EbsVolumeSource) !void {
    const device = volume.device;

    std.log.info("processing EBS volume {s}", .{device});

    // Validate device is specified
    if (device.len == 0) {
        std.log.err("EBS volume must have a device", .{});
        return error.InvalidEbsConfig;
    }

    // Validate mount configuration if present
    if (volume.mount) |mnt| {
        if (mnt.destination.len == 0) {
            std.log.err("EBS volume mount must have a destination", .{});
            return error.InvalidEbsConfig;
        }
    }

    // Handle volume attachment if specified
    if (volume.attachment) |attachment| {
        const imds_client = aws_ctx.getImds();

        // Get availability zone from IMDS
        const az = imds_client.get("/latest/meta-data/placement/availability-zone") catch |err| {
            std.log.err("failed to get availability zone from IMDS: {s}", .{@errorName(err)});
            return err;
        };
        defer aws_ctx.allocator.free(az);

        // Get instance ID from IMDS
        const instance_id = imds_client.get("/latest/meta-data/instance-id") catch |err| {
            std.log.err("failed to get instance ID from IMDS: {s}", .{@errorName(err)});
            return err;
        };
        defer aws_ctx.allocator.free(instance_id);

        // Get EC2 client and ensure volume is attached
        const ec2_client = try aws_ctx.getEc2();
        ec2_client.ensureVolumeAttached(
            &attachment,
            device,
            std.mem.trim(u8, az, " \t\r\n"),
            std.mem.trim(u8, instance_id, " \t\r\n"),
        ) catch |err| {
            std.log.err("unable to ensure EBS volume {s} is attached: {s}", .{ device, @errorName(err) });
            return err;
        };

        std.log.info("EBS volume {s} is attached", .{device});

        // Wait for device to appear
        const timeout = attachment.timeout orelse 300;
        system.waitForDevice(device, timeout) catch |err| {
            std.log.err("timeout waiting for device {s}: {s}", .{ device, @errorName(err) });
            return err;
        };

        std.log.info("EBS volume device {s} is available", .{device});
    }

    // If no mount specified, we're done
    const mnt = volume.mount orelse return;

    // Get filesystem type (required for mounting)
    const fs_type = volume.@"fs-type" orelse {
        std.log.err("EBS volume mount must have a filesystem type", .{});
        return error.InvalidEbsConfig;
    };

    // Create filesystem if make-fs is true or not specified (default: create if needed)
    const make_fs = volume.@"make-fs" orelse true;
    if (make_fs) {
        system.createFilesystem(device, fs_type) catch |err| {
            std.log.err("failed to create filesystem on {s}: {s}", .{ device, @errorName(err) });
            return err;
        };
    }

    // Parse mode if specified
    const mode: std.fs.File.Mode = if (mnt.mode) |mode_str|
        std.fmt.parseInt(u32, mode_str, 8) catch 0o755
    else
        0o755;

    // Create mount point with proper permissions
    fs_utils.mkdir_p_own(mnt.destination, mode, mnt.@"user-id", mnt.@"group-id") catch |err| {
        std.log.err("failed to create mount point {s}: {s}", .{ mnt.destination, @errorName(err) });
        return err;
    };

    // Mount the device
    system.mountDevice(device, mnt.destination, fs_type) catch |err| {
        std.log.err("failed to mount {s} on {s}: {s}", .{ device, mnt.destination, @errorName(err) });
        return err;
    };

    std.log.info("EBS volume {s} mounted to {s}", .{ device, mnt.destination });
}

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
    var cmd_count: usize = 0;
    errdefer {
        for (expanded_command[0..cmd_count]) |s| allocator.free(s);
        allocator.free(expanded_command);
    }
    for (command, 0..) |arg, i| {
        expanded_command[i] = try k8s_expand.expand(allocator, arg, &context);
        cmd_count += 1;
    }

    // Expand args if present
    var expanded_args: ?[]const []const u8 = null;
    if (args) |args_slice| {
        var exp_args = try allocator.alloc([]const u8, args_slice.len);
        var args_count: usize = 0;
        errdefer {
            for (exp_args[0..args_count]) |s| allocator.free(s);
            allocator.free(exp_args);
        }
        for (args_slice, 0..) |arg, i| {
            exp_args[i] = try k8s_expand.expand(allocator, arg, &context);
            args_count += 1;
        }
        expanded_args = exp_args;
    }

    return ExpandedCommand{
        .command = expanded_command,
        .args = expanded_args,
    };
}

test "addEnvVar adds to empty env" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var vmspec = VmSpec{
        .arena = arena,
    };

    try addEnvVar(arena.allocator(), &vmspec, "FOO", "bar");

    try testing.expect(vmspec.env != null);
    try testing.expectEqual(@as(usize, 1), vmspec.env.?.len);
    try testing.expectEqualStrings("FOO", vmspec.env.?[0].name);
    try testing.expectEqualStrings("bar", vmspec.env.?[0].value);
}

test "addEnvVar appends new variable" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var vmspec = VmSpec{
        .arena = arena,
    };

    try addEnvVar(arena.allocator(), &vmspec, "FOO", "bar");
    try addEnvVar(arena.allocator(), &vmspec, "BAZ", "qux");

    try testing.expect(vmspec.env != null);
    try testing.expectEqual(@as(usize, 2), vmspec.env.?.len);
    try testing.expectEqualStrings("FOO", vmspec.env.?[0].name);
    try testing.expectEqualStrings("BAZ", vmspec.env.?[1].name);
}

test "addEnvVar replaces existing variable" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var vmspec = VmSpec{
        .arena = arena,
    };

    try addEnvVar(arena.allocator(), &vmspec, "FOO", "bar");
    try addEnvVar(arena.allocator(), &vmspec, "FOO", "updated");

    try testing.expect(vmspec.env != null);
    try testing.expectEqual(@as(usize, 1), vmspec.env.?.len);
    try testing.expectEqualStrings("FOO", vmspec.env.?[0].name);
    try testing.expectEqualStrings("updated", vmspec.env.?[0].value);
}

test "expandCommandAndArgs with no env" {
    const allocator = testing.allocator;

    var command = [_][]const u8{ "/bin/echo", "hello" };
    const expanded = try expandCommandAndArgs(allocator, &command, null, null);
    defer expanded.deinit(allocator);

    try testing.expectEqual(@as(usize, 2), expanded.command.len);
    try testing.expectEqualStrings("/bin/echo", expanded.command[0]);
    try testing.expectEqualStrings("hello", expanded.command[1]);
    try testing.expect(expanded.args == null);
}

test "expandCommandAndArgs expands variables in command" {
    const allocator = testing.allocator;

    var command = [_][]const u8{ "/bin/echo", "$(MSG)" };
    var env = [_]NameValue{
        .{ .name = "MSG", .value = "hello world" },
    };
    const expanded = try expandCommandAndArgs(allocator, &command, null, &env);
    defer expanded.deinit(allocator);

    try testing.expectEqual(@as(usize, 2), expanded.command.len);
    try testing.expectEqualStrings("/bin/echo", expanded.command[0]);
    try testing.expectEqualStrings("hello world", expanded.command[1]);
}

test "expandCommandAndArgs expands variables in args" {
    const allocator = testing.allocator;

    var command = [_][]const u8{"/bin/sh"};
    var args = [_][]const u8{ "-c", "echo $(MSG)" };
    var env = [_]NameValue{
        .{ .name = "MSG", .value = "test" },
    };
    const expanded = try expandCommandAndArgs(allocator, &command, &args, &env);
    defer expanded.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), expanded.command.len);
    try testing.expectEqualStrings("/bin/sh", expanded.command[0]);

    try testing.expect(expanded.args != null);
    try testing.expectEqual(@as(usize, 2), expanded.args.?.len);
    try testing.expectEqualStrings("-c", expanded.args.?[0]);
    try testing.expectEqualStrings("echo test", expanded.args.?[1]);
}

test "expandCommandAndArgs with multiple env vars" {
    const allocator = testing.allocator;

    var command = [_][]const u8{ "$(CMD)", "$(ARG1)", "$(ARG2)" };
    var env = [_]NameValue{
        .{ .name = "CMD", .value = "/usr/bin/test" },
        .{ .name = "ARG1", .value = "first" },
        .{ .name = "ARG2", .value = "second" },
    };
    const expanded = try expandCommandAndArgs(allocator, &command, null, &env);
    defer expanded.deinit(allocator);

    try testing.expectEqual(@as(usize, 3), expanded.command.len);
    try testing.expectEqualStrings("/usr/bin/test", expanded.command[0]);
    try testing.expectEqualStrings("first", expanded.command[1]);
    try testing.expectEqualStrings("second", expanded.command[2]);
}

test "expandCommandAndArgs preserves literal strings" {
    const allocator = testing.allocator;

    var command = [_][]const u8{ "/bin/echo", "no variables here" };
    var env = [_]NameValue{
        .{ .name = "UNUSED", .value = "value" },
    };
    const expanded = try expandCommandAndArgs(allocator, &command, null, &env);
    defer expanded.deinit(allocator);

    try testing.expectEqualStrings("no variables here", expanded.command[1]);
}

test "ExpandedCommand.deinit frees command" {
    const allocator = testing.allocator;

    var command = [_][]const u8{"/bin/echo"};
    const expanded = try expandCommandAndArgs(allocator, &command, null, null);
    expanded.deinit(allocator);
}

test "ExpandedCommand.deinit frees args" {
    const allocator = testing.allocator;

    var command = [_][]const u8{"/bin/sh"};
    var args = [_][]const u8{ "-c", "echo hello" };
    const expanded = try expandCommandAndArgs(allocator, &command, &args, null);
    expanded.deinit(allocator);
}
