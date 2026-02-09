const std = @import("std");

var current_level: std.log.Level = .info;

pub fn setLevel(level: std.log.Level) void {
    current_level = level;
}

pub fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(message_level) > @intFromEnum(current_level))
        return;
    std.log.defaultLog(message_level, scope, format, args);
}
