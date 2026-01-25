const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const testing = std.testing;

const constants = @import("constants.zig");
const container = @import("container.zig");
const Config = container.Config;
const ConfigFile = container.ConfigFile;
const login = @import("login.zig");
const string = @import("string.zig");

const default_command = [_][]const u8{constants.DIR_ET_BIN ++ "/sh"};

const Error = error{
    InvalidEnvironmentVariable,
    InvalidUserGroup,
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
    @"replace-init": ?bool = false,
    security: Security = Security{},
    @"shutdown-grace-period": ?u64 = 10,
    sysctls: ?[]NameValue = null,
    volumes: ?[]Volume = null,
    @"working-dir": ?[]const u8 = "/",

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
        const config = config_file.config orelse Config{};
        const env = if (config.Env != null)
            try VmSpec.env_strings_to_name_values(allocator, config.Env.?)
        else
            null;

        var vmspec = VmSpec{
            .args = config.Cmd,
            .command = config.Entrypoint,
            .env = env,
        };

        if (config.WorkingDir != null) {
            vmspec.@"working-dir" = config.WorkingDir;
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
    name: ?[]const u8,
    optional: ?bool = null,
};

pub const SecretsManagerEnvSource = struct {
    @"base64-encode": ?bool = null,
    name: []const u8,
    optional: ?bool = null,
    @"secret-id": []const u8,
};

pub const SsmEnvSource = struct {
    @"base64-encode": ?bool = null,
    name: ?[]const u8,
    path: []const u8,
    optional: ?bool = null,
};

pub const Security = struct {
    @"readonly-root-fs": ?bool = null,
    @"run-as-group-id": ?u32 = null,
    @"run-as-user-id": ?u32 = null,
    sshd: Sshd = Sshd{},
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
    device: []const u8,
    @"fs-type": ?[]const u8 = null,
    @"make-fs": ?bool = null,
    mount: Mount,
};

pub const S3VolumeSource = struct {
    bucket: []const u8,
    @"key-prefix": []const u8,
    optional: ?bool,
    mount: Mount,
};

pub const SecretsManagerVolumeSource = struct {
    @"secret-id": []const u8,
    mount: Mount,
    optional: ?bool,
};

pub const SsmVolumeSource = struct {
    path: []const u8,
    mount: Mount,
    optional: ?bool,
};

pub const Mount = struct {
    destination: []const u8,
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
