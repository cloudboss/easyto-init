//! EC2 client for EBS volume operations.

const std = @import("std");
const Allocator = std.mem.Allocator;

const aws_sdk = @import("aws_sdk");

const backoff = @import("../backoff.zig");
const vmspec = @import("../vmspec.zig");
const EbsVolumeAttachment = vmspec.EbsVolumeAttachment;
const AwsTag = vmspec.AwsTag;

const scoped_log = std.log.scoped(.aws_ec2);

pub const Ec2Error = error{
    /// Volume not found
    VolumeNotFound,
    /// Access denied
    AccessDenied,
    /// Request failed
    RequestFailed,
    /// Timeout waiting for volume
    Timeout,
    /// Out of memory
    OutOfMemory,
};

const services = aws_sdk.Services(.{.ec2}){};
const Filter = services.ec2.Filter;

/// Helper for building EC2 filter lists with automatic memory management.
const FilterBuilder = struct {
    allocator: Allocator,
    filters: std.ArrayListUnmanaged(Filter) = .empty,
    values: std.ArrayListUnmanaged([]const []const u8) = .empty,

    fn init(allocator: Allocator) FilterBuilder {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *FilterBuilder) void {
        for (self.values.items) |arr| self.allocator.free(arr);
        self.values.deinit(self.allocator);
        self.filters.deinit(self.allocator);
    }

    fn add(self: *FilterBuilder, name: []const u8, value: []const u8) !void {
        const vals = try self.allocator.dupe([]const u8, &[_][]const u8{value});
        try self.values.append(self.allocator, vals);
        try self.filters.append(self.allocator, .{ .name = name, .values = vals });
    }

    fn items(self: *FilterBuilder) []Filter {
        return self.filters.items;
    }
};

pub const Ec2Client = struct {
    allocator: Allocator,
    aws_client: aws_sdk.Client,

    const Self = @This();

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
        // Check if already attached
        if (try self.isVolumeAttached(attachment, device, instance_id)) {
            scoped_log.debug("volume already attached at {s}", .{device});
            return;
        }

        // Find an available volume matching the filters
        const volume_id = try self.waitForAvailableVolume(attachment, availability_zone);
        defer self.allocator.free(volume_id);

        scoped_log.info("attaching volume {s} to {s}", .{ volume_id, device });

        // Attach the volume
        try self.attachVolume(volume_id, device, instance_id);
    }

    /// Check if a volume matching the attachment spec is already attached.
    fn isVolumeAttached(
        self: *Self,
        attachment: *const EbsVolumeAttachment,
        device: []const u8,
        instance_id: []const u8,
    ) !bool {
        const options = aws_sdk.Options{
            .client = self.aws_client,
        };

        var fb = FilterBuilder.init(self.allocator);
        defer fb.deinit();

        try fb.add("attachment.instance-id", instance_id);
        try fb.add("attachment.device", device);
        try self.addTagFilters(&fb, attachment.tags);

        const result = aws_sdk.Request(services.ec2.describe_volumes).call(.{
            .filters = fb.items(),
        }, options) catch |err| {
            scoped_log.err("DescribeVolumes failed: {s}", .{@errorName(err)});
            return Ec2Error.RequestFailed;
        };
        defer result.deinit();

        if (result.response.volumes) |volumes| {
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
        const options = aws_sdk.Options{
            .client = self.aws_client,
        };

        var fb = FilterBuilder.init(self.allocator);
        defer fb.deinit();

        try fb.add("status", "available");
        try fb.add("availability-zone", availability_zone);
        try self.addTagFilters(&fb, attachment.tags);

        const result = aws_sdk.Request(services.ec2.describe_volumes).call(.{
            .filters = fb.items(),
        }, options) catch |err| {
            scoped_log.debug("DescribeVolumes failed: {s}", .{@errorName(err)});
            return null;
        };
        defer result.deinit();

        if (result.response.volumes) |volumes| {
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
        const options = aws_sdk.Options{
            .client = self.aws_client,
        };

        const result = aws_sdk.Request(services.ec2.attach_volume).call(.{
            .device = device,
            .instance_id = instance_id,
            .volume_id = volume_id,
        }, options) catch |err| {
            scoped_log.err("AttachVolume failed: {s}", .{@errorName(err)});
            return Ec2Error.RequestFailed;
        };
        result.deinit();

        scoped_log.info("attached volume {s} to instance {s} at {s}", .{ volume_id, instance_id, device });
    }

    /// Add tag filters to a FilterBuilder.
    fn addTagFilters(self: *Self, fb: *FilterBuilder, tags: []const AwsTag) !void {
        for (tags) |tag| {
            if (tag.value) |value| {
                const name = try std.fmt.allocPrint(self.allocator, "tag:{s}", .{tag.key});
                defer self.allocator.free(name);
                try fb.add(name, value);
            } else {
                try fb.add("tag-key", tag.key);
            }
        }
    }
};

const testing = std.testing;

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
