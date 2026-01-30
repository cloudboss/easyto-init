//! AWS context providing lazily-initialized clients for AWS services.
//!
//! This module provides a central context that manages AWS service clients.
//! Clients are initialized on first use and cached for subsequent calls.

const std = @import("std");
const Allocator = std.mem.Allocator;

const aws_sdk = @import("aws_sdk");
const S3Client = @import("s3.zig").S3Client;
const SsmClient = @import("ssm.zig").SsmClient;
const SecretsManagerClient = @import("asm.zig").SecretsManagerClient;

const scoped_log = std.log.scoped(.aws_context);

pub const AwsContext = struct {
    allocator: Allocator,
    region: []const u8,
    endpoint_url: ?[]const u8,

    s3: ?S3Client = null,
    ssm: ?SsmClient = null,
    secrets_manager: ?SecretsManagerClient = null,

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        // Get region from environment or default to us-east-1
        const region = std.posix.getenv("AWS_REGION") orelse
            std.posix.getenv("AWS_DEFAULT_REGION") orelse
            "us-east-1";

        // Get custom endpoint URL (for LocalStack)
        const endpoint_url = std.posix.getenv("AWS_ENDPOINT_URL");

        if (endpoint_url) |url| {
            scoped_log.debug("Using custom endpoint: {s}", .{url});
        }

        return Self{
            .allocator = allocator,
            .region = region,
            .endpoint_url = endpoint_url,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.s3) |*client| {
            client.deinit();
        }
        if (self.ssm) |*client| {
            client.deinit();
        }
        if (self.secrets_manager) |*client| {
            client.deinit();
        }
    }

    /// Get or initialize the S3 client.
    pub fn getS3(self: *Self) !*S3Client {
        if (self.s3 == null) {
            scoped_log.debug("Initializing S3 client", .{});
            self.s3 = try S3Client.init(self.allocator, self.region, self.endpoint_url);
        }
        return &self.s3.?;
    }

    /// Get or initialize the SSM client.
    pub fn getSsm(self: *Self) !*SsmClient {
        if (self.ssm == null) {
            scoped_log.debug("Initializing SSM client", .{});
            self.ssm = try SsmClient.init(self.allocator, self.region, self.endpoint_url);
        }
        return &self.ssm.?;
    }

    /// Get or initialize the Secrets Manager client.
    pub fn getSecretsManager(self: *Self) !*SecretsManagerClient {
        if (self.secrets_manager == null) {
            scoped_log.debug("Initializing Secrets Manager client", .{});
            self.secrets_manager = try SecretsManagerClient.init(self.allocator, self.region, self.endpoint_url);
        }
        return &self.secrets_manager.?;
    }
};
