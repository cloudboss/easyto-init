const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const testing = std.testing;
const yaml = @import("yaml.zig");

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

        // Dupe string arrays to arena
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
        for (slice, 0..) |s, i| {
            result[i] = try allocator.dupe(u8, s);
        }
        return result;
    }

    pub fn deinit(self: *VmSpec) void {
        if (self.arena) |*arena| {
            arena.deinit();
            self.arena = null;
        }
    }

    /// Get the arena allocator, creating it if needed.
    fn getArenaAllocator(self: *VmSpec, backing_allocator: Allocator) Allocator {
        if (self.arena == null) {
            self.arena = std.heap.ArenaAllocator.init(backing_allocator);
        }
        return self.arena.?.allocator();
    }

    /// Parse user data from YAML string.
    /// Returns null if the content is empty.
    pub fn from_yaml(allocator: Allocator, content: []const u8) !?VmSpec {
        const trimmed = std.mem.trim(u8, content, " \t\r\n");
        if (trimmed.len == 0) {
            return null;
        }

        var parsed = yaml.parse(allocator, content) catch |err| {
            std.log.err("failed to parse user data YAML: {s}", .{@errorName(err)});
            return err;
        };
        defer parsed.deinit();

        var vmspec = VmSpec{
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
        errdefer vmspec.deinit();

        try fromYamlValue(&vmspec, parsed.value);
        return vmspec;
    }

    fn fromYamlValue(vmspec: *VmSpec, value: yaml.Value) !void {
        const arena_alloc = vmspec.arena.?.allocator();

        const map = value.getMap() orelse {
            std.log.err("user data is not a valid YAML map", .{});
            return error.InvalidYaml;
        };

        for (map) |entry| {
            if (std.mem.eql(u8, entry.key, "args")) {
                vmspec.args = try parseStringList(arena_alloc, entry.value);
            } else if (std.mem.eql(u8, entry.key, "command")) {
                vmspec.command = try parseStringList(arena_alloc, entry.value);
            } else if (std.mem.eql(u8, entry.key, "debug")) {
                if (entry.value.getString()) |s| {
                    vmspec.debug = std.mem.eql(u8, s, "true");
                }
            } else if (std.mem.eql(u8, entry.key, "disable-services")) {
                vmspec.@"disable-services" = try parseStringList(arena_alloc, entry.value);
            } else if (std.mem.eql(u8, entry.key, "env")) {
                vmspec.env = try parseNameValueList(arena_alloc, entry.value);
            } else if (std.mem.eql(u8, entry.key, "init-scripts")) {
                vmspec.@"init-scripts" = try parseStringList(arena_alloc, entry.value);
            } else if (std.mem.eql(u8, entry.key, "modules")) {
                vmspec.modules = try parseStringList(arena_alloc, entry.value);
            } else if (std.mem.eql(u8, entry.key, "replace-init")) {
                if (entry.value.getString()) |s| {
                    vmspec.@"replace-init" = std.mem.eql(u8, s, "true");
                }
            } else if (std.mem.eql(u8, entry.key, "security")) {
                vmspec.security = try parseSecurity(entry.value);
            } else if (std.mem.eql(u8, entry.key, "shutdown-grace-period")) {
                if (entry.value.getString()) |s| {
                    vmspec.@"shutdown-grace-period" = std.fmt.parseInt(u64, s, 10) catch 10;
                }
            } else if (std.mem.eql(u8, entry.key, "sysctls")) {
                vmspec.sysctls = try parseNameValueList(arena_alloc, entry.value);
            } else if (std.mem.eql(u8, entry.key, "working-dir")) {
                if (entry.value.getString()) |s| {
                    vmspec.@"working-dir" = try arena_alloc.dupe(u8, s);
                }
            }
            // Note: env-from and volumes require more complex parsing
        }
    }

    fn parseStringList(allocator: Allocator, value: yaml.Value) !?[][]const u8 {
        const list = value.getList() orelse return null;
        var result = try ArrayList([]const u8).initCapacity(allocator, list.len);
        errdefer {
            for (result.items) |s| allocator.free(s);
            result.deinit(allocator);
        }

        for (list) |item| {
            if (item.getString()) |s| {
                try result.append(allocator, try allocator.dupe(u8, s));
            }
        }

        return try result.toOwnedSlice(allocator);
    }

    fn parseNameValueList(allocator: Allocator, value: yaml.Value) !?[]NameValue {
        const list = value.getList() orelse return null;
        var result = try ArrayList(NameValue).initCapacity(allocator, list.len);
        errdefer {
            for (result.items) |*nv| nv.deinit(allocator);
            result.deinit(allocator);
        }

        for (list) |item| {
            const item_map = item.getMap() orelse continue;
            var name: ?[]const u8 = null;
            var val: ?[]const u8 = null;

            for (item_map) |entry| {
                if (std.mem.eql(u8, entry.key, "name")) {
                    name = entry.value.getString();
                } else if (std.mem.eql(u8, entry.key, "value")) {
                    val = entry.value.getString();
                }
            }

            if (name != null) {
                try result.append(allocator, .{
                    .name = try allocator.dupe(u8, name.?),
                    .value = try allocator.dupe(u8, val orelse ""),
                });
            }
        }

        return try result.toOwnedSlice(allocator);
    }

    fn parseSecurity(value: yaml.Value) !Security {
        var security = Security{};
        const map = value.getMap() orelse return security;

        for (map) |entry| {
            if (std.mem.eql(u8, entry.key, "run-as-user-id")) {
                if (entry.value.getString()) |s| {
                    security.@"run-as-user-id" = std.fmt.parseInt(u32, s, 10) catch null;
                }
            } else if (std.mem.eql(u8, entry.key, "run-as-group-id")) {
                if (entry.value.getString()) |s| {
                    security.@"run-as-group-id" = std.fmt.parseInt(u32, s, 10) catch null;
                }
            } else if (std.mem.eql(u8, entry.key, "readonly-root-fs")) {
                if (entry.value.getString()) |s| {
                    security.@"readonly-root-fs" = std.mem.eql(u8, s, "true");
                }
            }
        }

        return security;
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
            // If command is overridden but args is not in other, clear args
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
        if (other.@"env-from" != null) {
            self.@"env-from" = other.@"env-from";
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
        if (other.volumes != null) {
            self.volumes = other.volumes;
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
