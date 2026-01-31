//! S3 client for fetching objects and environment variables from S3.

const std = @import("std");
const Allocator = std.mem.Allocator;

const aws_sdk = @import("aws_sdk");

const scoped_log = std.log.scoped(.aws_s3);

pub const S3Error = error{
    /// Object not found in S3
    ObjectNotFound,
    /// Access denied to S3 object
    AccessDenied,
    /// S3 request failed
    RequestFailed,
    /// Invalid JSON content
    InvalidJson,
    /// Out of memory
    OutOfMemory,
};

pub const S3Client = struct {
    allocator: Allocator,
    region: []const u8,
    aws_client: aws_sdk.Client,

    const Self = @This();
    const services = aws_sdk.Services(.{.s3}){};

    pub fn init(allocator: Allocator, region: []const u8, endpoint_url: ?[]const u8) !Self {
        _ = endpoint_url; // SDK reads AWS_ENDPOINT_URL automatically
        const aws_client = aws_sdk.Client.init(allocator, .{});
        return Self{
            .allocator = allocator,
            .region = region,
            .aws_client = aws_client,
        };
    }

    pub fn deinit(self: *Self) void {
        self.aws_client.deinit();
    }

    /// Fetch an object from S3 as bytes.
    pub fn getObject(self: *Self, bucket: []const u8, key: []const u8) ![]const u8 {
        scoped_log.debug("GetObject s3://{s}/{s}", .{ bucket, key });

        const options = aws_sdk.Options{
            .region = self.region,
            .client = self.aws_client,
        };

        const result = aws_sdk.Request(services.s3.get_object).call(.{
            .bucket = bucket,
            .key = key,
        }, options) catch |err| {
            scoped_log.err("S3 GetObject failed for s3://{s}/{s}: {s}", .{ bucket, key, @errorName(err) });
            return S3Error.RequestFailed;
        };
        defer result.deinit();

        if (result.response.body) |body| {
            return try self.allocator.dupe(u8, body);
        }

        return S3Error.ObjectNotFound;
    }

    /// Fetch an object from S3 and parse it as a JSON map of string key-value pairs.
    pub fn getObjectMap(self: *Self, bucket: []const u8, key: []const u8) !std.StringHashMap([]const u8) {
        const content = try self.getObject(bucket, key);
        defer self.allocator.free(content);

        var map = std.StringHashMap([]const u8).init(self.allocator);
        errdefer {
            var it = map.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            map.deinit();
        }

        // Parse JSON
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, content, .{}) catch |err| {
            scoped_log.err("Failed to parse JSON from s3://{s}/{s}: {s}", .{ bucket, key, @errorName(err) });
            return S3Error.InvalidJson;
        };
        defer parsed.deinit();

        // Expect an object at the root
        switch (parsed.value) {
            .object => |obj| {
                for (obj.keys(), obj.values()) |k, v| {
                    // Only include string values
                    switch (v) {
                        .string => |s| {
                            const key_copy = try self.allocator.dupe(u8, k);
                            errdefer self.allocator.free(key_copy);
                            const value_copy = try self.allocator.dupe(u8, s);
                            try map.put(key_copy, value_copy);
                        },
                        .integer => |i| {
                            const key_copy = try self.allocator.dupe(u8, k);
                            errdefer self.allocator.free(key_copy);
                            const value_str = try std.fmt.allocPrint(self.allocator, "{d}", .{i});
                            try map.put(key_copy, value_str);
                        },
                        .float => |f| {
                            const key_copy = try self.allocator.dupe(u8, k);
                            errdefer self.allocator.free(key_copy);
                            const value_str = try std.fmt.allocPrint(self.allocator, "{d}", .{f});
                            try map.put(key_copy, value_str);
                        },
                        .bool => |b| {
                            const key_copy = try self.allocator.dupe(u8, k);
                            errdefer self.allocator.free(key_copy);
                            const value_str = try self.allocator.dupe(u8, if (b) "true" else "false");
                            try map.put(key_copy, value_str);
                        },
                        else => {
                            // Skip non-scalar values
                            scoped_log.debug("Skipping non-scalar JSON value for key {s}", .{k});
                        },
                    }
                }
            },
            else => {
                scoped_log.err("Expected JSON object from s3://{s}/{s}", .{ bucket, key });
                return S3Error.InvalidJson;
            },
        }

        return map;
    }

    /// List objects with a given prefix, handling pagination.
    pub fn listObjects(self: *Self, bucket: []const u8, prefix: []const u8) ![]S3Object {
        scoped_log.debug("ListObjects s3://{s}/{s}", .{ bucket, prefix });

        const options = aws_sdk.Options{
            .region = self.region,
            .client = self.aws_client,
        };

        var objects: std.ArrayListUnmanaged(S3Object) = .empty;
        errdefer {
            for (objects.items) |*obj| obj.deinit(self.allocator);
            objects.deinit(self.allocator);
        }

        var continuation_token: ?[]const u8 = null;
        defer if (continuation_token) |ct| self.allocator.free(ct);

        while (true) {
            const result = aws_sdk.Request(services.s3.list_objects_v2).call(.{
                .bucket = bucket,
                .prefix = prefix,
                .continuation_token = continuation_token,
            }, options) catch |err| {
                scoped_log.err("S3 ListObjects failed for s3://{s}/{s}: {s}", .{ bucket, prefix, @errorName(err) });
                return S3Error.RequestFailed;
            };
            defer result.deinit();

            if (result.response.contents) |contents| {
                for (contents) |item| {
                    const item_key = item.key orelse continue;

                    // Skip "directory" markers (keys ending with /)
                    if (std.mem.endsWith(u8, item_key, "/")) continue;

                    // Calculate path suffix (relative to prefix)
                    const path_suffix = if (std.mem.startsWith(u8, item_key, prefix))
                        item_key[prefix.len..]
                    else
                        item_key;

                    try objects.append(self.allocator, S3Object{
                        .bucket = try self.allocator.dupe(u8, bucket),
                        .key = try self.allocator.dupe(u8, item_key),
                        .path_suffix = try self.allocator.dupe(u8, path_suffix),
                    });
                }
            }

            // Check for more pages
            if (result.response.is_truncated orelse false) {
                if (result.response.next_continuation_token) |token| {
                    if (continuation_token) |ct| self.allocator.free(ct);
                    continuation_token = try self.allocator.dupe(u8, token);
                    continue;
                }
            }
            break;
        }

        return try objects.toOwnedSlice(self.allocator);
    }
};

pub const S3Object = struct {
    bucket: []const u8,
    key: []const u8,
    path_suffix: []const u8,

    pub fn deinit(self: *S3Object, allocator: Allocator) void {
        allocator.free(self.bucket);
        allocator.free(self.key);
        allocator.free(self.path_suffix);
    }
};
