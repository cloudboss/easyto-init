const std = @import("std");

const AwsContext = @import("aws/context.zig").AwsContext;
const BootContext = @import("dag.zig").BootContext;
const constants = @import("constants.zig");
const initialize = @import("initialize.zig");
const log_level = @import("log_level.zig");
const network = @import("network.zig");
const system = @import("system.zig");
const uevent = @import("uevent.zig");
const VmSpec = @import("vmspec.zig").VmSpec;

pub fn awsContextInit(ctx: *BootContext) !void {
    ctx.aws_ctx = try AwsContext.init(ctx.allocator, ctx.io, ctx.env_map);
}

pub fn networkInit(ctx: *BootContext) !void {
    try network.initializeNetwork(ctx.allocator, ctx.io, ctx.aws_ctx.?.getImds());
}

pub fn fetchUserData(ctx: *BootContext) anyerror!void {
    ctx.user_data = initialize.fetchUserData(ctx.allocator, &ctx.aws_ctx.?) catch |err| blk: {
        std.log.warn("failed to fetch user data: {s}, continuing without", .{@errorName(err)});
        break :blk null;
    };
}

pub fn writeUserData(ctx: *BootContext) !void {
    const ud = ctx.user_data orelse return;
    try initialize.writeUserData(ctx.io, ud);
}

pub fn parseUserData(ctx: *BootContext) !void {
    const ud = ctx.user_data orelse return;
    if (VmSpec.fromYaml(ctx.allocator, ud)) |parsed| {
        ctx.user_vmspec_parsed = parsed;
    } else |err| {
        std.log.err("unable to parse user data: {s}", .{@errorName(err)});
        return err;
    }
}

pub fn enableDebugLogging(ctx: *BootContext) !void {
    if (ctx.user_vmspec_parsed) |p| {
        if (p.value.debug != null and p.value.debug.?) {
            log_level.setLevel(.debug);
            std.log.debug("debug logging enabled", .{});
        }
    }
}

pub fn startUeventListener(ctx: *BootContext) !void {
    try uevent.startUeventListener(ctx.allocator, ctx.io);
}

pub fn linkNvmeDevices(ctx: *BootContext) !void {
    try system.linkNvmeDevices(ctx.allocator, ctx.io);
}

pub fn readMetadata(ctx: *BootContext) !void {
    const path = constants.dir_et ++ "/" ++ constants.file_metadata;
    ctx.metadata = try initialize.readMetadata(ctx.allocator, ctx.io, path);
}

pub fn parseConfigFile(ctx: *BootContext) !void {
    ctx.vmspec = try VmSpec.fromConfigFile(
        ctx.vmspecAllocator(),
        ctx.io,
        &ctx.metadata.?.parsed.value,
    );
}

pub fn mergeVmspec(ctx: *BootContext) !void {
    if (ctx.user_vmspec_parsed) |p| {
        try ctx.vmspec.?.merge(ctx.vmspecAllocator(), p.value);
    }
}

pub fn resolveEnvFrom(ctx: *BootContext) !void {
    if (ctx.vmspec.?.@"env-from") |env_from| {
        initialize.resolveEnvFrom(
            ctx.allocator,
            ctx.vmspecAllocator(),
            &ctx.aws_ctx.?,
            &ctx.vmspec.?,
            env_from,
        ) catch |err| {
            std.log.err("unable to resolve environment variables from external sources", .{});
            return err;
        };
    }
}

pub fn expandEnvValues(ctx: *BootContext) !void {
    try initialize.expandEnvValues(
        ctx.allocator,
        ctx.vmspecAllocator(),
        &ctx.vmspec.?,
        ctx.vmspec.?.env,
    );
}

pub fn loadModules(ctx: *BootContext) !void {
    try system.loadModules(ctx.io, ctx.vmspec.?.modules);
}

pub fn setSysctls(ctx: *BootContext) !void {
    try system.setSysctls(ctx.io, ctx.vmspec.?.sysctls);
}

pub fn resizeRootVolume(ctx: *BootContext) !void {
    system.resizeRootVolume(ctx.allocator, ctx.io);
}

pub fn processVolumes(ctx: *BootContext) !void {
    const vmspec = ctx.vmspec.?;
    if (vmspec.volumes) |volumes| {
        try initialize.processVolumes(
            ctx.allocator,
            ctx.io,
            &ctx.aws_ctx.?,
            volumes,
            vmspec.env orelse &.{},
        );
    }
}

pub fn runInitScripts(ctx: *BootContext) !void {
    const vmspec = ctx.vmspec.?;
    try system.runInitScripts(ctx.allocator, ctx.io, vmspec.@"init-scripts", vmspec.env);
}

pub fn expandCommandAndArgs(ctx: *BootContext) !void {
    const vmspec = ctx.vmspec.?;
    ctx.expanded_command = try initialize.expandCommandAndArgs(
        ctx.allocator,
        ctx.io,
        vmspec.fullCommand(),
        vmspec.commandArgs(),
        vmspec.env,
    );
}
