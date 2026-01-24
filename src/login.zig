const std = @import("std");
const fmt = std.fmt;
const Allocator = std.mem.Allocator;

const string = @import("string.zig");

pub fn user_group_id(contents: []const u8, name: []const u8) !u32 {
    var lines = std.mem.splitScalar(u8, contents, '\n');

    while (lines.next()) |line| {
        var fields = std.mem.splitSequence(u8, line, ":");

        const field0 = fields.next() orelse return error.InvalidUserGroupFile;
        if (!string.equals(field0, name)) continue;

        _ = fields.next() orelse return error.InvalidUserGroupFile;

        const field2 = fields.next() orelse return error.InvalidUserGroupFile;
        const id = fmt.parseInt(u32, field2, 10) catch {
            return error.InvalidUserGroupId;
        };
        return id;
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

    const id = user_group_id(contents, "tcpdump");
    try testing.expectEqual(72, id);

    const notfound = user_group_id(contents, "xyz");
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

    const id = user_group_id(contents, "joseph");
    try testing.expectEqual(1000, id);

    const notfound = user_group_id(contents, "xyz");
    try testing.expectError(error.UserGroupIdNotFound, notfound);
}
