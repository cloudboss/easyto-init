//! SSM Parameter Store client.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const SsmClient = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator, region: []const u8, endpoint_url: ?[]const u8) !SsmClient {
        _ = region;
        _ = endpoint_url;
        return SsmClient{ .allocator = allocator };
    }

    pub fn deinit(self: *SsmClient) void {
        _ = self;
    }
};
