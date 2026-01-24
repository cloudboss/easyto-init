const std = @import("std");

pub fn equals(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) {
        return false;
    }
    for (left, 0..) |c, i| {
        if (c != right[i]) {
            return false;
        }
    }
    return true;
}

pub fn starts_with(string: []const u8, prefix: []const u8) bool {
    if (string.len < prefix.len) {
        return false;
    }
    for (prefix, 0..) |c, i| {
        if (c != string[i]) {
            return false;
        }
    }
    return true;
}

const testing = std.testing;

test "string equals" {
    try testing.expect(equals("", ""));
    try testing.expect(equals("hello, world", "hello, world"));
    try testing.expect(!equals("", "hello"));
    try testing.expect(!equals("hello", ""));
    try testing.expect(!equals("hello, world", "world"));
    try testing.expect(!equals("hello, world", "hello, world!"));
}

test "string starts_with" {
    try testing.expect(starts_with("", ""));
    try testing.expect(starts_with("hello, world", ""));
    try testing.expect(starts_with("hello, world", "hello"));
    try testing.expect(!starts_with("", "hello"));
    try testing.expect(!starts_with("hello, world", "world"));
    try testing.expect(!starts_with("hello, world", "hello, world!"));
}
