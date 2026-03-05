//! EC2 client for EBS volume operations.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const aws = @import("aws");
const ec2 = @import("ec2");
const Filter = ec2.types.Filter;

const backoff = @import("../backoff.zig");
const vmspec = @import("../vmspec.zig");
const EbsVolumeAttachment = vmspec.EbsVolumeAttachment;
const AwsTag = vmspec.AwsTag;

const scoped_log = std.log.scoped(.aws_ec2);

pub const Ec2Error = error{
    RequestFailed,
    ServiceError,
    Timeout,
};

/// Helper for building EC2 filter lists with automatic memory management.
const FilterBuilder = struct {
    allocator: Allocator,
    filters: std.ArrayListUnmanaged(Filter) = .empty,
    values: std.ArrayListUnmanaged([]const []const u8) = .empty,
    names: std.ArrayListUnmanaged([]const u8) = .empty,

    fn init(allocator: Allocator) FilterBuilder {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *FilterBuilder) void {
        for (self.names.items) |n| self.allocator.free(n);
        self.names.deinit(self.allocator);
        for (self.values.items) |arr| self.allocator.free(arr);
        self.values.deinit(self.allocator);
        self.filters.deinit(self.allocator);
    }

    fn add(self: *FilterBuilder, name: []const u8, value: []const u8) !void {
        const vals = try self.allocator.dupe([]const u8, &[_][]const u8{value});
        try self.values.append(self.allocator, vals);
        try self.filters.append(self.allocator, .{ .name = name, .values = vals });
    }

    /// Like add, but takes ownership of an allocated name.
    fn addAlloc(self: *FilterBuilder, name: []const u8, value: []const u8) !void {
        try self.names.append(self.allocator, name);
        try self.add(name, value);
    }

    fn items(self: *FilterBuilder) []Filter {
        return self.filters.items;
    }
};

pub const Ec2Client = struct {
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

    /// Ensure an EBS volume is attached to the instance.
    /// If the volume is already attached, returns immediately.
    /// If not, finds an available volume matching the tags and attaches it.
    pub fn ensureVolumeAttached(
        self: *Self,
        attachment: *const EbsVolumeAttachment,
        device: []const u8,
        availability_zone: []const u8,
        instance_id: []const u8,
    ) !void {
        if (try self.isVolumeAttached(attachment, device, instance_id)) {
            scoped_log.debug("volume already attached at {s}", .{device});
            return;
        }

        const volume_id = try self.waitForAvailableVolume(attachment, availability_zone);
        defer self.allocator.free(volume_id);

        scoped_log.info("attaching volume {s} to {s}", .{ volume_id, device });

        try self.attachVolume(volume_id, device, instance_id);
    }

    /// Check if a volume matching the attachment spec is already attached.
    fn isVolumeAttached(
        self: *Self,
        attachment: *const EbsVolumeAttachment,
        device: []const u8,
        instance_id: []const u8,
    ) !bool {
        var client = ec2.Client.init(self.allocator, &self.config);
        defer client.deinit();

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        var fb = FilterBuilder.init(self.allocator);
        defer fb.deinit();

        try fb.add("attachment.instance-id", instance_id);
        try fb.add("attachment.device", device);
        try self.addTagFilters(&fb, attachment.tags);

        var diagnostic: ec2.ServiceError = undefined;

        const result = client.describeVolumes(
            arena.allocator(),
            .{ .filters = fb.items() },
            .{ .diagnostic = &diagnostic },
        ) catch |err| {
            if (err == error.ServiceError) {
                defer diagnostic.deinit();
                scoped_log.err(
                    "DescribeVolumes failed: {s}: {s}",
                    .{ diagnostic.code(), diagnostic.message() },
                );
                return Ec2Error.ServiceError;
            }
            scoped_log.err("DescribeVolumes failed: {s}", .{@errorName(err)});
            return Ec2Error.RequestFailed;
        };

        if (result.volumes) |volumes| {
            return volumes.len > 0;
        }

        return false;
    }

    /// Wait for an available volume matching the attachment spec.
    /// Returns the volume ID when found.
    fn waitForAvailableVolume(
        self: *Self,
        attachment: *const EbsVolumeAttachment,
        availability_zone: []const u8,
    ) ![]const u8 {
        const timeout_secs = attachment.timeout orelse 300;
        const timeout_ns: u64 = timeout_secs * std.time.ns_per_s;
        const start_time = std.time.nanoTimestamp();

        var retry = backoff.RetryBackoff.init(10000);

        while (true) {
            if (try self.findAvailableVolume(attachment, availability_zone)) |volume_id| {
                return volume_id;
            }

            const elapsed: u64 = @intCast(std.time.nanoTimestamp() - start_time);
            if (elapsed > timeout_ns) {
                scoped_log.err("timeout waiting for EBS volume to be available", .{});
                return Ec2Error.Timeout;
            }

            scoped_log.debug("waiting for EBS volume to be available", .{});
            retry.wait();
        }
    }

    /// Find an available volume matching the attachment spec.
    fn findAvailableVolume(
        self: *Self,
        attachment: *const EbsVolumeAttachment,
        availability_zone: []const u8,
    ) !?[]const u8 {
        var client = ec2.Client.init(self.allocator, &self.config);
        defer client.deinit();

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        var fb = FilterBuilder.init(self.allocator);
        defer fb.deinit();

        try fb.add("status", "available");
        try fb.add("availability-zone", availability_zone);
        try self.addTagFilters(&fb, attachment.tags);

        var diagnostic: ec2.ServiceError = undefined;

        const result = client.describeVolumes(
            arena.allocator(),
            .{ .filters = fb.items() },
            .{ .diagnostic = &diagnostic },
        ) catch |err| {
            if (err == error.ServiceError) {
                defer diagnostic.deinit();
                scoped_log.err("DescribeVolumes failed: {s}: {s}", .{ diagnostic.code(), diagnostic.message() });
                return Ec2Error.ServiceError;
            }
            scoped_log.debug("DescribeVolumes failed: {s}", .{@errorName(err)});
            return null;
        };

        if (result.volumes) |volumes| {
            if (volumes.len > 0) {
                if (volumes[0].volume_id) |vol_id| {
                    scoped_log.debug("found matching EBS volume: {s}", .{vol_id});
                    return try self.allocator.dupe(u8, vol_id);
                }
            }
        }

        return null;
    }

    /// Attach a volume to an instance.
    fn attachVolume(
        self: *Self,
        volume_id: []const u8,
        device: []const u8,
        instance_id: []const u8,
    ) !void {
        var client = ec2.Client.init(self.allocator, &self.config);
        defer client.deinit();

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        var diagnostic: ec2.ServiceError = undefined;

        _ = client.attachVolume(
            arena.allocator(),
            .{
                .device = device,
                .instance_id = instance_id,
                .volume_id = volume_id,
            },
            .{ .diagnostic = &diagnostic },
        ) catch |err| {
            if (err == error.ServiceError) {
                defer diagnostic.deinit();
                scoped_log.err("AttachVolume failed: {s}: {s}", .{ diagnostic.code(), diagnostic.message() });
                return Ec2Error.ServiceError;
            }
            scoped_log.err("AttachVolume failed: {s}", .{@errorName(err)});
            return Ec2Error.RequestFailed;
        };

        scoped_log.info(
            "attached volume {s} to instance {s} at {s}",
            .{ volume_id, instance_id, device },
        );
    }

    fn addTagFilters(self: *Self, fb: *FilterBuilder, tags: []const AwsTag) !void {
        for (tags) |tag| {
            if (tag.value) |value| {
                const name = try std.fmt.allocPrint(self.allocator, "tag:{s}", .{tag.key});
                try fb.addAlloc(name, value);
            } else {
                try fb.add("tag-key", tag.key);
            }
        }
    }
};

test "FilterBuilder empty" {
    var fb = FilterBuilder.init(testing.allocator);
    defer fb.deinit();

    try testing.expectEqual(@as(usize, 0), fb.items().len);
}

test "FilterBuilder single filter" {
    var fb = FilterBuilder.init(testing.allocator);
    defer fb.deinit();

    try fb.add("status", "available");

    const filters = fb.items();
    try testing.expectEqual(@as(usize, 1), filters.len);
    try testing.expectEqualStrings("status", filters[0].name.?);
    try testing.expectEqual(@as(usize, 1), filters[0].values.?.len);
    try testing.expectEqualStrings("available", filters[0].values.?[0]);
}

test "FilterBuilder multiple filters" {
    var fb = FilterBuilder.init(testing.allocator);
    defer fb.deinit();

    try fb.add("status", "available");
    try fb.add("availability-zone", "us-east-1a");
    try fb.add("tag:Environment", "production");

    const filters = fb.items();
    try testing.expectEqual(@as(usize, 3), filters.len);

    try testing.expectEqualStrings("status", filters[0].name.?);
    try testing.expectEqualStrings("available", filters[0].values.?[0]);

    try testing.expectEqualStrings("availability-zone", filters[1].name.?);
    try testing.expectEqualStrings("us-east-1a", filters[1].values.?[0]);

    try testing.expectEqualStrings("tag:Environment", filters[2].name.?);
    try testing.expectEqualStrings("production", filters[2].values.?[0]);
}
