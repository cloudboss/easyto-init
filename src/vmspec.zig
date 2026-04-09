const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const testing = std.testing;

const yaml = @import("yaml");

const constants = @import("constants.zig");
const container = @import("container.zig");
const Config = container.Config;
const ConfigFile = container.ConfigFile;
const login = @import("login.zig");
const string = @import("string.zig");

const default_command = [_][]const u8{constants.DIR_ET_BIN ++ "/sh"};

/// Merge two NameValue slices. Values from `other` override values in `base` with the same name.
/// Items from `base` that aren't in `other` are kept; all items from `other` are added.
/// Strings are copied to ensure proper ownership.
fn mergeNameValues(allocator: Allocator, base: ?[]const NameValue, other: []const NameValue) ![]NameValue {
    if (other.len == 0) {
        // Nothing to merge, keep base as-is (base items are already owned)
        if (base) |b| {
            return try allocator.dupe(NameValue, b);
        }
        return try allocator.alloc(NameValue, 0);
    }

    const base_slice = base orelse &[_]NameValue{};

    // Count how many base items are not overridden
    var keep_count: usize = 0;
    for (base_slice) |base_nv| {
        var found = false;
        for (other) |other_nv| {
            if (std.mem.eql(u8, base_nv.name, other_nv.name)) {
                found = true;
                break;
            }
        }
        if (!found) keep_count += 1;
    }

    // Allocate result: kept base items + all other items
    var result = try ArrayList(NameValue).initCapacity(allocator, keep_count + other.len);
    errdefer {
        for (result.items) |*nv| nv.deinit(allocator);
        result.deinit(allocator);
    }

    // Add base items that aren't being overridden (these are already owned, just copy pointers)
    for (base_slice) |base_nv| {
        var found = false;
        for (other) |other_nv| {
            if (std.mem.eql(u8, base_nv.name, other_nv.name)) {
                found = true;
                break;
            }
        }
        if (!found) {
            try result.append(allocator, base_nv);
        }
    }

    // Add all items from other (copy strings to transfer ownership)
    for (other) |other_nv| {
        try result.append(allocator, NameValue{
            .name = try allocator.dupe(u8, other_nv.name),
            .value = try allocator.dupe(u8, other_nv.value),
        });
    }

    return try result.toOwnedSlice(allocator);
}

const Error = error{
    InvalidEnvironmentVariable,
    InvalidUserGroup,
    InvalidYaml,
};

const UserGroupNames = struct {
    user: []const u8,
    group: ?[]const u8,

    fn from_string(str: []const u8) !UserGroupNames {
        var fields = std.mem.splitSequence(u8, str, ":");
        const user = fields.next() orelse return Error.InvalidUserGroup;
        return UserGroupNames{ .user = user, .group = fields.next() };
    }
};

pub const VmSpec = struct {
    args: ?[][]const u8 = null,
    command: ?[][]const u8 = null,
    debug: ?bool = false,
    @"disable-services": ?[][]const u8 = null,
    env: ?[]NameValue = null,
    @"env-from": ?[]EnvFromSource = null,
    @"init-scripts": ?[][]const u8 = null,
    modules: ?[][]const u8 = null,
    @"replace-init": ?bool = false,
    security: Security = Security{},
    @"shutdown-grace-period": ?u64 = 10,
    sysctls: ?[]NameValue = null,
    volumes: ?[]Volume = null,
    @"working-dir": ?[]const u8 = "/",

    /// Arena allocator that owns all string allocations in this VmSpec.
    arena: ?std.heap.ArenaAllocator = null,

    fn env_strings_to_name_values(allocator: Allocator, env: []const []const u8) ![]NameValue {
        var name_values = try ArrayList(NameValue).initCapacity(allocator, env.len);
        errdefer {
            for (name_values.items) |*nv| nv.deinit(allocator);
            name_values.deinit(allocator);
        }
        for (env) |e| {
            var iter = std.mem.splitSequence(u8, e, "=");
            const first = iter.next().?;
            // No `=` sign found, first field is the same as the whole string.
            if (std.mem.eql(u8, first, iter.buffer)) return Error.InvalidEnvironmentVariable;
            var name = try ArrayList(u8).initCapacity(allocator, first.len);
            try name.appendSlice(allocator, first);
            const rest = iter.rest();
            var value = try ArrayList(u8).initCapacity(allocator, rest.len);
            try value.appendSlice(allocator, rest);
            try name_values.append(allocator, NameValue{
                .name = try name.toOwnedSlice(allocator),
                .value = try value.toOwnedSlice(allocator),
            });
        }
        return try name_values.toOwnedSlice(allocator);
    }

    pub fn full_command(self: *const VmSpec) []const []const u8 {
        const command_len = if (self.command) |c| c.len else 0;
        const args_len = if (self.args) |a| a.len else 0;

        if (command_len == 0 and args_len == 0) {
            return &default_command;
        }

        if (command_len > 0) {
            return self.command.?;
        }
        return self.args.?;
    }

    pub fn command_args(self: *const VmSpec) ?[]const []const u8 {
        const command_len = if (self.command) |c| c.len else 0;
        if (command_len > 0) {
            return self.args;
        }
        return null;
    }

    pub fn from_config_file(allocator: Allocator, config_file: *const ConfigFile) !VmSpec {
        var vmspec = VmSpec{
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
        errdefer vmspec.deinit();

        const arena_alloc = vmspec.arena.?.allocator();
        const config = config_file.config orelse Config{};

        if (config.Cmd) |cmd| {
            vmspec.args = try dupeStringSlice(arena_alloc, cmd);
        }
        if (config.Entrypoint) |ep| {
            vmspec.command = try dupeStringSlice(arena_alloc, ep);
        }
        if (config.Env) |env| {
            vmspec.env = try VmSpec.env_strings_to_name_values(arena_alloc, env);
        }
        if (config.WorkingDir) |wd| {
            vmspec.@"working-dir" = try arena_alloc.dupe(u8, wd);
        }

        if (config.User != null) {
            const user_group_names = try UserGroupNames.from_string(config.User.?);

            if (std.fmt.parseInt(u32, user_group_names.user, 10)) |uid| {
                vmspec.security.@"run-as-user-id" = uid;
            } else |_| {
                const passwd_contents = try std.fs.cwd().readFileAlloc(
                    allocator,
                    constants.FILE_ETC_PASSWD,
                    1048576,
                );
                defer allocator.free(passwd_contents);
                const uid = try login.user_group_id(passwd_contents, user_group_names.user);
                vmspec.security.@"run-as-user-id" = uid;
            }

            if (user_group_names.group) |group| {
                if (std.fmt.parseInt(u32, group, 10)) |gid| {
                    vmspec.security.@"run-as-group-id" = gid;
                } else |_| {
                    const group_contents = try std.fs.cwd().readFileAlloc(
                        allocator,
                        constants.FILE_ETC_GROUP,
                        1048576,
                    );
                    defer allocator.free(group_contents);
                    const gid = try login.user_group_id(group_contents, group);
                    vmspec.security.@"run-as-group-id" = gid;
                }
            }
        }

        return vmspec;
    }

    fn dupeStringSlice(allocator: Allocator, slice: []const []const u8) ![][]const u8 {
        var result = try allocator.alloc([]const u8, slice.len);
        var i: usize = 0;
        errdefer {
            for (result[0..i]) |s| allocator.free(s);
            allocator.free(result);
        }
        for (slice) |s| {
            result[i] = try allocator.dupe(u8, s);
            i += 1;
        }
        return result;
    }

    pub fn deinit(self: *VmSpec) void {
        if (self.arena) |*arena| {
            arena.deinit();
            self.arena = null;
        }
    }

    pub const ParsedYaml = yaml.Parsed(VmSpec);

    /// Parse user data from YAML string.
    /// Returns null if the content is empty.
    /// Caller must call .deinit() on the returned ParsedYaml when done.
    pub fn from_yaml(allocator: Allocator, content: []const u8) !?ParsedYaml {
        const trimmed = std.mem.trim(u8, content, " \t\r\n");
        if (trimmed.len == 0) {
            return null;
        }

        return yaml.parseFromSlice(VmSpec, allocator, content, .{}) catch |err| {
            std.log.err("failed to parse user data YAML: {s}", .{@errorName(err)});
            return error.InvalidYaml;
        };
    }

    fn dupeVolumes(allocator: Allocator, volumes: []const Volume) ![]Volume {
        var result = try allocator.alloc(Volume, volumes.len);
        for (volumes, 0..) |vol, i| {
            result[i] = try dupeVolume(allocator, vol);
        }
        return result;
    }

    fn dupeVolume(allocator: Allocator, vol: Volume) !Volume {
        return Volume{
            .s3 = if (vol.s3) |s3| try dupeS3VolumeSource(allocator, s3) else null,
            .ssm = if (vol.ssm) |ssm| try dupeSsmVolumeSource(allocator, ssm) else null,
            .@"secrets-manager" = if (vol.@"secrets-manager") |sm|
                try dupeSecretsManagerVolumeSource(allocator, sm)
            else
                null,
            .ebs = if (vol.ebs) |ebs| try dupeEbsVolumeSource(allocator, ebs) else null,
        };
    }

    fn dupeS3VolumeSource(allocator: Allocator, src: S3VolumeSource) !S3VolumeSource {
        return S3VolumeSource{
            .bucket = try allocator.dupe(u8, src.bucket),
            .@"key-prefix" = try allocator.dupe(u8, src.@"key-prefix"),
            .optional = src.optional,
            .mount = try dupeMount(allocator, src.mount),
        };
    }

    fn dupeSsmVolumeSource(allocator: Allocator, src: SsmVolumeSource) !SsmVolumeSource {
        return SsmVolumeSource{
            .path = try allocator.dupe(u8, src.path),
            .optional = src.optional,
            .mount = try dupeMount(allocator, src.mount),
        };
    }

    fn dupeSecretsManagerVolumeSource(allocator: Allocator, src: SecretsManagerVolumeSource) !SecretsManagerVolumeSource {
        return SecretsManagerVolumeSource{
            .@"secret-id" = try allocator.dupe(u8, src.@"secret-id"),
            .optional = src.optional,
            .mount = try dupeMount(allocator, src.mount),
        };
    }

    fn dupeEbsVolumeSource(allocator: Allocator, src: EbsVolumeSource) !EbsVolumeSource {
        return EbsVolumeSource{
            .attachment = if (src.attachment) |att| try dupeEbsVolumeAttachment(allocator, att) else null,
            .device = try allocator.dupe(u8, src.device),
            .mount = if (src.mount) |m| try dupeMount(allocator, m) else null,
        };
    }

    fn dupeEbsVolumeAttachment(allocator: Allocator, src: EbsVolumeAttachment) !EbsVolumeAttachment {
        var tags = try allocator.alloc(AwsTag, src.tags.len);
        for (src.tags, 0..) |tag, i| {
            tags[i] = AwsTag{
                .key = try allocator.dupe(u8, tag.key),
                .value = if (tag.value) |v| try allocator.dupe(u8, v) else null,
            };
        }
        return EbsVolumeAttachment{
            .tags = tags,
            .timeout = src.timeout,
        };
    }

    fn dupeMount(allocator: Allocator, src: Mount) !Mount {
        return Mount{
            .destination = try allocator.dupe(u8, src.destination),
            .@"fs-type" = if (src.@"fs-type") |f| try allocator.dupe(u8, f) else null,
            .@"user-id" = src.@"user-id",
            .@"group-id" = src.@"group-id",
            .mode = if (src.mode) |m| try allocator.dupe(u8, m) else null,
            .options = if (src.options) |opts| try dupeStringSlice(allocator, opts) else null,
        };
    }

    fn dupeEnvFromSources(allocator: Allocator, sources: []const EnvFromSource) ![]EnvFromSource {
        var result = try allocator.alloc(EnvFromSource, sources.len);
        for (sources, 0..) |src, i| {
            result[i] = try dupeEnvFromSource(allocator, src);
        }
        return result;
    }

    fn dupeEnvFromSource(allocator: Allocator, src: EnvFromSource) !EnvFromSource {
        return EnvFromSource{
            .imds = if (src.imds) |imds| try dupeImdsEnvSource(allocator, imds) else null,
            .s3 = if (src.s3) |s3| try dupeS3EnvSource(allocator, s3) else null,
            .@"secrets-manager" = if (src.@"secrets-manager") |sm|
                try dupeSecretsManagerEnvSource(allocator, sm)
            else
                null,
            .ssm = if (src.ssm) |ssm| try dupeSsmEnvSource(allocator, ssm) else null,
        };
    }

    fn dupeImdsEnvSource(allocator: Allocator, src: ImdsEnvSource) !ImdsEnvSource {
        return ImdsEnvSource{
            .name = try allocator.dupe(u8, src.name),
            .path = try allocator.dupe(u8, src.path),
            .optional = src.optional,
        };
    }

    fn dupeS3EnvSource(allocator: Allocator, src: S3EnvSource) !S3EnvSource {
        return S3EnvSource{
            .bucket = try allocator.dupe(u8, src.bucket),
            .key = try allocator.dupe(u8, src.key),
            .name = if (src.name) |n| try allocator.dupe(u8, n) else null,
            .optional = src.optional,
            .@"base64-encode" = src.@"base64-encode",
        };
    }

    fn dupeSecretsManagerEnvSource(allocator: Allocator, src: SecretsManagerEnvSource) !SecretsManagerEnvSource {
        return SecretsManagerEnvSource{
            .name = if (src.name) |n| try allocator.dupe(u8, n) else null,
            .@"secret-id" = try allocator.dupe(u8, src.@"secret-id"),
            .optional = src.optional,
            .@"base64-encode" = src.@"base64-encode",
        };
    }

    fn dupeSsmEnvSource(allocator: Allocator, src: SsmEnvSource) !SsmEnvSource {
        return SsmEnvSource{
            .path = try allocator.dupe(u8, src.path),
            .name = if (src.name) |n| try allocator.dupe(u8, n) else null,
            .optional = src.optional,
            .@"base64-encode" = src.@"base64-encode",
        };
    }

    /// Merge user data into this VmSpec.
    /// Fields from `other` override fields in `self` when present.
    /// Strings are duped into self's arena.
    pub fn merge(self: *VmSpec, other: VmSpec) !void {
        const arena_alloc = self.arena.?.allocator();

        if (other.args) |args| {
            self.args = try dupeStringSlice(arena_alloc, args);
        }
        if (other.command) |command| {
            self.command = try dupeStringSlice(arena_alloc, command);
            if (other.args == null) {
                self.args = null;
            }
        }
        if (other.debug != null and other.debug.?) {
            self.debug = other.debug;
        }
        if (other.@"disable-services") |ds| {
            self.@"disable-services" = try dupeStringSlice(arena_alloc, ds);
        }
        if (other.env) |env| {
            self.env = try mergeNameValues(arena_alloc, self.env, env);
        }
        if (other.@"env-from") |env_from| {
            self.@"env-from" = try dupeEnvFromSources(arena_alloc, env_from);
        }
        if (other.@"init-scripts") |scripts| {
            self.@"init-scripts" = try dupeStringSlice(arena_alloc, scripts);
        }
        if (other.modules) |modules| {
            self.modules = try dupeStringSlice(arena_alloc, modules);
        }
        if (other.@"replace-init" != null and other.@"replace-init".?) {
            self.@"replace-init" = other.@"replace-init";
        }
        self.security.merge(other.security);
        if (other.@"shutdown-grace-period" != null) {
            self.@"shutdown-grace-period" = other.@"shutdown-grace-period";
        }
        if (other.sysctls) |sysctls| {
            self.sysctls = try mergeNameValues(arena_alloc, self.sysctls, sysctls);
        }
        if (other.volumes) |volumes| {
            self.volumes = try dupeVolumes(arena_alloc, volumes);
        }
        if (other.@"working-dir") |wd| {
            self.@"working-dir" = try arena_alloc.dupe(u8, wd);
        }
    }
};

pub const NameValue = struct {
    name: []const u8,
    value: []const u8,

    pub fn deinit(self: *NameValue, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.value);
    }
};

pub const EnvFromSource = struct {
    imds: ?ImdsEnvSource = null,
    s3: ?S3EnvSource = null,
    @"secrets-manager": ?SecretsManagerEnvSource = null,
    ssm: ?SsmEnvSource = null,
};

pub const ImdsEnvSource = struct {
    name: []const u8,
    optional: ?bool = null,
    path: []const u8,
};

pub const S3EnvSource = struct {
    @"base64-encode": ?bool = null,
    bucket: []const u8,
    key: []const u8,
    name: ?[]const u8 = null,
    optional: ?bool = null,
};

pub const SecretsManagerEnvSource = struct {
    @"base64-encode": ?bool = null,
    name: ?[]const u8 = null,
    optional: ?bool = null,
    @"secret-id": []const u8,
};

pub const SsmEnvSource = struct {
    @"base64-encode": ?bool = null,
    name: ?[]const u8 = null,
    path: []const u8,
    optional: ?bool = null,
};

pub const Security = struct {
    @"readonly-root-fs": ?bool = null,
    @"run-as-group-id": ?u32 = null,
    @"run-as-user-id": ?u32 = null,
    sshd: Sshd = Sshd{},

    pub fn merge(self: *Security, other: Security) void {
        if (other.@"readonly-root-fs" != null) {
            self.@"readonly-root-fs" = other.@"readonly-root-fs";
        }
        if (other.@"run-as-group-id" != null) {
            self.@"run-as-group-id" = other.@"run-as-group-id";
        }
        if (other.@"run-as-user-id" != null) {
            self.@"run-as-user-id" = other.@"run-as-user-id";
        }
        if (other.sshd.enable != null) {
            self.sshd = other.sshd;
        }
    }
};

pub const Sshd = struct {
    enable: ?bool = null,
};

pub const Volume = struct {
    ebs: ?EbsVolumeSource = null,
    s3: ?S3VolumeSource = null,
    @"secrets-manager": ?SecretsManagerVolumeSource = null,
    ssm: ?SsmVolumeSource = null,
};

pub const EbsVolumeSource = struct {
    attachment: ?EbsVolumeAttachment = null,
    device: []const u8,
    mount: ?Mount = null,
};

pub const EbsVolumeAttachment = struct {
    tags: []AwsTag = &[_]AwsTag{},
    timeout: ?u64 = null,
};

pub const AwsTag = struct {
    key: []const u8,
    value: ?[]const u8 = null,
};

pub const S3VolumeSource = struct {
    bucket: []const u8,
    @"key-prefix": []const u8,
    optional: ?bool = null,
    mount: Mount,
};

pub const SecretsManagerVolumeSource = struct {
    @"secret-id": []const u8,
    mount: Mount,
    optional: ?bool = null,
};

pub const SsmVolumeSource = struct {
    path: []const u8,
    mount: Mount,
    optional: ?bool = null,
};

pub const Mount = struct {
    destination: []const u8,
    @"fs-type": ?[]const u8 = null,
    @"group-id": ?u32 = null,
    mode: ?[]const u8 = null,
    options: ?[][]const u8 = null,
    @"user-id": ?u32 = null,
};

test "VmSpec.env_strings_to_name_values error" {
    const env_strings = [_][]const u8{"invalid environment variable"};
    const actual = VmSpec.env_strings_to_name_values(
        testing.allocator,
        &env_strings,
    );
    try testing.expectError(Error.InvalidEnvironmentVariable, actual);
}

test "VmSpec.env_strings_to_name_values empty" {
    const env_strings = [_][]const u8{};
    const expected = [_]NameValue{};
    const actual = try VmSpec.env_strings_to_name_values(
        testing.allocator,
        &env_strings,
    );
    try testing.expect(actual.len == 0);
    try testing.expectEqualDeep(&expected, actual);
}

test "VmSpec.env_strings_to_name_values single" {
    const env_strings = [_][]const u8{"PATH=/bin:/usr/bin"};
    const expected = [_]NameValue{
        .{
            .name = "PATH",
            .value = "/bin:/usr/bin",
        },
    };
    const actual = try VmSpec.env_strings_to_name_values(
        testing.allocator,
        &env_strings,
    );
    defer {
        for (actual) |*nv| nv.deinit(testing.allocator);
        testing.allocator.free(actual);
    }
    try testing.expectEqualDeep(&expected, actual);
}

test "VmSpec.env_strings_to_name_values multiple" {
    const env_strings = [_][]const u8{
        "PATH=/bin:/usr/bin",
        "HOME=/app",
        "SHELL=/bin/sh",
    };
    const expected = [_]NameValue{
        .{
            .name = "PATH",
            .value = "/bin:/usr/bin",
        },
        .{
            .name = "HOME",
            .value = "/app",
        },
        .{
            .name = "SHELL",
            .value = "/bin/sh",
        },
    };
    const actual = try VmSpec.env_strings_to_name_values(
        testing.allocator,
        &env_strings,
    );
    defer {
        for (actual) |*nv| nv.deinit(testing.allocator);
        testing.allocator.free(actual);
    }
    try testing.expectEqualDeep(&expected, actual);
}

test "VmSpec.env_strings_to_name_values multiple error" {
    const env_strings = [_][]const u8{
        "PATH=/bin:/usr/bin",
        "HOME=/app",
        "SHELL=/bin/sh",
        "SHELL/bin/sh",
    };
    const actual = VmSpec.env_strings_to_name_values(
        testing.allocator,
        &env_strings,
    );
    try testing.expectError(Error.InvalidEnvironmentVariable, actual);
}

test "VmSpec.full_command with both empty" {
    const vmspec = VmSpec{};
    const cmd = vmspec.full_command();
    try testing.expectEqual(@as(usize, 1), cmd.len);
    try testing.expectEqualStrings("/.easyto/bin/sh", cmd[0]);
}

test "VmSpec.full_command with command only" {
    var command_arr = [_][]const u8{ "/bin/echo", "hello" };
    const vmspec = VmSpec{
        .command = &command_arr,
    };
    const cmd = vmspec.full_command();
    try testing.expectEqual(@as(usize, 2), cmd.len);
    try testing.expectEqualStrings("/bin/echo", cmd[0]);
    try testing.expectEqualStrings("hello", cmd[1]);
}

test "VmSpec.full_command with args only" {
    var args_arr = [_][]const u8{ "/bin/sh", "-c", "echo test" };
    const vmspec = VmSpec{
        .args = &args_arr,
    };
    const cmd = vmspec.full_command();
    try testing.expectEqual(@as(usize, 3), cmd.len);
    try testing.expectEqualStrings("/bin/sh", cmd[0]);
}

test "VmSpec.full_command with command and args" {
    var command_arr = [_][]const u8{"/bin/echo"};
    var args_arr = [_][]const u8{ "hello", "world" };
    const vmspec = VmSpec{
        .command = &command_arr,
        .args = &args_arr,
    };
    const cmd = vmspec.full_command();
    try testing.expectEqual(@as(usize, 1), cmd.len);
    try testing.expectEqualStrings("/bin/echo", cmd[0]);
    const cmd_args = vmspec.command_args();
    try testing.expect(cmd_args != null);
    try testing.expectEqual(@as(usize, 2), cmd_args.?.len);
}

test "VmSpec.command_args returns null when command is null" {
    const vmspec = VmSpec{};
    try testing.expect(vmspec.command_args() == null);
}

test "VmSpec.command_args returns null when command is empty" {
    var empty_command = [_][]const u8{};
    const vmspec = VmSpec{
        .command = &empty_command,
    };
    try testing.expect(vmspec.command_args() == null);
}

test "UserGroupNames.from_string user only" {
    const ug = try UserGroupNames.from_string("postgres");
    try testing.expectEqualStrings("postgres", ug.user);
    try testing.expect(ug.group == null);
}

test "UserGroupNames.from_string user and group" {
    const ug = try UserGroupNames.from_string("postgres:postgres");
    try testing.expectEqualStrings("postgres", ug.user);
    try testing.expectEqualStrings("postgres", ug.group.?);
}

test "UserGroupNames.from_string user and different group" {
    const ug = try UserGroupNames.from_string("www-data:nginx");
    try testing.expectEqualStrings("www-data", ug.user);
    try testing.expectEqualStrings("nginx", ug.group.?);
}

test "UserGroupNames.from_string numeric user" {
    const ug = try UserGroupNames.from_string("1000:1000");
    try testing.expectEqualStrings("1000", ug.user);
    try testing.expectEqualStrings("1000", ug.group.?);
}

test "mergeNameValues empty other with null base" {
    const allocator = testing.allocator;
    const other = [_]NameValue{};
    const result = try mergeNameValues(allocator, null, &other);
    defer allocator.free(result);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "mergeNameValues empty other with populated base" {
    const allocator = testing.allocator;
    // Note: base items are not owned by the function, so we use static strings
    const base = [_]NameValue{
        .{ .name = "PATH", .value = "/bin" },
        .{ .name = "HOME", .value = "/root" },
    };
    const other = [_]NameValue{};
    const result = try mergeNameValues(allocator, &base, &other);
    // When other is empty, function shallow-copies base (pointers only), so don't free strings
    defer allocator.free(result);
    try testing.expectEqual(@as(usize, 2), result.len);
    try testing.expectEqualStrings("PATH", result[0].name);
    try testing.expectEqualStrings("HOME", result[1].name);
}

test "mergeNameValues populated other with null base" {
    const allocator = testing.allocator;
    const other = [_]NameValue{
        .{ .name = "FOO", .value = "bar" },
    };
    const result = try mergeNameValues(allocator, null, &other);
    defer {
        for (result) |*nv| {
            var nv_mut = nv.*;
            nv_mut.deinit(allocator);
        }
        allocator.free(result);
    }
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("FOO", result[0].name);
    try testing.expectEqualStrings("bar", result[0].value);
}

test "mergeNameValues override same name" {
    const allocator = testing.allocator;
    const base = [_]NameValue{
        .{ .name = "PATH", .value = "/bin" },
    };
    const other = [_]NameValue{
        .{ .name = "PATH", .value = "/usr/bin" },
    };
    const result = try mergeNameValues(allocator, &base, &other);
    defer {
        for (result) |*nv| {
            var nv_mut = nv.*;
            nv_mut.deinit(allocator);
        }
        allocator.free(result);
    }
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("PATH", result[0].name);
    try testing.expectEqualStrings("/usr/bin", result[0].value);
}

test "mergeNameValues non-overlapping merge" {
    const allocator = testing.allocator;
    // Base items are borrowed (not duped), other items are duped
    const base = [_]NameValue{
        .{ .name = "PATH", .value = "/bin" },
    };
    const other = [_]NameValue{
        .{ .name = "HOME", .value = "/root" },
    };
    const result = try mergeNameValues(allocator, &base, &other);
    defer {
        // Only free items that came from other (they were duped)
        // Base items are shallow-copied pointers, don't free those
        // In this case, result[0] is from base (shallow copy), result[1] is from other (duped)
        allocator.free(result[1].name);
        allocator.free(result[1].value);
        allocator.free(result);
    }
    try testing.expectEqual(@as(usize, 2), result.len);
    // Base items kept come first
    try testing.expectEqualStrings("PATH", result[0].name);
    // Other items come second
    try testing.expectEqualStrings("HOME", result[1].name);
}

test "Security.merge with empty other" {
    var security = Security{
        .@"run-as-user-id" = 1000,
        .@"run-as-group-id" = 1000,
    };
    const other = Security{};
    security.merge(other);
    try testing.expectEqual(@as(?u32, 1000), security.@"run-as-user-id");
    try testing.expectEqual(@as(?u32, 1000), security.@"run-as-group-id");
}

test "Security.merge overrides individual fields" {
    var security = Security{
        .@"run-as-user-id" = 1000,
        .@"run-as-group-id" = 1000,
    };
    const other = Security{
        .@"run-as-user-id" = 0,
    };
    security.merge(other);
    try testing.expectEqual(@as(?u32, 0), security.@"run-as-user-id");
    try testing.expectEqual(@as(?u32, 1000), security.@"run-as-group-id");
}

test "Security.merge overrides all fields" {
    var security = Security{};
    const other = Security{
        .@"run-as-user-id" = 1000,
        .@"run-as-group-id" = 1000,
        .@"readonly-root-fs" = true,
        .sshd = Sshd{ .enable = true },
    };
    security.merge(other);
    try testing.expectEqual(@as(?u32, 1000), security.@"run-as-user-id");
    try testing.expectEqual(@as(?u32, 1000), security.@"run-as-group-id");
    try testing.expectEqual(@as(?bool, true), security.@"readonly-root-fs");
    try testing.expectEqual(@as(?bool, true), security.sshd.enable);
}

test "VmSpec.from_yaml returns null for empty input" {
    const result = try VmSpec.from_yaml(testing.allocator, "");
    try testing.expect(result == null);
}

test "VmSpec.from_yaml returns null for whitespace-only input" {
    const result = try VmSpec.from_yaml(testing.allocator, "   \n\t\r\n  ");
    try testing.expect(result == null);
}

test "VmSpec.from_yaml parses command" {
    const yaml_content =
        \\command:
        \\  - /bin/echo
        \\  - hello
    ;
    const parsed = (try VmSpec.from_yaml(testing.allocator, yaml_content)).?;
    defer parsed.deinit();
    const vmspec = parsed.value;

    try testing.expect(vmspec.command != null);
    try testing.expectEqual(@as(usize, 2), vmspec.command.?.len);
    try testing.expectEqualStrings("/bin/echo", vmspec.command.?[0]);
    try testing.expectEqualStrings("hello", vmspec.command.?[1]);
}

test "VmSpec.from_yaml parses env" {
    const yaml_content =
        \\env:
        \\  - name: FOO
        \\    value: bar
        \\  - name: BAZ
        \\    value: qux
    ;
    const parsed = (try VmSpec.from_yaml(testing.allocator, yaml_content)).?;
    defer parsed.deinit();
    const vmspec = parsed.value;

    try testing.expect(vmspec.env != null);
    try testing.expectEqual(@as(usize, 2), vmspec.env.?.len);
    try testing.expectEqualStrings("FOO", vmspec.env.?[0].name);
    try testing.expectEqualStrings("bar", vmspec.env.?[0].value);
}

test "VmSpec.from_yaml parses security" {
    const yaml_content =
        \\security:
        \\  run-as-user-id: 1000
        \\  run-as-group-id: 1000
        \\  readonly-root-fs: true
    ;
    const parsed = (try VmSpec.from_yaml(testing.allocator, yaml_content)).?;
    defer parsed.deinit();
    const vmspec = parsed.value;

    try testing.expectEqual(@as(?u32, 1000), vmspec.security.@"run-as-user-id");
    try testing.expectEqual(@as(?u32, 1000), vmspec.security.@"run-as-group-id");
    try testing.expectEqual(@as(?bool, true), vmspec.security.@"readonly-root-fs");
}

test "VmSpec.from_yaml parses debug flag" {
    const yaml_content = "debug: true";
    const parsed = (try VmSpec.from_yaml(testing.allocator, yaml_content)).?;
    defer parsed.deinit();
    const vmspec = parsed.value;

    try testing.expectEqual(@as(?bool, true), vmspec.debug);
}

test "VmSpec.from_yaml parses replace-init flag" {
    const yaml_content = "replace-init: true";
    const parsed = (try VmSpec.from_yaml(testing.allocator, yaml_content)).?;
    defer parsed.deinit();
    const vmspec = parsed.value;

    try testing.expectEqual(@as(?bool, true), vmspec.@"replace-init");
}

test "VmSpec.from_yaml parses working-dir" {
    const yaml_content = "working-dir: /app";
    const parsed = (try VmSpec.from_yaml(testing.allocator, yaml_content)).?;
    defer parsed.deinit();
    const vmspec = parsed.value;

    try testing.expectEqualStrings("/app", vmspec.@"working-dir".?);
}

test "VmSpec.from_yaml treats null working-dir as null" {
    const yaml_content = "working-dir: null";
    const parsed = (try VmSpec.from_yaml(testing.allocator, yaml_content)).?;
    defer parsed.deinit();
    const vmspec = parsed.value;

    // YAML null sets the optional to null; merge will skip it
    try testing.expect(vmspec.@"working-dir" == null);
}

test "VmSpec.from_yaml parses shutdown-grace-period" {
    const yaml_content = "shutdown-grace-period: 30";
    const parsed = (try VmSpec.from_yaml(testing.allocator, yaml_content)).?;
    defer parsed.deinit();
    const vmspec = parsed.value;

    try testing.expectEqual(@as(?u64, 30), vmspec.@"shutdown-grace-period");
}

test "VmSpec.from_yaml parses modules" {
    const yaml_content =
        \\modules:
        \\  - nvme
        \\  - xfs
    ;
    const parsed = (try VmSpec.from_yaml(testing.allocator, yaml_content)).?;
    defer parsed.deinit();
    const vmspec = parsed.value;

    try testing.expect(vmspec.modules != null);
    try testing.expectEqual(@as(usize, 2), vmspec.modules.?.len);
    try testing.expectEqualStrings("nvme", vmspec.modules.?[0]);
    try testing.expectEqualStrings("xfs", vmspec.modules.?[1]);
}

test "VmSpec.from_yaml parses sysctls" {
    const yaml_content =
        \\sysctls:
        \\  - name: net.ipv4.ip_forward
        \\    value: 1
    ;
    const parsed = (try VmSpec.from_yaml(testing.allocator, yaml_content)).?;
    defer parsed.deinit();
    const vmspec = parsed.value;

    try testing.expect(vmspec.sysctls != null);
    try testing.expectEqual(@as(usize, 1), vmspec.sysctls.?.len);
    try testing.expectEqualStrings("net.ipv4.ip_forward", vmspec.sysctls.?[0].name);
    try testing.expectEqualStrings("1", vmspec.sysctls.?[0].value);
}

test "VmSpec.from_yaml parses init-scripts" {
    const yaml_content =
        \\init-scripts:
        \\  - /etc/init.d/script1
        \\  - /etc/init.d/script2
    ;
    const parsed = (try VmSpec.from_yaml(testing.allocator, yaml_content)).?;
    defer parsed.deinit();
    const vmspec = parsed.value;

    try testing.expect(vmspec.@"init-scripts" != null);
    try testing.expectEqual(@as(usize, 2), vmspec.@"init-scripts".?.len);
    try testing.expectEqualStrings("/etc/init.d/script1", vmspec.@"init-scripts".?[0]);
}

test "VmSpec.from_yaml parses disable-services" {
    const yaml_content =
        \\disable-services:
        \\  - sshd
        \\  - network
    ;
    const parsed = (try VmSpec.from_yaml(testing.allocator, yaml_content)).?;
    defer parsed.deinit();
    const vmspec = parsed.value;

    try testing.expect(vmspec.@"disable-services" != null);
    try testing.expectEqual(@as(usize, 2), vmspec.@"disable-services".?.len);
    try testing.expectEqualStrings("sshd", vmspec.@"disable-services".?[0]);
}

test "VmSpec.from_yaml parses env-from with imds" {
    const yaml_content =
        \\env-from:
        \\  - imds:
        \\      name: INSTANCE_ID
        \\      path: /latest/meta-data/instance-id
        \\      optional: true
    ;
    const parsed = (try VmSpec.from_yaml(testing.allocator, yaml_content)).?;
    defer parsed.deinit();
    const vmspec = parsed.value;

    try testing.expect(vmspec.@"env-from" != null);
    try testing.expectEqual(@as(usize, 1), vmspec.@"env-from".?.len);
    const imds = vmspec.@"env-from".?[0].imds.?;
    try testing.expectEqualStrings("INSTANCE_ID", imds.name);
    try testing.expectEqualStrings("/latest/meta-data/instance-id", imds.path);
    try testing.expectEqual(@as(?bool, true), imds.optional);
}

test "VmSpec.from_yaml parses env-from with s3" {
    const yaml_content =
        \\env-from:
        \\  - s3:
        \\      bucket: my-bucket
        \\      key: config/env.json
        \\      name: S3_CONFIG
    ;
    const parsed = (try VmSpec.from_yaml(testing.allocator, yaml_content)).?;
    defer parsed.deinit();
    const vmspec = parsed.value;

    try testing.expect(vmspec.@"env-from" != null);
    const s3 = vmspec.@"env-from".?[0].s3.?;
    try testing.expectEqualStrings("my-bucket", s3.bucket);
    try testing.expectEqualStrings("config/env.json", s3.key);
    try testing.expectEqualStrings("S3_CONFIG", s3.name.?);
}

test "VmSpec.from_yaml parses env-from with secrets-manager" {
    const yaml_content =
        \\env-from:
        \\  - secrets-manager:
        \\      name: DB_PASSWORD
        \\      secret-id: prod/db/password
    ;
    const parsed = (try VmSpec.from_yaml(testing.allocator, yaml_content)).?;
    defer parsed.deinit();
    const vmspec = parsed.value;

    try testing.expect(vmspec.@"env-from" != null);
    const sm = vmspec.@"env-from".?[0].@"secrets-manager".?;
    try testing.expect(sm.name != null);
    try testing.expectEqualStrings("DB_PASSWORD", sm.name.?);
    try testing.expectEqualStrings("prod/db/password", sm.@"secret-id");
}

test "VmSpec.from_yaml parses env-from with ssm" {
    const yaml_content =
        \\env-from:
        \\  - ssm:
        \\      path: /prod/config/api-key
        \\      name: API_KEY
        \\      base64-encode: true
    ;
    const parsed = (try VmSpec.from_yaml(testing.allocator, yaml_content)).?;
    defer parsed.deinit();
    const vmspec = parsed.value;

    try testing.expect(vmspec.@"env-from" != null);
    const ssm = vmspec.@"env-from".?[0].ssm.?;
    try testing.expectEqualStrings("/prod/config/api-key", ssm.path);
    try testing.expectEqualStrings("API_KEY", ssm.name.?);
    try testing.expectEqual(@as(?bool, true), ssm.@"base64-encode");
}

test "VmSpec.merge empty other into populated self" {
    var base_command = [_][]const u8{"/bin/echo"};
    var vmspec = VmSpec{
        .command = &base_command,
        .debug = true,
        .arena = std.heap.ArenaAllocator.init(testing.allocator),
    };
    defer vmspec.deinit();

    const other = VmSpec{};
    try vmspec.merge(other);

    // Original values preserved
    try testing.expectEqualStrings("/bin/echo", vmspec.command.?[0]);
    try testing.expectEqual(@as(?bool, true), vmspec.debug);
}

test "VmSpec.merge overrides command and clears args" {
    var base_command = [_][]const u8{"/bin/sh"};
    var base_args = [_][]const u8{ "-c", "echo hello" };
    var vmspec = VmSpec{
        .command = &base_command,
        .args = &base_args,
        .arena = std.heap.ArenaAllocator.init(testing.allocator),
    };
    defer vmspec.deinit();

    var other_command = [_][]const u8{"/bin/bash"};
    const other = VmSpec{
        .command = &other_command,
    };
    try vmspec.merge(other);

    try testing.expectEqualStrings("/bin/bash", vmspec.command.?[0]);
    try testing.expect(vmspec.args == null);
}

test "VmSpec.merge preserves args when other provides args" {
    var base_command = [_][]const u8{"/bin/sh"};
    var vmspec = VmSpec{
        .command = &base_command,
        .arena = std.heap.ArenaAllocator.init(testing.allocator),
    };
    defer vmspec.deinit();

    var other_command = [_][]const u8{"/bin/bash"};
    var other_args = [_][]const u8{ "-c", "echo test" };
    const other = VmSpec{
        .command = &other_command,
        .args = &other_args,
    };
    try vmspec.merge(other);

    try testing.expectEqualStrings("/bin/bash", vmspec.command.?[0]);
    try testing.expect(vmspec.args != null);
    try testing.expectEqualStrings("-c", vmspec.args.?[0]);
}

test "VmSpec.merge env combines and overrides" {
    var vmspec = VmSpec{
        .arena = std.heap.ArenaAllocator.init(testing.allocator),
    };
    defer vmspec.deinit();

    const arena_alloc = vmspec.arena.?.allocator();
    var base_env = try ArrayList(NameValue).initCapacity(arena_alloc, 2);
    try base_env.append(arena_alloc, .{
        .name = try arena_alloc.dupe(u8, "PATH"),
        .value = try arena_alloc.dupe(u8, "/bin"),
    });
    try base_env.append(arena_alloc, .{
        .name = try arena_alloc.dupe(u8, "HOME"),
        .value = try arena_alloc.dupe(u8, "/root"),
    });
    vmspec.env = try base_env.toOwnedSlice(arena_alloc);

    var other_env = [_]NameValue{
        .{ .name = "PATH", .value = "/usr/bin" },
        .{ .name = "SHELL", .value = "/bin/bash" },
    };
    const other = VmSpec{
        .env = &other_env,
    };
    try vmspec.merge(other);

    // Should have 3 items: HOME from base (not overridden), PATH and SHELL from other
    try testing.expectEqual(@as(usize, 3), vmspec.env.?.len);

    // Find each expected value
    var found_home = false;
    var found_path = false;
    var found_shell = false;
    for (vmspec.env.?) |nv| {
        if (std.mem.eql(u8, nv.name, "HOME")) {
            try testing.expectEqualStrings("/root", nv.value);
            found_home = true;
        } else if (std.mem.eql(u8, nv.name, "PATH")) {
            try testing.expectEqualStrings("/usr/bin", nv.value);
            found_path = true;
        } else if (std.mem.eql(u8, nv.name, "SHELL")) {
            try testing.expectEqualStrings("/bin/bash", nv.value);
            found_shell = true;
        }
    }
    try testing.expect(found_home);
    try testing.expect(found_path);
    try testing.expect(found_shell);
}

test "VmSpec.merge security" {
    var vmspec = VmSpec{
        .security = Security{
            .@"run-as-user-id" = 1000,
        },
        .arena = std.heap.ArenaAllocator.init(testing.allocator),
    };
    defer vmspec.deinit();

    const other = VmSpec{
        .security = Security{
            .@"run-as-group-id" = 1000,
            .@"readonly-root-fs" = true,
        },
    };
    try vmspec.merge(other);

    try testing.expectEqual(@as(?u32, 1000), vmspec.security.@"run-as-user-id");
    try testing.expectEqual(@as(?u32, 1000), vmspec.security.@"run-as-group-id");
    try testing.expectEqual(@as(?bool, true), vmspec.security.@"readonly-root-fs");
}

test "VmSpec.merge working-dir" {
    var vmspec = VmSpec{
        .@"working-dir" = "/",
        .arena = std.heap.ArenaAllocator.init(testing.allocator),
    };
    defer vmspec.deinit();

    const other = VmSpec{
        .@"working-dir" = "/app",
    };
    try vmspec.merge(other);

    try testing.expectEqualStrings("/app", vmspec.@"working-dir".?);
}

test "VmSpec.from_yaml parses both env and env-from" {
    const yaml_content =
        \\env:
        \\  - name: DATABASE_URL
        \\    value: "test-value"
        \\env-from:
        \\  - s3:
        \\      bucket: env-bucket
        \\      key: db-config.json
        \\  - ssm:
        \\      path: /app/db/username
        \\      name: DB_USER
        \\  - secrets-manager:
        \\      secret-id: app/db/password
        \\      name: DB_PASS
    ;
    const parsed = (try VmSpec.from_yaml(testing.allocator, yaml_content)).?;
    defer parsed.deinit();
    const vmspec = parsed.value;

    // Check env was parsed
    try testing.expect(vmspec.env != null);
    try testing.expectEqual(@as(usize, 1), vmspec.env.?.len);
    try testing.expectEqualStrings("DATABASE_URL", vmspec.env.?[0].name);

    // Check env-from was parsed
    try testing.expect(vmspec.@"env-from" != null);
    try testing.expectEqual(@as(usize, 3), vmspec.@"env-from".?.len);

    // Check S3 source
    try testing.expect(vmspec.@"env-from".?[0].s3 != null);
    try testing.expectEqualStrings("env-bucket", vmspec.@"env-from".?[0].s3.?.bucket);

    // Check SSM source
    try testing.expect(vmspec.@"env-from".?[1].ssm != null);
    try testing.expectEqualStrings("/app/db/username", vmspec.@"env-from".?[1].ssm.?.path);

    // Check Secrets Manager source
    try testing.expect(vmspec.@"env-from".?[2].@"secrets-manager" != null);
    try testing.expectEqualStrings("app/db/password", vmspec.@"env-from".?[2].@"secrets-manager".?.@"secret-id");
}

test "VmSpec.merge env-from" {
    var vmspec = VmSpec{
        .arena = std.heap.ArenaAllocator.init(testing.allocator),
    };
    defer vmspec.deinit();

    // Parse env-from from YAML
    const yaml_content =
        \\env-from:
        \\  - s3:
        \\      bucket: test-bucket
        \\      key: config.json
        \\  - ssm:
        \\      path: /app/config
        \\      name: CONFIG
    ;
    const other_parsed = (try VmSpec.from_yaml(testing.allocator, yaml_content)).?;
    defer other_parsed.deinit();
    const other = other_parsed.value;

    // Verify other has env-from
    try testing.expect(other.@"env-from" != null);
    try testing.expectEqual(@as(usize, 2), other.@"env-from".?.len);

    // Merge into vmspec
    try vmspec.merge(other);

    // Verify env-from was merged
    try testing.expect(vmspec.@"env-from" != null);
    try testing.expectEqual(@as(usize, 2), vmspec.@"env-from".?.len);
    try testing.expect(vmspec.@"env-from".?[0].s3 != null);
    try testing.expect(vmspec.@"env-from".?[1].ssm != null);
}

test "VmSpec.from_yaml parses user data with quoted keys" {
    const yaml_content =
        \\"args": null
        \\"command":
        \\- "/usr/bin/runsvdir"
        \\- "/etc/service"
        \\"debug": true
        \\"disable-services": null
        \\"env":
        \\- "name": "KEIGHTS_INPUTS_SHA"
        \\  "value": "abc123"
        \\"env-from":
        \\- "imds":
        \\    "name": "HOSTNAME"
        \\    "optional": null
        \\    "path": "hostname"
        \\"init-scripts":
        \\- |
        \\  #!/bin/sh -e
        \\  echo hello
        \\"modules":
        \\- "br_netfilter"
        \\- "overlay"
        \\"replace-init": null
        \\"security": null
        \\"shutdown-grace-period": null
        \\"sysctls":
        \\- "name": "net.bridge.bridge-nf-call-iptables"
        \\  "value": "1"
        \\"working-dir": null
    ;
    const parsed = (try VmSpec.from_yaml(testing.allocator, yaml_content)).?;
    defer parsed.deinit();
    const vmspec = parsed.value;

    try testing.expect(vmspec.args == null);

    try testing.expectEqualStrings("/usr/bin/runsvdir", vmspec.command.?[0]);
    try testing.expectEqualStrings("/etc/service", vmspec.command.?[1]);

    try testing.expectEqual(@as(?bool, true), vmspec.debug);

    try testing.expectEqualStrings("KEIGHTS_INPUTS_SHA", vmspec.env.?[0].name);
    try testing.expectEqualStrings("abc123", vmspec.env.?[0].value);

    const imds = vmspec.@"env-from".?[0].imds.?;
    try testing.expectEqualStrings("HOSTNAME", imds.name);
    try testing.expectEqualStrings("hostname", imds.path);

    try testing.expect(
        std.mem.startsWith(u8, vmspec.@"init-scripts".?[0], "#!/bin/sh -e"),
    );

    try testing.expectEqualStrings("br_netfilter", vmspec.modules.?[0]);
    try testing.expectEqualStrings("overlay", vmspec.modules.?[1]);

    try testing.expectEqualStrings(
        "net.bridge.bridge-nf-call-iptables",
        vmspec.sysctls.?[0].name,
    );
    try testing.expectEqualStrings("1", vmspec.sysctls.?[0].value);

    // Fields set to YAML null are null; merge will skip them
    try testing.expect(vmspec.@"replace-init" == null);
    try testing.expect(vmspec.@"shutdown-grace-period" == null);
    try testing.expect(vmspec.@"working-dir" == null);
}
