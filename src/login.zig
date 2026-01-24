const std = @import("std");
const fmt = std.fmt;
const Allocator = std.mem.Allocator;
const AnyReader = std.io.AnyReader;

const string = @import("string.zig");

pub fn user_group_id(allocator: Allocator, reader: AnyReader, name: []const u8) !u32 {
    var line = std.ArrayList(u8).init(allocator);
    defer line.deinit();

    const writer = line.writer();

    while (reader.streamUntilDelimiter(writer, '\n', null)) {
        defer line.clearRetainingCapacity();

        var fields = std.mem.splitSequence(u8, line.items, ":");

        const field0 = fields.next() orelse return error.InvalidUserGroupFile;
        if (!string.equals(field0, name)) continue;

        _ = fields.next() orelse return error.InvalidUserGroupFile;

        const field2 = fields.next() orelse return error.InvalidUserGroupFile;
        const id = fmt.parseInt(u32, field2, 10) catch {
            return error.InvalidUserGroupId;
        };
        return id;
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }

    return error.UserGroupIdNotFound;
}

const testing = std.testing;

test "user_group_id user id" {
    const contents =
        \\tcpdump:x:72:72:tcpdump:/:/usr/sbin/nologin
        \\systemd-coredump:x:978:978:systemd Core Dumper:/:/usr/sbin/nologin
        \\systemd-timesync:x:977:977:systemd Time Synchronization:/:/usr/sbin/nologin
        \\joseph:x:1000:1000:Joseph Wright:/home/joseph:/bin/bash
        \\passim:x:975:975:Local Caching Server:/usr/share/empty:/usr/sbin/nologin
        \\wsdd:x:974:974:Web Services Dynamic Discovery host daemon:/:/sbin/nologin
        \\stapunpriv:x:159:159:systemtap unprivileged user:/var/lib/stapunpriv:/sbin/nologin
    ;
    const reader = string.Reader.init(contents).reader();

    const id = user_group_id(testing.allocator, reader, "tcpdump");
    try testing.expectEqual(72, id);

    const notfound = user_group_id(testing.allocator, reader, "xyz");
    try testing.expectError(error.UserGroupIdNotFound, notfound);
}

test "user_group_id group id" {
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
    const reader = string.Reader.init(contents).reader();

    const id = user_group_id(testing.allocator, reader, "joseph");
    try testing.expectEqual(1000, id);

    const notfound = user_group_id(testing.allocator, reader, "xyz");
    try testing.expectError(error.UserGroupIdNotFound, notfound);
}
