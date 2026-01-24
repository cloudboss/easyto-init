const std = @import("std");
const AnyReader = std.io.AnyReader;

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

pub const Reader = struct {
    pos: usize,
    str: []const u8,

    pub fn init(str: []const u8) Reader {
        return .{
            .pos = 0,
            .str = str,
        };
    }

    pub fn reader(self: *const Reader) AnyReader {
        return .{
            .context = self,
            .readFn = Reader.read,
        };
    }

    fn read(context: *const anyopaque, buffer: []u8) anyerror!usize {
        const ptr: *Reader = @constCast(@alignCast(@ptrCast(context)));
        var bread: usize = 0;
        for (ptr.str[ptr.pos..]) |c| {
            if (bread >= buffer.len) break;
            buffer[bread] = c;
            bread += 1;
            ptr.pos += 1;
        }
        return bread;
    }
};

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

test "string reader empty" {
    const contents = "";
    const reader = Reader.init(contents).reader();
    var buf: [10]u8 = undefined;
    const bread = try reader.read(&buf);
    try testing.expectEqual(0, bread);
    try testing.expectEqualStrings(contents, buf[0..bread]);
}

test "string reader nonempty" {
    const contents =
        \\joseph:x:1000:
        \\stapusr:x:156:
        \\stapsys:x:157:
        \\stapdev:x:158:
        \\docker:x:976:joseph
        \\passim:x:975:
        \\wsdd:x:974:
        \\gnome-remote-desktop:x:973:
        \\stapunpriv:x:159:stapunpriv
    ;
    const reader = Reader.init(contents).reader();
    var buf: [200]u8 = undefined;
    const bread = try reader.read(&buf);
    try testing.expectEqual(161, bread);
    try testing.expectEqualStrings(contents, buf[0..bread]);
}
