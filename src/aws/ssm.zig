//! SSM Parameter Store client.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const aws = @import("aws");
const ssm = @import("ssm");

const fs_utils = @import("../fs.zig");
const s3 = @import("s3.zig");

const scoped_log = std.log.scoped(.aws_ssm);

pub const SsmError = error{
    ParameterNotFound,
    RequestFailed,
    ServiceError,
};

pub const SsmClient = struct {
    allocator: Allocator,
    config: aws.Config,

    const Self = @This();

    pub fn init(allocator: Allocator, region: []const u8) !Self {
        return Self{
            .allocator = allocator,
            .config = try aws.Config.load(allocator, .{ .region = region }),
        };
    }

    pub fn deinit(self: *Self) void {
        self.config.deinit();
    }

    /// Fetch a single parameter value from SSM.
    pub fn getParameter(self: *Self, name: []const u8) ![]const u8 {
        scoped_log.debug("GetParameter {s}", .{name});

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        var client = ssm.Client.init(self.allocator, &self.config);
        defer client.deinit();

        var diagnostic: ssm.ServiceError = undefined;

        const result = client.getParameter(
            arena.allocator(),
            .{ .name = name, .with_decryption = true },
            .{ .diagnostic = &diagnostic },
        ) catch |err| {
            if (err == error.ServiceError) {
                defer diagnostic.deinit();
                scoped_log.err(
                    "SSM GetParameter failed for {s}: {s}: {s}",
                    .{ name, diagnostic.code(), diagnostic.message() },
                );
                return SsmError.ServiceError;
            }
            scoped_log.err(
                "SSM GetParameter failed for {s}: {s}",
                .{ name, @errorName(err) },
            );
            return SsmError.RequestFailed;
        };

        if (result.parameter) |param| {
            if (param.value) |value| {
                return try self.allocator.dupe(u8, value);
            }
        }

        return SsmError.ParameterNotFound;
    }

    /// Fetch a parameter and parse it as a JSON map of string key-value pairs.
    pub fn getParameterMap(
        self: *Self,
        name: []const u8,
    ) !std.StringHashMap([]const u8) {
        const content = try self.getParameter(name);
        defer self.allocator.free(content);

        return s3.parseJsonToMap(self.allocator, content) catch |err| {
            scoped_log.err(
                "Failed to parse JSON from SSM parameter {s}: {s}",
                .{ name, @errorName(err) },
            );
            return err;
        };
    }

    /// Fetch all parameters under a path prefix, handling pagination.
    pub fn getParametersByPath(self: *Self, path: []const u8) ![]SsmParameter {
        scoped_log.debug("GetParametersByPath {s}", .{path});

        var parameters: std.ArrayListUnmanaged(SsmParameter) = .empty;
        errdefer {
            for (parameters.items) |*param| param.deinit(self.allocator);
            parameters.deinit(self.allocator);
        }

        var client = ssm.Client.init(self.allocator, &self.config);
        defer client.deinit();

        var paginator = ssm.paginator.GetParametersByPathPaginator{
            .client = &client,
            .params = .{
                .path = path,
                .recursive = true,
                .with_decryption = true,
                .max_results = 10,
            },
        };
        defer paginator.deinit();

        while (!paginator.done) {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();

            var diagnostic: ssm.ServiceError = undefined;
            const result = paginator.next(
                arena.allocator(),
                .{ .diagnostic = &diagnostic },
            ) catch |err| {
                if (err == error.ServiceError) {
                    defer diagnostic.deinit();
                    scoped_log.err(
                        "SSM GetParametersByPath failed for {s}: {s}: {s}",
                        .{ path, diagnostic.code(), diagnostic.message() },
                    );
                    return SsmError.ServiceError;
                }
                scoped_log.err(
                    "SSM GetParametersByPath failed for {s}: {s}",
                    .{ path, @errorName(err) },
                );
                return SsmError.RequestFailed;
            };

            if (result.parameters) |params| {
                for (params) |param| {
                    const param_name = param.name orelse continue;
                    const param_value = param.value orelse continue;

                    const relative_name = calculateRelativeName(
                        param_name,
                        path,
                    );

                    try parameters.append(self.allocator, SsmParameter{
                        .name = try self.allocator.dupe(u8, param_name),
                        .relative_name = try self.allocator.dupe(u8, relative_name),
                        .value = try self.allocator.dupe(u8, param_value),
                    });
                }
            }
        }

        return try parameters.toOwnedSlice(self.allocator);
    }

    /// Fetch parameters at a path. If the path starts with `/`, first tries
    /// GetParametersByPath (hierarchy lookup). If that returns no results,
    /// or if the path doesn't start with `/`, falls back to GetParameter
    /// (single parameter). Matches the Rust implementation's logic.
    pub fn getParameters(self: *Self, path: []const u8) ![]SsmParameter {
        var parameters: std.ArrayListUnmanaged(SsmParameter) = .empty;
        errdefer {
            for (parameters.items) |*param| param.deinit(self.allocator);
            parameters.deinit(self.allocator);
        }

        if (std.mem.startsWith(u8, path, "/")) {
            const by_path = try self.getParametersByPath(path);
            defer self.allocator.free(by_path);
            for (by_path) |param| {
                try parameters.append(self.allocator, param);
            }
        }

        if (parameters.items.len == 0) {
            scoped_log.debug("no parameters under path {s}, trying as single parameter", .{path});
            const value = try self.getParameter(path);
            errdefer self.allocator.free(value);

            try parameters.append(self.allocator, SsmParameter{
                .name = try self.allocator.dupe(u8, path),
                .relative_name = try self.allocator.dupe(u8, calculateRelativeName(path, path)),
                .value = value,
            });
        }

        return try parameters.toOwnedSlice(self.allocator);
    }

    /// Download all parameters under a path to a destination directory.
    /// Each parameter's relative name (after the path prefix) determines its file location.
    /// Falls back to fetching a single parameter if the path doesn't match a hierarchy.
    pub fn downloadPathToDir(
        self: *Self,
        path: []const u8,
        destination: []const u8,
        options: DownloadOptions,
    ) !DownloadResult {
        scoped_log.debug("downloadPathToDir {s} -> {s}", .{ path, destination });

        const parameters = try self.getParameters(path);
        defer {
            for (parameters) |*param| {
                var p = param.*;
                p.deinit(self.allocator);
            }
            self.allocator.free(parameters);
        }

        for (parameters) |param| {
            scoped_log.debug("downloading SSM parameter {s}", .{param.name});

            const dest_path = if (param.relative_name.len == 0)
                try self.allocator.dupe(u8, destination)
            else
                try fs_utils.joinPath(
                    self.allocator,
                    destination,
                    param.relative_name,
                );
            defer self.allocator.free(dest_path);

            scoped_log.debug("writing {s} ({d} bytes)", .{ dest_path, param.value.len });

            fs_utils.writeFile(
                dest_path,
                param.value,
                options.file_mode,
                options.dir_mode,
                options.uid,
                options.gid,
            ) catch |err| {
                scoped_log.err("failed to write {s}: {s}", .{ dest_path, @errorName(err) });
                return err;
            };
        }

        return DownloadResult{ .files_written = parameters.len };
    }
};

/// Options for downloading SSM parameters to the filesystem.
pub const DownloadOptions = struct {
    file_mode: std.fs.File.Mode = 0o600, // SSM params often contain secrets
    dir_mode: std.fs.File.Mode = 0o755,
    uid: ?u32 = null,
    gid: ?u32 = null,
};

/// Result of a path download operation.
pub const DownloadResult = struct {
    files_written: usize,
};

pub const SsmParameter = struct {
    name: []const u8,
    relative_name: []const u8,
    value: []const u8,

    pub fn deinit(self: *SsmParameter, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.relative_name);
        allocator.free(self.value);
    }
};

/// Calculate the relative name for an SSM parameter by removing the path prefix.
pub fn calculateRelativeName(name: []const u8, path: []const u8) []const u8 {
    if (std.mem.startsWith(u8, name, path)) {
        return name[path.len..];
    }
    return name;
}

test "calculateRelativeName with matching prefix" {
    try testing.expectEqualStrings("database_host", calculateRelativeName("/app/config/database_host", "/app/config/"));
    try testing.expectEqualStrings("nested/deep/param", calculateRelativeName("/prefix/nested/deep/param", "/prefix/"));
    try testing.expectEqualStrings("", calculateRelativeName("/exact/match/", "/exact/match/"));
}

test "calculateRelativeName with non-matching prefix" {
    try testing.expectEqualStrings("/other/path/param", calculateRelativeName("/other/path/param", "/app/config/"));
}

test "calculateRelativeName with empty prefix" {
    try testing.expectEqualStrings("/app/config/param", calculateRelativeName("/app/config/param", ""));
}

test "calculateRelativeName with empty name" {
    try testing.expectEqualStrings("", calculateRelativeName("", "/prefix/"));
}

test "SsmParameter.deinit frees all strings" {
    const allocator = testing.allocator;

    var param = SsmParameter{
        .name = try allocator.dupe(u8, "/app/config/test"),
        .relative_name = try allocator.dupe(u8, "test"),
        .value = try allocator.dupe(u8, "test-value"),
    };

    param.deinit(allocator);
}

test "SsmParameter with empty strings" {
    const allocator = testing.allocator;

    var param = SsmParameter{
        .name = try allocator.dupe(u8, ""),
        .relative_name = try allocator.dupe(u8, ""),
        .value = try allocator.dupe(u8, ""),
    };

    param.deinit(allocator);
}
