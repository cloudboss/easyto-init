//! AWS Secrets Manager client.

const std = @import("std");
const Allocator = std.mem.Allocator;

const aws_sdk = @import("aws_sdk");

const scoped_log = std.log.scoped(.aws_asm);

const fs_utils = @import("../fs.zig");
const s3 = @import("s3.zig");

pub const SecretsManagerError = error{
    /// Secret not found in Secrets Manager
    SecretNotFound,
    /// Access denied to secret
    AccessDenied,
    /// Secrets Manager request failed
    RequestFailed,
    /// Invalid JSON content
    InvalidJson,
    /// Secret has no value
    SecretEmpty,
    /// Out of memory
    OutOfMemory,
};

pub const SecretsManagerClient = struct {
    allocator: Allocator,
    aws_client: aws_sdk.Client,
    region: []const u8,

    const Self = @This();
    const services = aws_sdk.Services(.{.secrets_manager}){};

    pub fn init(allocator: Allocator, region: []const u8) Self {
        const aws_client = aws_sdk.Client.init(allocator, .{});
        return Self{
            .allocator = allocator,
            .aws_client = aws_client,
            .region = region,
        };
    }

    pub fn deinit(self: *Self) void {
        self.aws_client.deinit();
    }

    /// Fetch a secret value from Secrets Manager.
    /// Returns the secret as bytes (works for both string and binary secrets).
    pub fn getSecretValue(self: *Self, secret_id: []const u8) ![]const u8 {
        scoped_log.debug("GetSecretValue {s}", .{secret_id});

        const options = aws_sdk.Options{
            .client = self.aws_client,
            .region = self.region,
        };

        const result = aws_sdk.Request(services.secrets_manager.get_secret_value).call(.{
            .secret_id = secret_id,
        }, options) catch |err| {
            scoped_log.err(
                "Secrets Manager GetSecretValue failed for {s}: {s}",
                .{ secret_id, @errorName(err) },
            );
            return SecretsManagerError.RequestFailed;
        };
        defer result.deinit();

        // Check for string secret first, then binary
        if (result.response.secret_string) |secret_string| {
            return try self.allocator.dupe(u8, secret_string);
        }

        if (result.response.secret_binary) |secret_binary| {
            return try self.allocator.dupe(u8, secret_binary);
        }

        scoped_log.err("Secret {s} has no value (neither string nor binary)", .{secret_id});
        return SecretsManagerError.SecretEmpty;
    }

    /// Fetch a secret and parse it as a JSON map of string key-value pairs.
    pub fn getSecretMap(self: *Self, secret_id: []const u8) !std.StringHashMap([]const u8) {
        const content = try self.getSecretValue(secret_id);
        defer self.allocator.free(content);

        return s3.parseJsonToMap(self.allocator, content) catch |err| {
            scoped_log.err("Failed to parse JSON from secret {s}: {s}", .{ secret_id, @errorName(err) });
            return err;
        };
    }

    /// Download a secret to a file.
    /// The file is created with restrictive permissions (0o600 by default) since secrets
    /// should be protected.
    pub fn downloadSecretToFile(
        self: *Self,
        secret_id: []const u8,
        destination: []const u8,
        options: DownloadOptions,
    ) !void {
        scoped_log.debug("downloadSecretToFile {s} -> {s}", .{ secret_id, destination });

        const content = try self.getSecretValue(secret_id);
        defer self.allocator.free(content);

        scoped_log.debug("writing {s} ({d} bytes)", .{ destination, content.len });

        fs_utils.writeFile(
            destination,
            content,
            options.file_mode,
            options.dir_mode,
            options.uid,
            options.gid,
        ) catch |err| {
            scoped_log.err("failed to write {s}: {s}", .{ destination, @errorName(err) });
            return err;
        };
    }
};

/// Options for downloading secrets to the filesystem.
pub const DownloadOptions = struct {
    file_mode: std.fs.File.Mode = 0o600, // Secrets should be restrictive
    dir_mode: std.fs.File.Mode = 0o755,
    uid: ?u32 = null,
    gid: ?u32 = null,
};

const testing = std.testing;

test "SecretsManagerClient struct has expected fields" {
    // Compile-time check that the struct has the expected shape
    const T = SecretsManagerClient;
    try testing.expect(@hasField(T, "allocator"));
    try testing.expect(@hasField(T, "aws_client"));
}

test "DownloadOptions has secure defaults" {
    const opts = DownloadOptions{};
    // Secrets should default to 0o600 (owner read/write only)
    try testing.expectEqual(@as(std.fs.File.Mode, 0o600), opts.file_mode);
    try testing.expectEqual(@as(std.fs.File.Mode, 0o755), opts.dir_mode);
    try testing.expect(opts.uid == null);
    try testing.expect(opts.gid == null);
}

test "DownloadOptions can override permissions" {
    const opts = DownloadOptions{
        .file_mode = 0o400,
        .dir_mode = 0o700,
        .uid = 1000,
        .gid = 1000,
    };
    try testing.expectEqual(@as(std.fs.File.Mode, 0o400), opts.file_mode);
    try testing.expectEqual(@as(std.fs.File.Mode, 0o700), opts.dir_mode);
    try testing.expectEqual(@as(?u32, 1000), opts.uid);
    try testing.expectEqual(@as(?u32, 1000), opts.gid);
}
