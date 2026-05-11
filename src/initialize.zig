const std = @import("std");
const fmt = std.fmt;
const mount = std.os.linux.mount;
const ms = std.os.linux.MS;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const linux = std.os.linux;
const posix = std.posix;
const testing = std.testing;

const aws = @import("aws");
const k8s_expand = @import("k8s_expand");

const AwsContext = @import("aws/context.zig").AwsContext;
const constants = @import("constants.zig");
const container = @import("container.zig");
const dag = @import("dag.zig");
const EbsVolumeSource = @import("vmspec.zig").EbsVolumeSource;
const EnvFromSource = @import("vmspec.zig").EnvFromSource;
const fs = @import("fs.zig");
const log_level = @import("log_level.zig");
const NameValue = @import("vmspec.zig").NameValue;
const network = @import("network.zig");
const process = @import("process.zig");
const S3VolumeSource = @import("vmspec.zig").S3VolumeSource;
const SecretsManagerVolumeSource = @import("vmspec.zig").SecretsManagerVolumeSource;
const service = @import("service.zig");
const Supervisor = service.Supervisor;
const spot = @import("spot.zig");
const SsmVolumeSource = @import("vmspec.zig").SsmVolumeSource;
const system = @import("system.zig");
const template = @import("template.zig");
const TemplateVolumeSource = @import("vmspec.zig").TemplateVolumeSource;
const uevent = @import("uevent.zig");
const VmSpec = @import("vmspec.zig").VmSpec;
const Volume = @import("vmspec.zig").Volume;

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
    mode: posix.mode_t,
    options: ?[]const u8 = null,
    target: []const u8,

    pub fn execute(self: Mount, io: Io) !void {
        fs.mkdirRecursive(io, self.target, self.mode) catch |err| {
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
                std.log.err(
                    "mount {s} on {s} failed: {s}",
                    .{ self.source, self.target, @tagName(e) },
                );
                return Error.MountError;
            },
        }
    }
};

const Link = struct {
    path: []const u8,
    target: []const u8,
};

pub fn run(allocator: Allocator, io: Io, env_map: *std.process.Environ.Map) !void {
    // Pre-DAG serial phase.
    try baseMounts(io);
    try setupTestMode(env_map);
    const boot_start = Io.Timestamp.now(io, .awake);
    std.log.info("easyto-init started", .{});
    std.log.info("creating base symlinks", .{});
    try baseLinks(io);

    // Parallel DAG phase.
    var ctx = dag.BootContext.init(allocator, io, env_map);
    defer ctx.deinit();
    var executor = dag.DagExecutor.init(&ctx);
    try executor.run();

    // Post-DAG: start supervisor.
    const vmspec = ctx.vmspec.?;
    const expanded = ctx.expanded_command.?;
    const command = expanded.command;
    const args = expanded.args;
    const uid = vmspec.security.@"run-as-user-id" orelse 0;
    const gid = vmspec.security.@"run-as-group-id" orelse 0;
    const working_dir = vmspec.@"working-dir" orelse "/";
    const shutdown_grace_period = vmspec.@"shutdown-grace-period" orelse 10;
    const replace_init = vmspec.@"replace-init" orelse false;
    const readonly_root_fs = vmspec.security.@"readonly-root-fs" orelse false;

    if (replace_init) {
        std.log.info(
            "easyto-init boot completed in {d}ms",
            .{boot_start.durationTo(Io.Timestamp.now(io, .awake)).toMilliseconds()},
        );
        try replaceInit(
            allocator,
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
            io,
            env_map,
            command,
            args,
            vmspec.env,
            working_dir,
            uid,
            gid,
            shutdown_grace_period,
            vmspec.@"disable-services",
            ctx.aws_ctx.?.getImds(),
            readonly_root_fs,
        );

        try supervisor.start();
        spot.startSpotTerminationMonitor(allocator, io, env_map);
        std.log.info(
            "easyto-init boot completed in {d}ms",
            .{boot_start.durationTo(Io.Timestamp.now(io, .awake)).toMilliseconds()},
        );
        supervisor.wait();

        std.log.info("supervisor finished, shutting down", .{});
    }
}

fn baseMounts(io: Io) !void {
    const mounts = [_]Mount{
        .{
            .source = "devtmpfs",
            .flags = ms.NOSUID,
            .fs_type = "devtmpfs",
            .mode = 0o755,
            .target = constants.dir_dev,
        },
        .{
            .source = "devpts",
            .flags = ms.NOATIME | ms.NOEXEC | ms.NOSUID,
            .fs_type = "devpts",
            .mode = 0o755,
            .options = "mode=0620,gid=5,ptmxmode=666",
            .target = constants.dir_dev_pts,
        },
        .{
            .source = "mqueue",
            .flags = ms.NODEV | ms.NOEXEC | ms.NOSUID,
            .fs_type = "mqueue",
            .mode = 0o755,
            .target = constants.dir_dev_mqueue,
        },
        .{
            .source = "tmpfs",
            .flags = ms.NODEV | ms.NOSUID,
            .fs_type = "tmpfs",
            .mode = 0o1777,
            .target = constants.dir_dev_shm,
        },
        .{
            .source = "hugetlbfs",
            .flags = ms.RELATIME,
            .fs_type = "hugetlbfs",
            .mode = 0o755,
            .target = constants.dir_dev_hugepages,
        },
        .{
            .source = "proc",
            .flags = ms.NODEV | ms.NOEXEC | ms.RELATIME | ms.NOSUID,
            .fs_type = "proc",
            .mode = 0o555,
            .target = constants.dir_proc,
        },
        .{
            .source = "sys",
            .flags = ms.NODEV | ms.NOEXEC | ms.NOSUID,
            .fs_type = "sysfs",
            .mode = 0o555,
            .target = constants.dir_sys,
        },
        .{
            .source = "tmpfs",
            .flags = ms.NODEV | ms.NOSUID,
            .fs_type = "tmpfs",
            .mode = 0o755,
            .options = "mode=0755",
            .target = constants.dir_et_run,
        },
        .{
            .source = "cgroup2",
            .flags = ms.NODEV | ms.NOEXEC | ms.RELATIME | ms.NOSUID,
            .fs_type = "cgroup2",
            .mode = 0o555,
            .options = "nsdelegate",
            .target = constants.dir_sys_fs_cgroup,
        },
        .{
            .source = "debugfs",
            .flags = ms.NODEV | ms.NOEXEC | ms.RELATIME | ms.NOSUID,
            .fs_type = "debugfs",
            .mode = 0o500,
            .target = constants.dir_sys_kernel_debug,
        },
    };

    for (mounts) |m| try m.execute(io);
}

fn baseLinks(io: Io) !void {
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
        Io.Dir.symLinkAbsolute(io, link.target, link.path, .{}) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };
    }
}

fn setupTestMode(env_map: *std.process.Environ.Map) !void {
    _ = env_map.get("EASYTO_TEST_MODE") orelse return;

    const tty_path = "/dev/ttyS0";

    // Make serial console accessible to non-root users
    const tty_fd = posix.openat(
        linux.AT.FDCWD,
        tty_path,
        .{ .ACCMODE = .WRONLY },
        0,
    ) catch |err| {
        std.log.err("unable to open {s}: {s}", .{ tty_path, @errorName(err) });
        return err;
    };

    const chmod_errno = posix.errno(linux.fchmod(tty_fd, 0o666));
    if (chmod_errno != .SUCCESS) {
        std.log.err("unable to chmod {s}: {s}", .{ tty_path, @tagName(chmod_errno) });
        return error.FchmodFailed;
    }

    // Redirect stderr to serial console
    const dup2_errno = posix.errno(linux.dup2(tty_fd, posix.STDERR_FILENO));
    if (dup2_errno != .SUCCESS) {
        std.log.err("unable to dup2 stderr to {s}: {s}", .{ tty_path, @tagName(dup2_errno) });
        return error.Dup2Failed;
    }

    _ = linux.close(tty_fd);

    std.log.info("test mode enabled", .{});
}

pub const Metadata = struct {
    contents: []const u8,
    parsed: std.json.Parsed(container.ConfigFile),
    allocator: Allocator,

    pub fn deinit(self: *Metadata) void {
        self.parsed.deinit();
        self.allocator.free(self.contents);
    }
};

pub fn readMetadata(allocator: Allocator, io: Io, path: []const u8) !Metadata {
    const contents = try Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(1073741824),
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

pub fn fetchUserData(allocator: Allocator, aws_ctx: *AwsContext) !?[]const u8 {
    const imds_client = aws_ctx.getImds();

    var diagnostic: aws.imds.ServiceError = undefined;
    const raw = imds_client.getMetadata(
        "/latest/user-data",
        .{ .diagnostic = &diagnostic },
    ) catch |err| {
        if (err == error.HttpError and diagnostic.httpStatus() == 404) {
            return null;
        }
        std.log.err("failed to fetch user data from IMDS: {s}", .{@errorName(err)});
        return err;
    };
    defer aws_ctx.allocator.free(raw);

    if (raw.len >= 2 and raw[0] == 0x1f and raw[1] == 0x8b) {
        std.log.debug("user data is gzip compressed, decompressing", .{});
        var in: std.Io.Reader = .fixed(raw);
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        var decomp: std.compress.flate.Decompress = .init(&in, .gzip, &.{});
        _ = try decomp.reader.streamRemaining(&aw.writer);
        return try aw.toOwnedSlice();
    }

    return try allocator.dupe(u8, raw);
}

pub fn writeUserData(io: Io, user_data: []const u8) !void {
    fs.mkdirRecursive(io, constants.dir_et_var_lib, 0o755) catch |err| {
        std.log.err("failed to create {s}: {s}", .{ constants.dir_et_var_lib, @errorName(err) });
        return err;
    };
    const path = constants.dir_et_var_lib ++ "/" ++ constants.file_user_data;
    const file = Io.Dir.createFileAbsolute(io, path, .{}) catch |err| {
        std.log.err("failed to create {s}: {s}", .{ path, @errorName(err) });
        return err;
    };
    defer file.close(io);
    file.writeStreamingAll(io, user_data) catch |err| {
        std.log.err("failed to write {s}: {s}", .{ path, @errorName(err) });
        return err;
    };
}

fn replaceInit(
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
        try system.remountRootReadonly();
    }

    const argv = try concatArgv(allocator, command, args);
    defer allocator.free(argv);

    std.log.info("execve: {s}", .{command[0]});
    return process.replace(allocator, .{
        .argv = argv,
        .env = env orelse &.{},
        .working_dir = working_dir,
        .uid = uid,
        .gid = gid,
    });
}

fn concatArgv(
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

pub fn resolveEnvFrom(
    allocator: Allocator,
    vmspec_alloc: Allocator,
    aws_ctx: *AwsContext,
    vmspec: *VmSpec,
    env_from: []const EnvFromSource,
) !void {
    var env: std.ArrayList(NameValue) = .empty;
    if (vmspec.env) |existing| try env.appendSlice(vmspec_alloc, existing);

    for (env_from) |source| {
        if (source.imds) |imds| {
            const imds_client = aws_ctx.getImds();
            const imds_path = try std.fmt.allocPrint(
                allocator,
                "/latest/meta-data/{s}",
                .{imds.path},
            );
            defer allocator.free(imds_path);

            const value = imds_client.getMetadata(imds_path, .{}) catch |err| {
                if (imds.optional orelse false) {
                    std.log.info("optional IMDS path {s} not found, skipping", .{imds.path});
                    continue;
                }
                std.log.err("failed to fetch IMDS path {s}: {s}", .{ imds.path, @errorName(err) });
                return err;
            };
            defer allocator.free(value);

            const trimmed = std.mem.trim(u8, value, " \t\r\n");
            try upsertEnv(vmspec_alloc, &env, imds.name, trimmed);
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

                const trimmed = std.mem.trim(u8, value, " \t\r\n");
                try upsertEnv(vmspec_alloc, &env, name, trimmed);
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
                    try upsertEnv(vmspec_alloc, &env, entry.key_ptr.*, entry.value_ptr.*);
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
                        std.log.info(
                            "optional SSM parameter {s} not found, skipping",
                            .{ssm.path},
                        );
                        continue;
                    }
                    std.log.err(
                        "failed to fetch SSM parameter {s}: {s}",
                        .{ ssm.path, @errorName(err) },
                    );
                    return err;
                };
                defer allocator.free(value);

                const trimmed = std.mem.trim(u8, value, " \t\r\n");
                try upsertEnv(vmspec_alloc, &env, name, trimmed);
                std.log.info("resolved env {s} from SSM parameter {s}", .{ name, ssm.path });
            } else {
                // JSON map expanded to multiple env vars
                var env_map = ssm_client.getParameterMap(ssm.path) catch |err| {
                    if (ssm.optional orelse false) {
                        std.log.info(
                            "optional SSM parameter {s} not found, skipping",
                            .{ssm.path},
                        );
                        continue;
                    }
                    std.log.err(
                        "failed to fetch SSM parameter map {s}: {s}",
                        .{ ssm.path, @errorName(err) },
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
                    try upsertEnv(vmspec_alloc, &env, entry.key_ptr.*, entry.value_ptr.*);
                    std.log.info(
                        "resolved env {s} from SSM parameter {s}",
                        .{ entry.key_ptr.*, ssm.path },
                    );
                }
            }
        }

        if (source.@"secrets-manager") |sm| {
            const sm_client = try aws_ctx.getSecretsManager();

            if (sm.name) |name| {
                // Single value with explicit name
                const value = sm_client.getSecretValue(sm.@"secret-id") catch |err| {
                    if (sm.optional orelse false) {
                        std.log.info(
                            "optional secret {s} not found, skipping",
                            .{sm.@"secret-id"},
                        );
                        continue;
                    }
                    std.log.err(
                        "failed to fetch secret {s}: {s}",
                        .{ sm.@"secret-id", @errorName(err) },
                    );
                    return err;
                };
                defer allocator.free(value);

                const trimmed = std.mem.trim(u8, value, " \t\r\n");
                try upsertEnv(vmspec_alloc, &env, name, trimmed);
                std.log.info("resolved env {s} from secret {s}", .{ name, sm.@"secret-id" });
            } else {
                // JSON map expanded to multiple env vars
                var env_map = sm_client.getSecretMap(sm.@"secret-id") catch |err| {
                    if (sm.optional orelse false) {
                        std.log.info(
                            "optional secret {s} not found, skipping",
                            .{sm.@"secret-id"},
                        );
                        continue;
                    }
                    std.log.err(
                        "failed to fetch secret map {s}: {s}",
                        .{ sm.@"secret-id", @errorName(err) },
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
                    try upsertEnv(vmspec_alloc, &env, entry.key_ptr.*, entry.value_ptr.*);
                    std.log.info(
                        "resolved env {s} from secret {s}",
                        .{ entry.key_ptr.*, sm.@"secret-id" },
                    );
                }
            }
        }
    }

    vmspec.env = try env.toOwnedSlice(vmspec_alloc);
}

fn upsertEnv(
    arena: Allocator,
    env: *std.ArrayList(NameValue),
    name: []const u8,
    value: []const u8,
) !void {
    for (env.items) |*nv| {
        if (std.mem.eql(u8, nv.name, name)) {
            nv.value = try arena.dupe(u8, value);
            return;
        }
    }
    try env.append(arena, .{
        .name = try arena.dupe(u8, name),
        .value = try arena.dupe(u8, value),
    });
}

pub fn expandEnvValues(
    allocator: Allocator,
    vmspec_alloc: Allocator,
    vmspec: *VmSpec,
    env: ?[]const NameValue,
) !void {
    const env_slice: []const NameValue = env orelse &.{};

    var mapping = std.StringHashMap([]const u8).init(allocator);
    defer mapping.deinit();

    for (env_slice) |nv| {
        try mapping.put(nv.name, nv.value);
    }

    const context = [_]*const std.StringHashMap([]const u8){&mapping};

    // Guarantee PATH is always set in the resulting env: the env is
    // used both to look up argv[0] and as the environment of the
    // spawned process, so a default is appended when none is given.
    const has_path = mapping.contains("PATH");
    const out_len = env_slice.len + @as(usize, if (has_path) 0 else 1);
    var new_env = try vmspec_alloc.alloc(NameValue, out_len);
    for (env_slice, 0..) |nv, i| {
        const expanded_value = try k8s_expand.expand(allocator, nv.value, &context);
        defer allocator.free(expanded_value);

        new_env[i] = NameValue{
            .name = nv.name,
            .value = if (!std.mem.eql(u8, expanded_value, nv.value))
                try vmspec_alloc.dupe(u8, expanded_value)
            else
                nv.value,
        };
    }
    if (!has_path) {
        new_env[env_slice.len] = NameValue{
            .name = try vmspec_alloc.dupe(u8, "PATH"),
            .value = try vmspec_alloc.dupe(u8, constants.env_path),
        };
    }
    vmspec.env = new_env;
}

pub const ExpandedCommand = struct {
    command: []const []const u8,
    args: ?[]const []const u8,

    pub fn deinit(self: ExpandedCommand, allocator: Allocator) void {
        for (self.command) |s| allocator.free(s);
        allocator.free(self.command);
        if (self.args) |args| {
            for (args) |s| allocator.free(s);
            allocator.free(args);
        }
    }
};

pub fn processVolumes(
    allocator: Allocator,
    io: Io,
    aws_ctx: *AwsContext,
    volumes: []const Volume,
    env: []const NameValue,
) !void {
    for (volumes) |volume| {
        if (volume.s3) |s3| {
            try handleS3Volume(io, aws_ctx, &s3);
        }
        if (volume.ssm) |ssm| {
            try handleSsmVolume(io, aws_ctx, &ssm);
        }
        if (volume.@"secrets-manager") |sm| {
            try handleSecretsManagerVolume(io, aws_ctx, &sm);
        }
        if (volume.ebs) |ebs| {
            try handleEbsVolume(io, aws_ctx, &ebs);
        }
        if (volume.template) |t| {
            try handleTemplateVolume(allocator, io, &t, env);
        }
    }
}

fn handleTemplateVolume(
    allocator: Allocator,
    io: Io,
    volume: *const TemplateVolumeSource,
    env: []const NameValue,
) !void {
    const destination = volume.mount.destination;
    const optional = volume.optional orelse false;

    std.log.info("processing template volume -> {s}", .{destination});

    template.renderToFile(allocator, io, volume, env) catch |err| {
        if (optional) {
            std.log.info(
                "optional template volume at {s} failed, skipping: {s}",
                .{ destination, @errorName(err) },
            );
            return;
        }
        std.log.err("failed to render template to {s}: {s}", .{ destination, @errorName(err) });
        return err;
    };

    std.log.info("template volume rendered to {s}", .{destination});
}

fn handleSsmVolume(io: Io, aws_ctx: *AwsContext, volume: *const SsmVolumeSource) !void {
    const path = volume.path;
    const destination = volume.mount.destination;
    const optional = volume.optional orelse false;

    std.log.info("processing SSM volume {s} -> {s}", .{ path, destination });

    const ssm_client = try aws_ctx.getSsm();

    const result = ssm_client.downloadPathToDir(io, path, destination, .{
        .uid = volume.mount.@"user-id",
        .gid = volume.mount.@"group-id",
    }) catch |err| {
        if (optional) {
            std.log.info(
                "optional SSM volume {s} failed, skipping: {s}",
                .{ path, @errorName(err) },
            );
            return;
        }
        std.log.err(
            "failed to download SSM volume {s}: {s}",
            .{ path, @errorName(err) },
        );
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

    std.log.info(
        "SSM volume {s} mounted to {s} ({d} files)",
        .{ path, destination, result.files_written },
    );
}

fn handleS3Volume(io: Io, aws_ctx: *AwsContext, volume: *const S3VolumeSource) !void {
    const bucket = volume.bucket;
    const key_prefix = volume.@"key-prefix";
    const destination = volume.mount.destination;
    const optional = volume.optional orelse false;

    std.log.info("processing S3 volume s3://{s}/{s} -> {s}", .{ bucket, key_prefix, destination });

    const s3_client = try aws_ctx.getS3();

    const result = s3_client.downloadPrefixToDir(io, bucket, key_prefix, destination, .{
        .uid = volume.mount.@"user-id",
        .gid = volume.mount.@"group-id",
    }) catch |err| {
        if (optional) {
            std.log.info(
                "optional S3 volume s3://{s}/{s} failed, skipping: {s}",
                .{ bucket, key_prefix, @errorName(err) },
            );
            return;
        }
        std.log.err(
            "failed to download S3 volume s3://{s}/{s}: {s}",
            .{ bucket, key_prefix, @errorName(err) },
        );
        return err;
    };

    if (result.files_written == 0) {
        if (optional) {
            std.log.info(
                "no objects found in s3://{s}/{s}, skipping (optional)",
                .{ bucket, key_prefix },
            );
            return;
        }
        std.log.err("no S3 objects found at s3://{s}/{s}", .{ bucket, key_prefix });
        return error.S3VolumeEmpty;
    }

    std.log.info(
        "S3 volume s3://{s}/{s} mounted to {s} ({d} files)",
        .{ bucket, key_prefix, destination, result.files_written },
    );
}

fn handleSecretsManagerVolume(
    io: Io,
    aws_ctx: *AwsContext,
    volume: *const SecretsManagerVolumeSource,
) !void {
    const secret_id = volume.@"secret-id";
    const destination = volume.mount.destination;
    const optional = volume.optional orelse false;

    std.log.info("processing Secrets Manager volume {s} -> {s}", .{ secret_id, destination });

    const sm_client = try aws_ctx.getSecretsManager();

    sm_client.downloadSecretToFile(io, secret_id, destination, .{
        .uid = volume.mount.@"user-id",
        .gid = volume.mount.@"group-id",
    }) catch |err| {
        if (optional) {
            std.log.info(
                "optional secret {s} failed, skipping: {s}",
                .{ secret_id, @errorName(err) },
            );
            return;
        }
        std.log.err("failed to download secret {s}: {s}", .{ secret_id, @errorName(err) });
        return err;
    };

    std.log.info("Secrets Manager secret {s} mounted to {s}", .{ secret_id, destination });
}

fn handleEbsVolume(io: Io, aws_ctx: *AwsContext, volume: *const EbsVolumeSource) !void {
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
        if (mnt.@"fs-type" == null or mnt.@"fs-type".?.len == 0) {
            std.log.err("EBS volume mount must have a filesystem type", .{});
            return error.InvalidEbsConfig;
        }
    }

    // Handle volume attachment if specified
    if (volume.attachment) |attachment| {
        const imds_client = aws_ctx.getImds();

        // Get availability zone from IMDS
        const az = imds_client.getMetadata(
            "/latest/meta-data/placement/availability-zone",
            .{},
        ) catch |err| {
            std.log.err("failed to get availability zone from IMDS: {s}", .{@errorName(err)});
            return err;
        };
        defer aws_ctx.allocator.free(az);

        // Get instance ID from IMDS
        const instance_id = imds_client.getMetadata(
            "/latest/meta-data/instance-id",
            .{},
        ) catch |err| {
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
            std.log.err(
                "unable to ensure EBS volume {s} is attached: {s}",
                .{ device, @errorName(err) },
            );
            return err;
        };

        std.log.info("EBS volume {s} is attached", .{device});

        // Wait for device to appear
        const timeout = attachment.timeout orelse 300;
        system.waitForDevice(io, device, timeout) catch |err| {
            std.log.err("timeout waiting for device {s}: {s}", .{ device, @errorName(err) });
            return err;
        };

        std.log.info("EBS volume device {s} is available", .{device});
    }

    // If no mount specified, we're done
    const mnt = volume.mount orelse return;

    const fs_type = mnt.@"fs-type".?;

    system.createFilesystem(io, device, fs_type) catch |err| {
        std.log.err("failed to create filesystem on {s}: {s}", .{ device, @errorName(err) });
        return err;
    };

    // Parse mode if specified
    const mode: posix.mode_t = if (mnt.mode) |mode_str|
        std.fmt.parseInt(u32, mode_str, 8) catch 0o755
    else
        0o755;

    // Create mount point with proper permissions
    fs.mkdirRecursiveOwn(io, mnt.destination, mode, mnt.@"user-id", mnt.@"group-id") catch |err| {
        std.log.err("failed to create mount point {s}: {s}", .{ mnt.destination, @errorName(err) });
        return err;
    };

    // Mount the device
    system.mountDevice(io, device, mnt.destination, fs_type) catch |err| {
        std.log.err(
            "failed to mount {s} on {s}: {s}",
            .{ device, mnt.destination, @errorName(err) },
        );
        return err;
    };

    std.log.info("EBS volume {s} mounted to {s}", .{ device, mnt.destination });
}

pub fn expandCommandAndArgs(
    allocator: Allocator,
    io: Io,
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

    // Resolve argv[0] against PATH when it is not already absolute,
    // since execve (used at the end of init) does not search PATH.
    // PATH is always present in env because expandEnvValues appends
    // a default when none is provided.
    if (expanded_command.len > 0 and
        !std.mem.startsWith(u8, expanded_command[0], constants.dir_root))
    {
        const path_var = mapping.get("PATH").?;
        if (try system.findExecutableInPath(
            allocator,
            io,
            path_var,
            expanded_command[0],
        )) |resolved| {
            allocator.free(expanded_command[0]);
            expanded_command[0] = resolved;
        } else {
            return error.ExecutableNotFoundInPath;
        }
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

test "upsertEnv adds to empty env" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var env: std.ArrayList(NameValue) = .empty;
    try upsertEnv(arena.allocator(), &env, "FOO", "bar");

    try testing.expectEqual(@as(usize, 1), env.items.len);
    try testing.expectEqualStrings("FOO", env.items[0].name);
    try testing.expectEqualStrings("bar", env.items[0].value);
}

test "upsertEnv appends new variable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var env: std.ArrayList(NameValue) = .empty;
    try upsertEnv(arena.allocator(), &env, "FOO", "bar");
    try upsertEnv(arena.allocator(), &env, "BAZ", "qux");

    try testing.expectEqual(@as(usize, 2), env.items.len);
    try testing.expectEqualStrings("FOO", env.items[0].name);
    try testing.expectEqualStrings("BAZ", env.items[1].name);
}

test "upsertEnv replaces existing variable in place" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var env: std.ArrayList(NameValue) = .empty;
    try upsertEnv(arena.allocator(), &env, "FOO", "bar");
    try upsertEnv(arena.allocator(), &env, "FOO", "updated");

    try testing.expectEqual(@as(usize, 1), env.items.len);
    try testing.expectEqualStrings("FOO", env.items[0].name);
    try testing.expectEqualStrings("updated", env.items[0].value);
}

test "expandCommandAndArgs with no env" {
    const allocator = testing.allocator;

    var command = [_][]const u8{ "/bin/echo", "hello" };
    const expanded = try expandCommandAndArgs(allocator, testing.io, &command, null, null);
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
    const expanded = try expandCommandAndArgs(allocator, testing.io, &command, null, &env);
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
    const expanded = try expandCommandAndArgs(allocator, testing.io, &command, &args, &env);
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
    const expanded = try expandCommandAndArgs(allocator, testing.io, &command, null, &env);
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
    const expanded = try expandCommandAndArgs(allocator, testing.io, &command, null, &env);
    defer expanded.deinit(allocator);

    try testing.expectEqualStrings("no variables here", expanded.command[1]);
}

test "ExpandedCommand.deinit frees command" {
    const allocator = testing.allocator;

    var command = [_][]const u8{"/bin/echo"};
    const expanded = try expandCommandAndArgs(allocator, testing.io, &command, null, null);
    expanded.deinit(allocator);
}

test "ExpandedCommand.deinit frees args" {
    const allocator = testing.allocator;

    var command = [_][]const u8{"/bin/sh"};
    var args = [_][]const u8{ "-c", "echo hello" };
    const expanded = try expandCommandAndArgs(allocator, testing.io, &command, &args, null);
    expanded.deinit(allocator);
}

test "expandCommandAndArgs resolves relative command[0] via PATH" {
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

    var env_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_value = try std.fmt.bufPrint(&env_buf, "{s}", .{bin_abs});

    var command = [_][]const u8{"myprog"};
    var env = [_]NameValue{
        .{ .name = "PATH", .value = path_value },
    };
    const expanded = try expandCommandAndArgs(allocator, testing.io, &command, null, &env);
    defer expanded.deinit(allocator);

    var expected_buf: [std.fs.max_path_bytes]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buf, "{s}/myprog", .{bin_abs});
    try testing.expectEqualStrings(expected, expanded.command[0]);
}

test "expandCommandAndArgs leaves absolute command[0] unchanged" {
    const allocator = testing.allocator;

    var command = [_][]const u8{"/some/absolute/path"};
    var env = [_]NameValue{
        .{ .name = "PATH", .value = "/usr/bin:/bin" },
    };
    const expanded = try expandCommandAndArgs(allocator, testing.io, &command, null, &env);
    defer expanded.deinit(allocator);

    try testing.expectEqualStrings("/some/absolute/path", expanded.command[0]);
}
