//! AWS Secrets Manager client.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const SecretsManagerClient = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator, region: []const u8, endpoint_url: ?[]const u8) !SecretsManagerClient {
        _ = region;
        _ = endpoint_url;
        return SecretsManagerClient{ .allocator = allocator };
    }

    pub fn deinit(self: *SecretsManagerClient) void {
        _ = self;
    }
};
