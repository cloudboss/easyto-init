const std = @import("std");
const builtin = @import("builtin");

const init = @import("init.zig");
const system = @import("system.zig");

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

pub fn main() !void {
    const alloc, const is_debug = switch (builtin.mode) {
        .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
        .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
    };

    init.run(alloc) catch |err| {
        std.log.err("system error: {any}\n", .{err});
    };

    if (is_debug) {
        _ = debug_allocator.deinit();
    }

    system.poweroff();
}
