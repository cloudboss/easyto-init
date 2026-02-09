const std = @import("std");
const builtin = @import("builtin");

const init = @import("init.zig");
const system = @import("system.zig");

pub const log_level = @import("log_level.zig");

// Compile in all log levels so debug can be enabled at runtime.
pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = log_level.logFn,
};

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

pub fn main() !void {
    const alloc, const is_debug = switch (builtin.mode) {
        .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
        .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
    };

    init.run(alloc) catch |err| {
        std.log.err("System error: {s}", .{@errorName(err)});
    };

    if (is_debug) {
        _ = debug_allocator.deinit();
    }

    system.poweroff();
}
