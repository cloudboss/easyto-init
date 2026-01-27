//! Minimal YAML parser for easyto user data.
//!
//! This parser handles a subset of YAML sufficient for parsing user data:
//! - Key-value pairs
//! - Lists of strings
//! - Lists of objects with name/value fields
//! - Simple nested objects
//! - Multiline strings (literal block scalar with |)

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

pub const ParseError = error{
    InvalidYaml,
    UnexpectedIndent,
    InvalidKey,
    OutOfMemory,
};

/// Result of parsing YAML, including ownership tracking.
pub const ParseResult = struct {
    value: Value,
    owned_strings: std.ArrayListUnmanaged([]const u8),
    allocator: Allocator,

    pub fn deinit(self: *ParseResult) void {
        // Free owned strings (from block scalars)
        for (self.owned_strings.items) |s| {
            self.allocator.free(s);
        }
        self.owned_strings.deinit(self.allocator);
        // Free Value structure
        self.value.deinit(self.allocator);
    }
};

pub const Value = union(enum) {
    string: []const u8,
    list: []const Value,
    map: []const MapEntry,

    pub fn getString(self: Value) ?[]const u8 {
        return switch (self) {
            .string => |s| s,
            else => null,
        };
    }

    pub fn getList(self: Value) ?[]const Value {
        return switch (self) {
            .list => |l| l,
            else => null,
        };
    }

    pub fn getMap(self: Value) ?[]const MapEntry {
        return switch (self) {
            .map => |m| m,
            else => null,
        };
    }

    pub fn get(self: Value, key: []const u8) ?Value {
        const map = self.getMap() orelse return null;
        for (map) |entry| {
            if (std.mem.eql(u8, entry.key, key)) {
                return entry.value;
            }
        }
        return null;
    }

    /// Free allocated memory. Note: strings are not freed as they may be
    /// slices of the original input. Only list/map structures are freed.
    pub fn deinit(self: Value, allocator: Allocator) void {
        switch (self) {
            .string => {},
            .list => |list| {
                for (list) |item| {
                    item.deinit(allocator);
                }
                allocator.free(list);
            },
            .map => |map| {
                for (map) |entry| {
                    entry.value.deinit(allocator);
                }
                allocator.free(map);
            },
        }
    }
};

pub const MapEntry = struct {
    key: []const u8,
    value: Value,
};

const Line = struct {
    indent: usize,
    content: []const u8,
    is_list_item: bool,
    key: ?[]const u8,
    value: ?[]const u8,
    is_block_scalar: bool,
};

pub fn parse(allocator: Allocator, content: []const u8) !ParseResult {
    var owned_strings: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (owned_strings.items) |s| allocator.free(s);
        owned_strings.deinit(allocator);
    }

    if (content.len == 0) {
        return ParseResult{
            .value = Value{ .map = &.{} },
            .owned_strings = owned_strings,
            .allocator = allocator,
        };
    }

    var lines = ArrayList(Line){};
    defer lines.deinit(allocator);

    // Parse lines
    var line_iter = std.mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |line| {
        const parsed_line = parseLine(line);
        if (parsed_line.content.len > 0 or parsed_line.is_block_scalar) {
            try lines.append(allocator, parsed_line);
        }
    }

    const value = try parseValue(allocator, lines.items, 0, 0, &owned_strings);
    return ParseResult{
        .value = value,
        .owned_strings = owned_strings,
        .allocator = allocator,
    };
}

fn stripInlineComment(s: []const u8) []const u8 {
    // Strip inline comments: " #" followed by comment text
    if (std.mem.indexOf(u8, s, " #")) |pos| {
        return std.mem.trim(u8, s[0..pos], " \t\r");
    }
    return s;
}

fn parseLine(line: []const u8) Line {
    var indent: usize = 0;
    while (indent < line.len and line[indent] == ' ') {
        indent += 1;
    }

    const rest = if (indent < line.len) line[indent..] else "";

    // Check for list item
    const is_list_item = rest.len >= 2 and rest[0] == '-' and rest[1] == ' ';
    const content = if (is_list_item) rest[2..] else rest;

    // Check for key: value
    var key: ?[]const u8 = null;
    var value: ?[]const u8 = null;
    var is_block_scalar = false;

    if (std.mem.indexOf(u8, content, ": ")) |colon_pos| {
        key = content[0..colon_pos];
        const raw_value = std.mem.trim(u8, content[colon_pos + 2 ..], " \t\r");
        if (raw_value.len == 0) {
            value = null;
        } else {
            value = stripInlineComment(raw_value);
            if (value.?.len == 0) value = null;
        }
    } else if (content.len > 0 and content[content.len - 1] == ':') {
        key = content[0 .. content.len - 1];
        value = null;
    } else if (std.mem.eql(u8, std.mem.trim(u8, content, " \t\r"), "|")) {
        is_block_scalar = true;
    }

    return Line{
        .indent = indent,
        .content = content,
        .is_list_item = is_list_item,
        .key = key,
        .value = value,
        .is_block_scalar = is_block_scalar,
    };
}

fn isCommentLine(line: Line) bool {
    return line.key == null and
        !line.is_list_item and
        !line.is_block_scalar and
        line.content.len > 0 and
        line.content[0] == '#';
}

fn parseValue(allocator: Allocator, lines: []const Line, start: usize, base_indent: usize, owned_strings: *std.ArrayListUnmanaged([]const u8)) ParseError!Value {
    // Skip comment lines at the structural level
    var actual_start = start;
    while (actual_start < lines.len) {
        const line = lines[actual_start];
        if (line.indent < base_indent) break;
        if (isCommentLine(line)) {
            actual_start += 1;
            continue;
        }
        break;
    }

    if (actual_start >= lines.len) {
        return Value{ .string = "" };
    }

    const first = lines[actual_start];

    // Check if this is a list
    if (first.is_list_item) {
        return parseList(allocator, lines, actual_start, base_indent, owned_strings);
    }

    // Check if this is a map
    if (first.key != null) {
        return parseMap(allocator, lines, actual_start, base_indent, owned_strings);
    }

    // Check for block scalar
    if (first.is_block_scalar) {
        return parseBlockScalar(allocator, lines, actual_start, base_indent, owned_strings);
    }

    // Simple string value
    return Value{ .string = std.mem.trim(u8, first.content, " \t\r\"'") };
}

fn parseList(allocator: Allocator, lines: []const Line, start: usize, base_indent: usize, owned_strings: *std.ArrayListUnmanaged([]const u8)) ParseError!Value {
    var items = ArrayList(Value){};
    errdefer items.deinit(allocator);

    var i = start;
    while (i < lines.len) {
        const line = lines[i];
        if (line.indent < base_indent) break;
        // Skip comment lines
        if (isCommentLine(line)) {
            i += 1;
            continue;
        }
        if (line.indent == base_indent and !line.is_list_item) break;

        if (line.is_list_item and line.indent == base_indent) {
            // Parse the list item value
            if (line.key != null) {
                // Inline map: - key: value
                var map_items = ArrayList(MapEntry){};
                errdefer map_items.deinit(allocator);

                // Add the inline key-value
                const nested_value = if (line.value) |v|
                    Value{ .string = std.mem.trim(u8, v, " \t\r\"'") }
                else
                    try parseValue(allocator, lines, i + 1, line.indent + 2, owned_strings);

                try map_items.append(allocator, .{
                    .key = line.key.?,
                    .value = nested_value,
                });

                // Only check for sibling keys at same level when we had an inline value.
                // When line.value is null, parseValue already consumed the nested content.
                var j = i + 1;
                if (line.value != null) {
                    // Check for more keys at deeper indent (same level as the inline value)
                    while (j < lines.len and lines[j].indent > base_indent and !lines[j].is_list_item) {
                        if (lines[j].key) |k| {
                            try map_items.append(allocator, .{
                                .key = k,
                                .value = if (lines[j].value) |v|
                                    Value{ .string = std.mem.trim(u8, v, " \t\r\"'") }
                                else
                                    try parseValue(allocator, lines, j + 1, lines[j].indent + 2, owned_strings),
                            });
                        }
                        j += 1;
                    }
                } else {
                    // Skip past all nested content (parseValue consumed it)
                    while (j < lines.len and lines[j].indent > base_indent and !lines[j].is_list_item) {
                        j += 1;
                    }
                }
                i = j;

                try items.append(allocator, Value{ .map = try map_items.toOwnedSlice(allocator) });
            } else if (line.content.len > 0) {
                // Check if this is a block scalar indicator
                const trimmed_content = std.mem.trim(u8, line.content, " \t\r");
                if (std.mem.eql(u8, trimmed_content, "|")) {
                    // Block scalar in list item: - |
                    const block_value = try parseBlockScalarFromList(allocator, lines, i, base_indent, owned_strings);
                    try items.append(allocator, block_value.value);
                    i = block_value.next_index;
                } else {
                    // Simple value: - value
                    try items.append(allocator, Value{ .string = std.mem.trim(u8, line.content, " \t\r\"'") });
                    i += 1;
                }
            } else {
                i += 1;
            }
        } else {
            i += 1;
        }
    }

    return Value{ .list = try items.toOwnedSlice(allocator) };
}

fn parseMap(allocator: Allocator, lines: []const Line, start: usize, base_indent: usize, owned_strings: *std.ArrayListUnmanaged([]const u8)) ParseError!Value {
    var entries = ArrayList(MapEntry){};
    errdefer entries.deinit(allocator);

    // Use the actual indent of the first line as the map's working indent.
    // This handles cases where the map is more deeply indented than base_indent.
    const map_indent = if (start < lines.len) lines[start].indent else base_indent;

    var i = start;
    while (i < lines.len) {
        const line = lines[i];
        if (line.indent < base_indent) break;

        if (line.key) |key| {
            if (line.indent == map_indent) {
                const val = if (line.value) |v| blk: {
                    // Check for block scalar indicator
                    if (std.mem.eql(u8, std.mem.trim(u8, v, " \t\r"), "|")) {
                        break :blk try parseBlockScalar(allocator, lines, i, map_indent, owned_strings);
                    }
                    break :blk Value{ .string = std.mem.trim(u8, v, " \t\r\"'") };
                } else blk: {
                    // Value is on subsequent lines
                    break :blk try parseValue(allocator, lines, i + 1, line.indent + 2, owned_strings);
                };

                try entries.append(allocator, .{ .key = key, .value = val });

                // Skip to next key at same indent
                i += 1;
                if (line.value == null or std.mem.eql(u8, std.mem.trim(u8, line.value.?, " \t\r"), "|")) {
                    while (i < lines.len and lines[i].indent > map_indent) {
                        i += 1;
                    }
                }
            } else {
                i += 1;
            }
        } else {
            i += 1;
        }
    }

    return Value{ .map = try entries.toOwnedSlice(allocator) };
}

const BlockScalarResult = struct {
    value: Value,
    next_index: usize,
};

fn parseBlockScalarFromList(allocator: Allocator, lines: []const Line, start: usize, list_indent: usize, owned_strings: *std.ArrayListUnmanaged([]const u8)) ParseError!BlockScalarResult {
    var content = ArrayList(u8){};
    errdefer content.deinit(allocator);

    // The content indent is determined by the first non-empty line after the `|`
    var content_indent: ?usize = null;
    var i = start + 1;

    while (i < lines.len) {
        const line = lines[i];

        // Check if we've hit another list item at same or lesser indent
        if (line.is_list_item and line.indent <= list_indent) {
            break;
        }

        // Check if we've hit a key at same or lesser indent
        if (line.key != null and line.indent <= list_indent) {
            break;
        }

        // Empty line within block
        if (line.content.len == 0) {
            if (content_indent != null) {
                try content.append(allocator, '\n');
            }
            i += 1;
            continue;
        }

        // Determine content indent from first non-empty line
        if (content_indent == null) {
            content_indent = line.indent;
        }

        // Check if we've exited the block (dedented)
        if (line.indent < content_indent.?) {
            break;
        }

        // Add the content (preserving indentation beyond the base)
        if (content.items.len > 0) {
            try content.append(allocator, '\n');
        }
        // Add any extra indentation beyond content_indent
        const extra_indent = line.indent - content_indent.?;
        var j: usize = 0;
        while (j < extra_indent) : (j += 1) {
            try content.append(allocator, ' ');
        }
        try content.appendSlice(allocator, line.content);
        i += 1;
    }

    // Register the allocated string for cleanup
    const str = try content.toOwnedSlice(allocator);
    try owned_strings.append(allocator, str);

    return BlockScalarResult{
        .value = Value{ .string = str },
        .next_index = i,
    };
}

fn parseBlockScalar(allocator: Allocator, lines: []const Line, start: usize, base_indent: usize, owned_strings: *std.ArrayListUnmanaged([]const u8)) ParseError!Value {
    _ = base_indent;
    var content = ArrayList(u8){};
    errdefer content.deinit(allocator);

    // Find the indent of the block content
    var content_indent: ?usize = null;
    var i = start + 1;

    while (i < lines.len) {
        const line = lines[i];

        // Empty line within block
        if (line.content.len == 0) {
            try content.append(allocator, '\n');
            i += 1;
            continue;
        }

        // Determine content indent from first non-empty line
        if (content_indent == null) {
            content_indent = line.indent;
        }

        // Check if we've exited the block
        if (line.indent < content_indent.?) {
            break;
        }

        // Add the content
        if (content.items.len > 0) {
            try content.append(allocator, '\n');
        }
        try content.appendSlice(allocator, line.content);
        i += 1;
    }

    // Register the allocated string for cleanup
    const str = try content.toOwnedSlice(allocator);
    try owned_strings.append(allocator, str);

    return Value{ .string = str };
}

test "parse simple key-value" {
    const input = "name: hello";
    var result = try parse(std.testing.allocator, input);
    defer result.deinit();
    const name = result.value.get("name").?.getString().?;
    try std.testing.expectEqualStrings("hello", name);
}

test "parse list of strings" {
    const input =
        \\items:
        \\  - one
        \\  - two
        \\  - three
    ;
    var result = try parse(std.testing.allocator, input);
    defer result.deinit();
    const items = result.value.get("items").?.getList().?;
    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqualStrings("one", items[0].getString().?);
}

test "parse empty input" {
    var result = try parse(std.testing.allocator, "");
    defer result.deinit();
    try std.testing.expect(result.value.getMap() != null);
}

test "parse block scalar with shebang" {
    const input =
        \\init-scripts:
        \\  - |
        \\    #!/bin/sh
        \\    echo hello
    ;
    var result = try parse(std.testing.allocator, input);
    defer result.deinit();
    const scripts = result.value.get("init-scripts").?.getList().?;
    try std.testing.expectEqual(@as(usize, 1), scripts.len);
    const script = scripts[0].getString().?;
    try std.testing.expect(std.mem.startsWith(u8, script, "#!/bin/sh"));
}

test "comments are ignored" {
    const input =
        \\# This is a comment
        \\name: hello
        \\# Another comment
        \\value: world
    ;
    var result = try parse(std.testing.allocator, input);
    defer result.deinit();
    try std.testing.expectEqualStrings("hello", result.value.get("name").?.getString().?);
    try std.testing.expectEqualStrings("world", result.value.get("value").?.getString().?);
}

test "inline comments are stripped" {
    const input = "name: hello  # this is a comment";
    var result = try parse(std.testing.allocator, input);
    defer result.deinit();
    try std.testing.expectEqualStrings("hello", result.value.get("name").?.getString().?);
}
