const std = @import("std");

var current_level: std.atomic.Value(u8) = .init(@intFromEnum(std.log.Level.info));

pub fn setLevel(level: std.log.Level) void {
    current_level.store(@intFromEnum(level), .monotonic);
}

pub fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(message_level) > current_level.load(.monotonic))
        return;
    std.log.defaultLog(message_level, scope, format, args);
}
