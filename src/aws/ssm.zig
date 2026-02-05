//! SSM Parameter Store client.

const std = @import("std");
const Allocator = std.mem.Allocator;

const aws_sdk = @import("aws_sdk");

const scoped_log = std.log.scoped(.aws_ssm);

const fs_utils = @import("../fs.zig");
const s3 = @import("s3.zig");

pub const SsmError = error{
    /// Parameter not found in SSM
    ParameterNotFound,
    /// Access denied to SSM parameter
    AccessDenied,
    /// SSM request failed
    RequestFailed,
    /// Invalid JSON content
    InvalidJson,
    /// Out of memory
    OutOfMemory,
};

pub const SsmClient = struct {
    allocator: Allocator,
    aws_client: aws_sdk.Client,

    const Self = @This();
    const services = aws_sdk.Services(.{.ssm}){};

    pub fn init(allocator: Allocator) Self {
        const aws_client = aws_sdk.Client.init(allocator, .{});
        return Self{
            .allocator = allocator,
            .aws_client = aws_client,
        };
    }

    pub fn deinit(self: *Self) void {
        self.aws_client.deinit();
    }

    /// Fetch a single parameter value from SSM.
    pub fn getParameter(self: *Self, name: []const u8) ![]const u8 {
        scoped_log.debug("GetParameter {s}", .{name});

        const options = aws_sdk.Options{
            .client = self.aws_client,
        };

        const result = aws_sdk.Request(services.ssm.get_parameter).call(.{
            .name = name,
            .with_decryption = true,
        }, options) catch |err| {
            scoped_log.err("SSM GetParameter failed for {s}: {s}", .{ name, @errorName(err) });
            return SsmError.RequestFailed;
        };
        defer result.deinit();

        if (result.response.parameter) |param| {
            if (param.value) |value| {
                return try self.allocator.dupe(u8, value);
            }
        }

        return SsmError.ParameterNotFound;
    }

    /// Fetch a parameter and parse it as a JSON map of string key-value pairs.
    pub fn getParameterMap(self: *Self, name: []const u8) !std.StringHashMap([]const u8) {
        const content = try self.getParameter(name);
        defer self.allocator.free(content);

        return s3.parseJsonToMap(self.allocator, content) catch |err| {
            scoped_log.err("Failed to parse JSON from SSM parameter {s}: {s}", .{ name, @errorName(err) });
            return err;
        };
    }

    /// Fetch all parameters under a path prefix, handling pagination.
    pub fn getParametersByPath(self: *Self, path: []const u8) ![]SsmParameter {
        scoped_log.debug("GetParametersByPath {s}", .{path});

        const options = aws_sdk.Options{
            .client = self.aws_client,
        };

        var parameters: std.ArrayListUnmanaged(SsmParameter) = .empty;
        errdefer {
            for (parameters.items) |*param| param.deinit(self.allocator);
            parameters.deinit(self.allocator);
        }

        var next_token: ?[]const u8 = null;
        defer if (next_token) |nt| self.allocator.free(nt);

        while (true) {
            const result = aws_sdk.Request(services.ssm.get_parameters_by_path).call(.{
                .path = path,
                .recursive = true,
                .with_decryption = true,
                .next_token = next_token,
                .max_results = 10, // Required for LocalStack compatibility
            }, options) catch |err| {
                scoped_log.err("SSM GetParametersByPath failed for {s}: {s}", .{ path, @errorName(err) });
                return SsmError.RequestFailed;
            };
            defer result.deinit();

            if (result.response.parameters) |params| {
                for (params) |param| {
                    const param_name = param.name orelse continue;
                    const param_value = param.value orelse continue;

                    // Calculate relative path (remove prefix)
                    const relative_name = calculateRelativeName(param_name, path);

                    try parameters.append(self.allocator, SsmParameter{
                        .name = try self.allocator.dupe(u8, param_name),
                        .relative_name = try self.allocator.dupe(u8, relative_name),
                        .value = try self.allocator.dupe(u8, param_value),
                    });
                }
            }

            // Check for more pages
            if (result.response.next_token) |token| {
                if (next_token) |nt| self.allocator.free(nt);
                next_token = try self.allocator.dupe(u8, token);
                continue;
            }
            break;
        }

        return try parameters.toOwnedSlice(self.allocator);
    }

    /// Download all parameters under a path to a destination directory.
    /// Each parameter's relative name (after the path prefix) determines its file location.
    pub fn downloadPathToDir(
        self: *Self,
        path: []const u8,
        destination: []const u8,
        options: DownloadOptions,
    ) !DownloadResult {
        scoped_log.debug("downloadPathToDir {s} -> {s}", .{ path, destination });

        const parameters = try self.getParametersByPath(path);
        defer {
            for (parameters) |*param| {
                var p = param.*;
                p.deinit(self.allocator);
            }
            self.allocator.free(parameters);
        }

        for (parameters) |param| {
            scoped_log.debug("downloading SSM parameter {s}", .{param.name});

            // Build destination path: join destination with relative_name
            const dest_path = try fs_utils.joinPath(self.allocator, destination, param.relative_name);
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

const testing = std.testing;

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
