const std = @import("std");

const initialize = @import("initialize.zig");
pub const log_level = @import("log_level.zig");
const system = @import("system.zig");

// Compile in all log levels so debug can be enabled at runtime.
pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = log_level.logFn,
};

pub fn main(process_init: std.process.Init) !void {
    initialize.run(
        process_init.gpa,
        process_init.io,
        process_init.environ_map,
    ) catch |err| {
        std.log.err("System error: {s}", .{@errorName(err)});
    };

    system.poweroff();
}
