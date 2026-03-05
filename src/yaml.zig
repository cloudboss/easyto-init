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

fn parseFlowSequence(
    allocator: Allocator,
    input: []const u8,
    owned_strings: *std.ArrayListUnmanaged([]const u8),
) ParseError!Value {
    // Strip outer brackets
    const inner = std.mem.trim(u8, input[1 .. input.len - 1], " \t");
    if (inner.len == 0) {
        const items = try allocator.alloc(Value, 0);
        return Value{ .list = items };
    }

    var items = ArrayList(Value){};
    errdefer items.deinit(allocator);

    var it = std.mem.splitScalar(u8, inner, ',');
    while (it.next()) |raw_item| {
        const item = std.mem.trim(u8, raw_item, " \t\r\"'");
        if (item.len > 0) {
            const duped = try allocator.dupe(u8, item);
            try owned_strings.append(allocator, duped);
            try items.append(allocator, Value{ .string = duped });
        }
    }

    return Value{ .list = try items.toOwnedSlice(allocator) };
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

    // Check for comment line FIRST - comments can contain colons
    // A comment line starts with # (after optional indentation and list marker)
    const is_comment = content.len > 0 and content[0] == '#';

    if (!is_comment) {
        if (std.mem.indexOf(u8, content, ": ")) |colon_pos| {
            key = std.mem.trim(u8, content[0..colon_pos], "\"'");
            const raw_value = std.mem.trim(u8, content[colon_pos + 2 ..], " \t\r");
            if (raw_value.len == 0) {
                value = null;
            } else {
                value = stripInlineComment(raw_value);
                if (value.?.len == 0) value = null;
            }
        } else if (content.len > 0 and content[content.len - 1] == ':') {
            key = std.mem.trim(u8, content[0 .. content.len - 1], "\"'");
            value = null;
        } else if (std.mem.eql(u8, std.mem.trim(u8, content, " \t\r"), "|")) {
            is_block_scalar = true;
        }
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

fn parseValue(
    allocator: Allocator,
    lines: []const Line,
    start: usize,
    base_indent: usize,
    owned_strings: *std.ArrayListUnmanaged([]const u8),
) ParseError!Value {
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

fn parseList(
    allocator: Allocator,
    lines: []const Line,
    start: usize,
    base_indent: usize,
    owned_strings: *std.ArrayListUnmanaged([]const u8),
) ParseError!Value {
    var items = ArrayList(Value){};
    errdefer {
        for (items.items) |item| {
            item.deinit(allocator);
        }
        items.deinit(allocator);
    }

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
                errdefer {
                    for (map_items.items) |entry| {
                        entry.value.deinit(allocator);
                    }
                    map_items.deinit(allocator);
                }

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

fn parseMap(
    allocator: Allocator,
    lines: []const Line,
    start: usize,
    base_indent: usize,
    owned_strings: *std.ArrayListUnmanaged([]const u8),
) ParseError!Value {
    var entries = ArrayList(MapEntry){};
    errdefer {
        for (entries.items) |entry| {
            entry.value.deinit(allocator);
        }
        entries.deinit(allocator);
    }

    // Use the actual indent of the first line as the map's working indent.
    // This handles cases where the map is more deeply indented than base_indent.
    const map_indent = if (start < lines.len) lines[start].indent else base_indent;

    var i = start;
    while (i < lines.len) {
        const line = lines[i];
        if (line.indent < base_indent) break;

        if (line.key) |key| {
            if (line.indent == map_indent) {
                // Check for list at same indent as key (YAML allows this)
                if (line.value == null and i + 1 < lines.len and
                    lines[i + 1].is_list_item and lines[i + 1].indent == map_indent)
                {
                    const val = try parseList(allocator, lines, i + 1, map_indent, owned_strings);
                    try entries.append(allocator, .{ .key = key, .value = val });
                    i += 1;
                    while (i < lines.len) {
                        if (lines[i].indent < map_indent) break;
                        if (lines[i].indent == map_indent and !lines[i].is_list_item) break;
                        i += 1;
                    }
                } else {
                    const val = if (line.value) |v| blk: {
                        // Check for block scalar indicator
                        if (std.mem.eql(u8, std.mem.trim(u8, v, " \t\r"), "|")) {
                            break :blk try parseBlockScalar(allocator, lines, i, map_indent, owned_strings);
                        }
                        const trimmed = std.mem.trim(u8, v, " \t\r");
                        // Check for flow sequence [...]
                        if (trimmed.len >= 2 and trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
                            break :blk try parseFlowSequence(allocator, trimmed, owned_strings);
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

fn parseBlockScalarFromList(
    allocator: Allocator,
    lines: []const Line,
    start: usize,
    list_indent: usize,
    owned_strings: *std.ArrayListUnmanaged([]const u8),
) ParseError!BlockScalarResult {
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

fn parseBlockScalar(
    allocator: Allocator,
    lines: []const Line,
    start: usize,
    base_indent: usize,
    owned_strings: *std.ArrayListUnmanaged([]const u8),
) ParseError!Value {
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

test "Value.getString returns null for non-string" {
    const input = "items:\n  - one\n  - two";
    var result = try parse(std.testing.allocator, input);
    defer result.deinit();
    const items = result.value.get("items").?;
    try std.testing.expect(items.getString() == null);
    try std.testing.expect(items.getList() != null);
}

test "Value.getList returns null for string" {
    const input = "name: hello";
    var result = try parse(std.testing.allocator, input);
    defer result.deinit();
    const name = result.value.get("name").?;
    try std.testing.expect(name.getList() == null);
    try std.testing.expect(name.getString() != null);
}

test "Value.getMap returns null for string" {
    const input = "name: hello";
    var result = try parse(std.testing.allocator, input);
    defer result.deinit();
    const name = result.value.get("name").?;
    try std.testing.expect(name.getMap() == null);
}

test "Value.getMap returns null for list" {
    const input = "items:\n  - one";
    var result = try parse(std.testing.allocator, input);
    defer result.deinit();
    const items = result.value.get("items").?;
    try std.testing.expect(items.getMap() == null);
}

test "Value.get returns null for non-existent key" {
    const input = "name: hello";
    var result = try parse(std.testing.allocator, input);
    defer result.deinit();
    try std.testing.expect(result.value.get("missing") == null);
}

test "Value.get returns null on non-map value" {
    const input = "items:\n  - one";
    var result = try parse(std.testing.allocator, input);
    defer result.deinit();
    const items = result.value.get("items").?;
    try std.testing.expect(items.get("key") == null);
}

test "parse content with only comments" {
    const input =
        \\# This is a comment
        \\# Another comment
    ;
    var result = try parse(std.testing.allocator, input);
    defer result.deinit();
    // Comment-only content is parsed as empty string value
    const str = result.value.getString();
    try std.testing.expect(str != null);
    try std.testing.expectEqualStrings("", str.?);
}

test "parse nested maps" {
    const input =
        \\outer:
        \\  middle:
        \\    inner: value
    ;
    var result = try parse(std.testing.allocator, input);
    defer result.deinit();
    const outer = result.value.get("outer").?;
    const middle = outer.get("middle").?;
    const inner = middle.get("inner").?.getString().?;
    try std.testing.expectEqualStrings("value", inner);
}

test "parse deeply nested maps" {
    const input =
        \\level1:
        \\  level2:
        \\    level3:
        \\      level4: deep
    ;
    var result = try parse(std.testing.allocator, input);
    defer result.deinit();
    const l1 = result.value.get("level1").?;
    const l2 = l1.get("level2").?;
    const l3 = l2.get("level3").?;
    const l4 = l3.get("level4").?.getString().?;
    try std.testing.expectEqualStrings("deep", l4);
}

test "parse value containing hash without space" {
    const input = "color: #ff0000";
    var result = try parse(std.testing.allocator, input);
    defer result.deinit();
    try std.testing.expectEqualStrings("#ff0000", result.value.get("color").?.getString().?);
}

test "parse empty list item skipped" {
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
    try std.testing.expectEqualStrings("two", items[1].getString().?);
    try std.testing.expectEqualStrings("three", items[2].getString().?);
}

test "parse key with trailing colon only" {
    const input =
        \\parent:
        \\  child: value
    ;
    var result = try parse(std.testing.allocator, input);
    defer result.deinit();
    const parent = result.value.get("parent").?;
    const child = parent.get("child").?.getString().?;
    try std.testing.expectEqualStrings("value", child);
}

test "parse block scalar preserves internal indentation" {
    const input =
        \\script: |
        \\  line1
        \\    indented
        \\  line2
    ;
    var result = try parse(std.testing.allocator, input);
    defer result.deinit();
    const script = result.value.get("script").?.getString().?;
    try std.testing.expect(std.mem.indexOf(u8, script, "line1") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "indented") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "line2") != null);
}

test "parse empty block scalar" {
    const input =
        \\scripts:
        \\  - |
        \\next: value
    ;
    var result = try parse(std.testing.allocator, input);
    defer result.deinit();
    const scripts = result.value.get("scripts").?.getList().?;
    try std.testing.expectEqual(@as(usize, 1), scripts.len);
    try std.testing.expectEqualStrings("", scripts[0].getString().?);
    try std.testing.expectEqualStrings("value", result.value.get("next").?.getString().?);
}

test "parse quoted strings with double quotes" {
    const input = "name: \"hello world\"";
    var result = try parse(std.testing.allocator, input);
    defer result.deinit();
    try std.testing.expectEqualStrings("hello world", result.value.get("name").?.getString().?);
}

test "parse quoted strings with single quotes" {
    const input = "name: 'hello world'";
    var result = try parse(std.testing.allocator, input);
    defer result.deinit();
    try std.testing.expectEqualStrings("hello world", result.value.get("name").?.getString().?);
}

test "parse multiple keys at same level" {
    const input =
        \\first: one
        \\second: two
        \\third: three
    ;
    var result = try parse(std.testing.allocator, input);
    defer result.deinit();
    try std.testing.expectEqualStrings("one", result.value.get("first").?.getString().?);
    try std.testing.expectEqualStrings("two", result.value.get("second").?.getString().?);
    try std.testing.expectEqualStrings("three", result.value.get("third").?.getString().?);
}

test "parse list of maps" {
    const input =
        \\items:
        \\  - name: foo
        \\    value: bar
        \\  - name: baz
        \\    value: qux
    ;
    var result = try parse(std.testing.allocator, input);
    defer result.deinit();
    const items = result.value.get("items").?.getList().?;
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("foo", items[0].get("name").?.getString().?);
    try std.testing.expectEqualStrings("bar", items[0].get("value").?.getString().?);
    try std.testing.expectEqualStrings("baz", items[1].get("name").?.getString().?);
    try std.testing.expectEqualStrings("qux", items[1].get("value").?.getString().?);
}

test "parse block scalar multiple lines" {
    const input =
        \\script: |
        \\  #!/bin/bash
        \\  echo "hello"
        \\  echo "world"
    ;
    var result = try parse(std.testing.allocator, input);
    defer result.deinit();
    const script = result.value.get("script").?.getString().?;
    try std.testing.expect(std.mem.startsWith(u8, script, "#!/bin/bash"));
    try std.testing.expect(std.mem.indexOf(u8, script, "echo \"hello\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "echo \"world\"") != null);
}

test "parse whitespace-only lines returns empty string" {
    const input = "   \n   \n   ";
    var result = try parse(std.testing.allocator, input);
    defer result.deinit();
    // Whitespace-only lines (with no keys/values) result in empty string
    const str = result.value.getString();
    try std.testing.expect(str != null);
    try std.testing.expectEqualStrings("", str.?);
}

test "Value.deinit handles nested structures" {
    const allocator = std.testing.allocator;
    const input =
        \\outer:
        \\  inner:
        \\    items:
        \\      - one
        \\      - two
    ;
    var result = try parse(allocator, input);
    result.deinit();
}

test "parse handles tabs in content" {
    // Tab after colon doesn't count as `: ` separator, so it's parsed as string
    const input = "name:\thello";
    var result = try parse(std.testing.allocator, input);
    defer result.deinit();
    // This gets treated as a plain string, not a key-value pair
    const str = result.value.getString();
    try std.testing.expect(str != null);
}

test "parse list in list item with nested map" {
    const input =
        \\envs:
        \\  - name: FOO
        \\    value: bar
    ;
    var result = try parse(std.testing.allocator, input);
    defer result.deinit();
    const envs = result.value.get("envs").?.getList().?;
    try std.testing.expectEqual(@as(usize, 1), envs.len);
    const first = envs[0];
    try std.testing.expectEqualStrings("FOO", first.get("name").?.getString().?);
    try std.testing.expectEqualStrings("bar", first.get("value").?.getString().?);
}

test "parse map after list" {
    const input =
        \\items:
        \\  - one
        \\  - two
        \\next: value
    ;
    var result = try parse(std.testing.allocator, input);
    defer result.deinit();
    const items = result.value.get("items").?.getList().?;
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("value", result.value.get("next").?.getString().?);
}

test "parse comment between list items" {
    const input =
        \\items:
        \\  - one
        \\  # comment
        \\  - two
    ;
    var result = try parse(std.testing.allocator, input);
    defer result.deinit();
    const items = result.value.get("items").?.getList().?;
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("one", items[0].getString().?);
    try std.testing.expectEqualStrings("two", items[1].getString().?);
}

test "parse multiple top-level keys with env and env-from" {
    const input =
        \\disable-services:
        \\  - chrony
        \\  - ssh
        \\# Static env vars that reference values from env-from sources
        \\env:
        \\  - name: DATABASE_URL
        \\    value: "test"
        \\env-from:
        \\  # S3: provides DB_HOST, DB_PORT, DB_NAME
        \\  - s3:
        \\      bucket: env-bucket
        \\      key: db-config.json
        \\  # SSM: provides DB_USER
        \\  - ssm:
        \\      path: /app/db/username
        \\      name: DB_USER
        \\command:
        \\  - /bin/sh
    ;
    var result = try parse(std.testing.allocator, input);
    defer result.deinit();

    // Check disable-services
    const ds = result.value.get("disable-services").?.getList().?;
    try std.testing.expectEqual(@as(usize, 2), ds.len);

    // Check env
    const env = result.value.get("env").?.getList().?;
    try std.testing.expectEqual(@as(usize, 1), env.len);

    // Check env-from
    const env_from = result.value.get("env-from");
    try std.testing.expect(env_from != null);
    const ef_list = env_from.?.getList().?;
    try std.testing.expectEqual(@as(usize, 2), ef_list.len);

    // Check command
    const cmd = result.value.get("command").?.getList().?;
    try std.testing.expectEqual(@as(usize, 1), cmd.len);
}

test "parse flow sequence single item" {
    const input = "command: [\"/bin/echo\"]";
    var result = try parse(std.testing.allocator, input);
    defer result.deinit();
    const items = result.value.get("command").?.getList().?;
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("/bin/echo", items[0].getString().?);
}

test "parse flow sequence multiple items" {
    const input = "command: [\"/bin/sh\", \"-c\", \"echo hello\"]";
    var result = try parse(std.testing.allocator, input);
    defer result.deinit();
    const items = result.value.get("command").?.getList().?;
    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqualStrings("/bin/sh", items[0].getString().?);
    try std.testing.expectEqualStrings("-c", items[1].getString().?);
    try std.testing.expectEqualStrings("echo hello", items[2].getString().?);
}

test "parse flow sequence empty" {
    const input = "args: []";
    var result = try parse(std.testing.allocator, input);
    defer result.deinit();
    const items = result.value.get("args").?.getList().?;
    try std.testing.expectEqual(@as(usize, 0), items.len);
}

test "parse flow sequence unquoted items" {
    const input = "modules: [nfs, fuse]";
    var result = try parse(std.testing.allocator, input);
    defer result.deinit();
    const items = result.value.get("modules").?.getList().?;
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("nfs", items[0].getString().?);
    try std.testing.expectEqualStrings("fuse", items[1].getString().?);
}

test "parse quoted keys" {
    const input =
        \\"command":
        \\  - /bin/echo
        \\"debug": true
    ;
    var result = try parse(std.testing.allocator, input);
    defer result.deinit();
    const cmd = result.value.get("command").?.getList().?;
    try std.testing.expectEqual(@as(usize, 1), cmd.len);
    try std.testing.expectEqualStrings("/bin/echo", cmd[0].getString().?);
    try std.testing.expectEqualStrings("true", result.value.get("debug").?.getString().?);
}

test "parse quoted keys with inline values" {
    const input = "\"name\": hello";
    var result = try parse(std.testing.allocator, input);
    defer result.deinit();
    try std.testing.expectEqualStrings("hello", result.value.get("name").?.getString().?);
}

test "parse single-quoted keys" {
    const input = "'name': hello";
    var result = try parse(std.testing.allocator, input);
    defer result.deinit();
    try std.testing.expectEqualStrings("hello", result.value.get("name").?.getString().?);
}
