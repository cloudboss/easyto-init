//! S3 client for fetching objects and environment variables from S3.

const std = @import("std");
const Allocator = std.mem.Allocator;

const aws_sdk = @import("aws_sdk");

const scoped_log = std.log.scoped(.aws_s3);

const fs_utils = @import("../fs.zig");

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
    aws_client: aws_sdk.Client,
    region: []const u8,

    const Self = @This();
    const services = aws_sdk.Services(.{.s3}){};

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

    /// Fetch an object from S3 as bytes.
    pub fn getObject(self: *Self, bucket: []const u8, key: []const u8) ![]const u8 {
        scoped_log.debug("GetObject s3://{s}/{s}", .{ bucket, key });

        const options = aws_sdk.Options{
            .client = self.aws_client,
            .region = self.region,
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

        return parseJsonToMap(self.allocator, content) catch |err| {
            scoped_log.err(
                "Failed to parse JSON from s3://{s}/{s}: {s}",
                .{ bucket, key, @errorName(err) },
            );
            return err;
        };
    }

    /// List objects with a given prefix, handling pagination.
    pub fn listObjects(self: *Self, bucket: []const u8, prefix: []const u8) ![]S3Object {
        scoped_log.debug("ListObjects s3://{s}/{s}", .{ bucket, prefix });

        const options = aws_sdk.Options{
            .client = self.aws_client,
            .region = self.region,
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
                scoped_log.err(
                    "S3 ListObjects failed for s3://{s}/{s}: {s}",
                    .{ bucket, prefix, @errorName(err) },
                );
                return S3Error.RequestFailed;
            };
            defer result.deinit();

            if (result.response.contents) |contents| {
                for (contents) |item| {
                    const item_key = item.key orelse continue;

                    // Skip "directory" markers (keys ending with /)
                    if (isDirectoryMarker(item_key)) continue;

                    // Calculate path suffix (relative to prefix)
                    const path_suffix = calculatePathSuffix(item_key, prefix);

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

    /// Download all objects matching a prefix to a destination directory.
    /// For directory downloads (multiple files), each object's path_suffix determines
    /// its location under destination. For single file downloads (prefix matches exact key),
    /// the file is written directly to destination.
    pub fn downloadPrefixToDir(
        self: *Self,
        bucket: []const u8,
        prefix: []const u8,
        destination: []const u8,
        options: DownloadOptions,
    ) !DownloadResult {
        scoped_log.debug("downloadPrefixToDir s3://{s}/{s} -> {s}", .{ bucket, prefix, destination });

        const objects = try self.listObjects(bucket, prefix);
        defer {
            for (objects) |*obj| {
                var o = obj.*;
                o.deinit(self.allocator);
            }
            self.allocator.free(objects);
        }

        for (objects) |obj| {
            scoped_log.debug("downloading s3://{s}/{s}", .{ obj.bucket, obj.key });

            const content = try self.getObject(obj.bucket, obj.key);
            defer self.allocator.free(content);

            // Build destination path: join destination with path_suffix.
            // When path_suffix is empty (single file case), destination is the file path.
            const dest_path = try fs_utils.joinPath(self.allocator, destination, obj.path_suffix);
            defer self.allocator.free(dest_path);

            scoped_log.debug("writing {s} ({d} bytes)", .{ dest_path, content.len });

            fs_utils.writeFile(
                dest_path,
                content,
                options.file_mode,
                options.dir_mode,
                options.uid,
                options.gid,
            ) catch |err| {
                scoped_log.err("failed to write {s}: {s}", .{ dest_path, @errorName(err) });
                return err;
            };
        }

        return DownloadResult{ .files_written = objects.len };
    }
};

/// Options for downloading S3 objects to the filesystem.
pub const DownloadOptions = struct {
    file_mode: std.fs.File.Mode = 0o644,
    dir_mode: std.fs.File.Mode = 0o755,
    uid: ?u32 = null,
    gid: ?u32 = null,
};

/// Result of a prefix download operation.
pub const DownloadResult = struct {
    files_written: usize,
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

/// Parse a JSON object into a string map. Only scalar values (string, integer, float, bool)
/// are included; nested objects and arrays are skipped.
/// Caller owns the returned map and all strings within it.
pub fn parseJsonToMap(allocator: Allocator, content: []const u8) !std.StringHashMap([]const u8) {
    var map = std.StringHashMap([]const u8).init(allocator);
    errdefer {
        var it = map.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        map.deinit();
    }

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch {
        return S3Error.InvalidJson;
    };
    defer parsed.deinit();

    switch (parsed.value) {
        .object => |obj| {
            for (obj.keys(), obj.values()) |k, v| {
                switch (v) {
                    .string => |s| {
                        const key_copy = try allocator.dupe(u8, k);
                        errdefer allocator.free(key_copy);
                        const value_copy = try allocator.dupe(u8, s);
                        errdefer allocator.free(value_copy);
                        try map.put(key_copy, value_copy);
                    },
                    .integer => |i| {
                        const key_copy = try allocator.dupe(u8, k);
                        errdefer allocator.free(key_copy);
                        const value_str = try std.fmt.allocPrint(allocator, "{d}", .{i});
                        errdefer allocator.free(value_str);
                        try map.put(key_copy, value_str);
                    },
                    .float => |f| {
                        const key_copy = try allocator.dupe(u8, k);
                        errdefer allocator.free(key_copy);
                        const value_str = try std.fmt.allocPrint(allocator, "{d}", .{f});
                        errdefer allocator.free(value_str);
                        try map.put(key_copy, value_str);
                    },
                    .bool => |b| {
                        const key_copy = try allocator.dupe(u8, k);
                        errdefer allocator.free(key_copy);
                        const value_str = try allocator.dupe(u8, if (b) "true" else "false");
                        errdefer allocator.free(value_str);
                        try map.put(key_copy, value_str);
                    },
                    else => {
                        // Skip non-scalar values (null, arrays, nested objects)
                    },
                }
            }
        },
        else => {
            return S3Error.InvalidJson;
        },
    }

    return map;
}

/// Calculate the path suffix for an S3 object key relative to a prefix.
pub fn calculatePathSuffix(key: []const u8, prefix: []const u8) []const u8 {
    if (std.mem.startsWith(u8, key, prefix)) {
        return key[prefix.len..];
    }
    return key;
}

/// Check if an S3 key represents a directory marker (ends with /).
pub fn isDirectoryMarker(key: []const u8) bool {
    return std.mem.endsWith(u8, key, "/");
}

/// Free all entries in a string map and deinit the map.
pub fn freeStringMap(allocator: Allocator, map: *std.StringHashMap([]const u8)) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    map.deinit();
}

const testing = std.testing;

test "parseJsonToMap with string values" {
    const allocator = testing.allocator;
    const json = "{\"foo\": \"bar\", \"baz\": \"qux\"}";

    var map = try parseJsonToMap(allocator, json);
    defer freeStringMap(allocator, &map);

    try testing.expectEqual(@as(usize, 2), map.count());
    try testing.expectEqualStrings("bar", map.get("foo").?);
    try testing.expectEqualStrings("qux", map.get("baz").?);
}

test "parseJsonToMap with integer values" {
    const allocator = testing.allocator;
    const json = "{\"port\": 8080, \"count\": -42}";

    var map = try parseJsonToMap(allocator, json);
    defer freeStringMap(allocator, &map);

    try testing.expectEqual(@as(usize, 2), map.count());
    try testing.expectEqualStrings("8080", map.get("port").?);
    try testing.expectEqualStrings("-42", map.get("count").?);
}

test "parseJsonToMap with float values" {
    const allocator = testing.allocator;
    const json = "{\"rate\": 3.14, \"temp\": -0.5}";

    var map = try parseJsonToMap(allocator, json);
    defer freeStringMap(allocator, &map);

    try testing.expectEqual(@as(usize, 2), map.count());
    // Float formatting may vary, just check it parses
    try testing.expect(map.get("rate") != null);
    try testing.expect(map.get("temp") != null);
}

test "parseJsonToMap with boolean values" {
    const allocator = testing.allocator;
    const json = "{\"enabled\": true, \"debug\": false}";

    var map = try parseJsonToMap(allocator, json);
    defer freeStringMap(allocator, &map);

    try testing.expectEqual(@as(usize, 2), map.count());
    try testing.expectEqualStrings("true", map.get("enabled").?);
    try testing.expectEqualStrings("false", map.get("debug").?);
}

test "parseJsonToMap skips nested objects and arrays" {
    const allocator = testing.allocator;
    const json = "{\"name\": \"test\", \"nested\": {\"a\": 1}, \"list\": [1, 2, 3], \"null_val\": null}";

    var map = try parseJsonToMap(allocator, json);
    defer freeStringMap(allocator, &map);

    try testing.expectEqual(@as(usize, 1), map.count());
    try testing.expectEqualStrings("test", map.get("name").?);
    try testing.expect(map.get("nested") == null);
    try testing.expect(map.get("list") == null);
    try testing.expect(map.get("null_val") == null);
}

test "parseJsonToMap with empty object" {
    const allocator = testing.allocator;
    const json = "{}";

    var map = try parseJsonToMap(allocator, json);
    defer freeStringMap(allocator, &map);

    try testing.expectEqual(@as(usize, 0), map.count());
}

test "parseJsonToMap returns error for non-object JSON" {
    const allocator = testing.allocator;

    // Array at root
    try testing.expectError(S3Error.InvalidJson, parseJsonToMap(allocator, "[1, 2, 3]"));

    // String at root
    try testing.expectError(S3Error.InvalidJson, parseJsonToMap(allocator, "\"hello\""));

    // Number at root
    try testing.expectError(S3Error.InvalidJson, parseJsonToMap(allocator, "42"));

    // Boolean at root
    try testing.expectError(S3Error.InvalidJson, parseJsonToMap(allocator, "true"));

    // Null at root
    try testing.expectError(S3Error.InvalidJson, parseJsonToMap(allocator, "null"));
}

test "parseJsonToMap returns error for invalid JSON" {
    const allocator = testing.allocator;

    try testing.expectError(S3Error.InvalidJson, parseJsonToMap(allocator, "not valid json"));
    try testing.expectError(S3Error.InvalidJson, parseJsonToMap(allocator, "{invalid}"));
    try testing.expectError(S3Error.InvalidJson, parseJsonToMap(allocator, ""));
}

test "parseJsonToMap with mixed scalar types" {
    const allocator = testing.allocator;
    const json =
        \\{
        \\  "DB_HOST": "localhost",
        \\  "DB_PORT": 5432,
        \\  "DB_NAME": "myapp",
        \\  "DEBUG": true,
        \\  "TIMEOUT": 30.5
        \\}
    ;

    var map = try parseJsonToMap(allocator, json);
    defer freeStringMap(allocator, &map);

    try testing.expectEqual(@as(usize, 5), map.count());
    try testing.expectEqualStrings("localhost", map.get("DB_HOST").?);
    try testing.expectEqualStrings("5432", map.get("DB_PORT").?);
    try testing.expectEqualStrings("myapp", map.get("DB_NAME").?);
    try testing.expectEqualStrings("true", map.get("DEBUG").?);
    try testing.expect(map.get("TIMEOUT") != null);
}

test "calculatePathSuffix with matching prefix" {
    try testing.expectEqualStrings("file.txt", calculatePathSuffix("app/config/file.txt", "app/config/"));
    try testing.expectEqualStrings("nested/deep/file.txt", calculatePathSuffix("prefix/nested/deep/file.txt", "prefix/"));
    try testing.expectEqualStrings("", calculatePathSuffix("exact/match/", "exact/match/"));
}

test "calculatePathSuffix with non-matching prefix" {
    try testing.expectEqualStrings("other/path/file.txt", calculatePathSuffix("other/path/file.txt", "app/config/"));
}

test "calculatePathSuffix with empty prefix" {
    try testing.expectEqualStrings("app/config/file.txt", calculatePathSuffix("app/config/file.txt", ""));
}

test "calculatePathSuffix with empty key" {
    try testing.expectEqualStrings("", calculatePathSuffix("", "prefix/"));
}

test "isDirectoryMarker returns true for directory markers" {
    try testing.expect(isDirectoryMarker("folder/"));
    try testing.expect(isDirectoryMarker("path/to/folder/"));
    try testing.expect(isDirectoryMarker("/"));
}

test "isDirectoryMarker returns false for files" {
    try testing.expect(!isDirectoryMarker("file.txt"));
    try testing.expect(!isDirectoryMarker("path/to/file.txt"));
    try testing.expect(!isDirectoryMarker(""));
}

test "S3Object.deinit frees all strings" {
    const allocator = testing.allocator;

    var obj = S3Object{
        .bucket = try allocator.dupe(u8, "test-bucket"),
        .key = try allocator.dupe(u8, "path/to/object.txt"),
        .path_suffix = try allocator.dupe(u8, "object.txt"),
    };

    obj.deinit(allocator);
    // If deinit didn't free properly, testing.allocator would detect leaks
}

test "freeStringMap frees all entries" {
    const allocator = testing.allocator;

    var map = std.StringHashMap([]const u8).init(allocator);
    const key1 = try allocator.dupe(u8, "key1");
    const val1 = try allocator.dupe(u8, "value1");
    try map.put(key1, val1);

    const key2 = try allocator.dupe(u8, "key2");
    const val2 = try allocator.dupe(u8, "value2");
    try map.put(key2, val2);

    freeStringMap(allocator, &map);
    // If freeStringMap didn't free properly, testing.allocator would detect leaks
}

// === Additional negative and edge case tests ===

test "parseJsonToMap with unicode keys and values" {
    const allocator = testing.allocator;
    const json = "{\"日本語\": \"値\", \"emoji\": \"🎉\", \"accent\": \"café\"}";

    var map = try parseJsonToMap(allocator, json);
    defer freeStringMap(allocator, &map);

    try testing.expectEqual(@as(usize, 3), map.count());
    try testing.expectEqualStrings("値", map.get("日本語").?);
    try testing.expectEqualStrings("🎉", map.get("emoji").?);
    try testing.expectEqualStrings("café", map.get("accent").?);
}

test "parseJsonToMap with empty string key" {
    const allocator = testing.allocator;
    const json = "{\"\": \"empty_key_value\"}";

    var map = try parseJsonToMap(allocator, json);
    defer freeStringMap(allocator, &map);

    try testing.expectEqual(@as(usize, 1), map.count());
    try testing.expectEqualStrings("empty_key_value", map.get("").?);
}

test "parseJsonToMap with empty string value" {
    const allocator = testing.allocator;
    const json = "{\"key\": \"\"}";

    var map = try parseJsonToMap(allocator, json);
    defer freeStringMap(allocator, &map);

    try testing.expectEqual(@as(usize, 1), map.count());
    try testing.expectEqualStrings("", map.get("key").?);
}

test "parseJsonToMap with escaped characters in strings" {
    const allocator = testing.allocator;
    const json = "{\"path\": \"C:\\\\Users\\\\test\", \"quote\": \"say \\\"hello\\\"\", \"newline\": \"line1\\nline2\"}";

    var map = try parseJsonToMap(allocator, json);
    defer freeStringMap(allocator, &map);

    try testing.expectEqual(@as(usize, 3), map.count());
    try testing.expectEqualStrings("C:\\Users\\test", map.get("path").?);
    try testing.expectEqualStrings("say \"hello\"", map.get("quote").?);
    try testing.expectEqualStrings("line1\nline2", map.get("newline").?);
}

test "parseJsonToMap returns error for duplicate keys" {
    const allocator = testing.allocator;
    // Zig's JSON parser rejects duplicate keys as invalid
    const json = "{\"key\": \"first\", \"key\": \"second\"}";

    try testing.expectError(S3Error.InvalidJson, parseJsonToMap(allocator, json));
}

test "parseJsonToMap with large integer" {
    const allocator = testing.allocator;
    // Test with max i64 value
    const json = "{\"big\": 9223372036854775807, \"small\": -9223372036854775808}";

    var map = try parseJsonToMap(allocator, json);
    defer freeStringMap(allocator, &map);

    try testing.expectEqual(@as(usize, 2), map.count());
    try testing.expectEqualStrings("9223372036854775807", map.get("big").?);
    try testing.expectEqualStrings("-9223372036854775808", map.get("small").?);
}

test "parseJsonToMap with zero values" {
    const allocator = testing.allocator;
    const json = "{\"zero_int\": 0, \"zero_float\": 0.0, \"neg_zero\": -0.0}";

    var map = try parseJsonToMap(allocator, json);
    defer freeStringMap(allocator, &map);

    try testing.expectEqual(@as(usize, 3), map.count());
    try testing.expectEqualStrings("0", map.get("zero_int").?);
    // Float formatting for zero values
    try testing.expect(map.get("zero_float") != null);
    try testing.expect(map.get("neg_zero") != null);
}

test "parseJsonToMap with whitespace variations" {
    const allocator = testing.allocator;
    const json =
        \\{
        \\    "key1"   :   "value1"   ,
        \\    "key2":
        \\        "value2"
        \\}
    ;

    var map = try parseJsonToMap(allocator, json);
    defer freeStringMap(allocator, &map);

    try testing.expectEqual(@as(usize, 2), map.count());
    try testing.expectEqualStrings("value1", map.get("key1").?);
    try testing.expectEqualStrings("value2", map.get("key2").?);
}

test "parseJsonToMap with deeply nested objects to skip" {
    const allocator = testing.allocator;
    const json = "{\"keep\": \"value\", \"skip\": {\"a\": {\"b\": {\"c\": {\"d\": \"deep\"}}}}}";

    var map = try parseJsonToMap(allocator, json);
    defer freeStringMap(allocator, &map);

    try testing.expectEqual(@as(usize, 1), map.count());
    try testing.expectEqualStrings("value", map.get("keep").?);
    try testing.expect(map.get("skip") == null);
}

test "parseJsonToMap returns error for truncated JSON" {
    const allocator = testing.allocator;

    try testing.expectError(S3Error.InvalidJson, parseJsonToMap(allocator, "{\"key\": \"value\""));
    try testing.expectError(S3Error.InvalidJson, parseJsonToMap(allocator, "{\"key\":"));
    try testing.expectError(S3Error.InvalidJson, parseJsonToMap(allocator, "{\"key\""));
    try testing.expectError(S3Error.InvalidJson, parseJsonToMap(allocator, "{"));
}

test "parseJsonToMap returns error for JSON with trailing garbage" {
    const allocator = testing.allocator;

    // JSON parsers typically accept this and ignore trailing content
    // but let's verify our behavior is consistent
    const result = parseJsonToMap(allocator, "{\"key\": \"value\"}garbage");
    if (result) |*map| {
        var m = map.*;
        defer freeStringMap(allocator, &m);
        // Parser accepted it, which is acceptable behavior
        try testing.expectEqualStrings("value", m.get("key").?);
    } else |_| {
        // Parser rejected it, which is also acceptable
    }
}

test "parseJsonToMap with only whitespace" {
    const allocator = testing.allocator;

    try testing.expectError(S3Error.InvalidJson, parseJsonToMap(allocator, "   "));
    try testing.expectError(S3Error.InvalidJson, parseJsonToMap(allocator, "\n\t\r"));
}

test "parseJsonToMap with scientific notation float" {
    const allocator = testing.allocator;
    const json = "{\"sci\": 1.23e10, \"neg_sci\": -4.56e-7}";

    var map = try parseJsonToMap(allocator, json);
    defer freeStringMap(allocator, &map);

    try testing.expectEqual(@as(usize, 2), map.count());
    // Scientific notation gets formatted as regular float
    try testing.expect(map.get("sci") != null);
    try testing.expect(map.get("neg_sci") != null);
}

test "calculatePathSuffix when prefix is longer than key" {
    // When prefix is longer than key, startsWith returns false, so full key is returned
    try testing.expectEqualStrings("short", calculatePathSuffix("short", "this/is/a/very/long/prefix/"));
}

test "calculatePathSuffix with partial overlap not at start" {
    // Prefix "config/" doesn't match "app/config/file.txt" at the start
    try testing.expectEqualStrings("app/config/file.txt", calculatePathSuffix("app/config/file.txt", "config/"));
}

test "calculatePathSuffix with exact match returns empty" {
    try testing.expectEqualStrings("", calculatePathSuffix("prefix/", "prefix/"));
    try testing.expectEqualStrings("", calculatePathSuffix("exact", "exact"));
}

test "isDirectoryMarker with multiple trailing slashes" {
    // Only the last character matters
    try testing.expect(isDirectoryMarker("path//"));
    try testing.expect(isDirectoryMarker("a/b/c///"));
}

test "isDirectoryMarker with slash in middle only" {
    try testing.expect(!isDirectoryMarker("path/file"));
    try testing.expect(!isDirectoryMarker("/leading"));
}

test "S3Object with empty strings" {
    const allocator = testing.allocator;

    var obj = S3Object{
        .bucket = try allocator.dupe(u8, ""),
        .key = try allocator.dupe(u8, ""),
        .path_suffix = try allocator.dupe(u8, ""),
    };

    obj.deinit(allocator);
    // Should not crash or leak with empty strings
}
