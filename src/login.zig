const std = @import("std");
const fmt = std.fmt;
const Allocator = std.mem.Allocator;

const string = @import("string.zig");

pub const UserEntry = struct {
    name: []const u8,
    uid: u32,
    gid: u32,
    home_dir: []const u8,
    shell: []const u8,
};

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

/// Parse a passwd file and return the entry for the given username.
/// The returned slices point into the original contents buffer.
pub fn getUserEntry(contents: []const u8, name: []const u8) !UserEntry {
    var lines = std.mem.splitScalar(u8, contents, '\n');

    while (lines.next()) |line| {
        if (line.len == 0) continue;

        var fields = std.mem.splitSequence(u8, line, ":");

        // name:password:uid:gid:gecos:home:shell
        const field_name = fields.next() orelse return error.InvalidUserGroupFile;
        if (!string.equals(field_name, name)) continue;

        _ = fields.next() orelse return error.InvalidUserGroupFile; // password
        const uid_str = fields.next() orelse return error.InvalidUserGroupFile;
        const gid_str = fields.next() orelse return error.InvalidUserGroupFile;
        _ = fields.next() orelse return error.InvalidUserGroupFile; // gecos
        const home_dir = fields.next() orelse return error.InvalidUserGroupFile;
        const shell = fields.next() orelse return error.InvalidUserGroupFile;

        const uid = fmt.parseInt(u32, uid_str, 10) catch {
            return error.InvalidUserGroupId;
        };
        const gid = fmt.parseInt(u32, gid_str, 10) catch {
            return error.InvalidUserGroupId;
        };

        return UserEntry{
            .name = field_name,
            .uid = uid,
            .gid = gid,
            .home_dir = home_dir,
            .shell = shell,
        };
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

test "getUserEntry returns full user entry" {
    const contents =
        \\root:x:0:0:root:/root:/bin/bash
        \\joseph:x:1000:1000:Joseph Wright:/home/joseph:/bin/zsh
        \\cb-chrony:x:100:100:chrony user:/var/run/chrony:/usr/sbin/nologin
    ;

    const entry = try getUserEntry(contents, "joseph");
    try testing.expectEqualStrings("joseph", entry.name);
    try testing.expectEqual(@as(u32, 1000), entry.uid);
    try testing.expectEqual(@as(u32, 1000), entry.gid);
    try testing.expectEqualStrings("/home/joseph", entry.home_dir);
    try testing.expectEqualStrings("/bin/zsh", entry.shell);
}

test "getUserEntry returns not found error" {
    const contents =
        \\root:x:0:0:root:/root:/bin/bash
    ;

    const result = getUserEntry(contents, "nonexistent");
    try testing.expectError(error.UserGroupIdNotFound, result);
}
