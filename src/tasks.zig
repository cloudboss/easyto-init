const std = @import("std");

const constants = @import("constants.zig");
const dag = @import("dag.zig");
const init_mod = @import("init.zig");
const log_level = @import("log_level.zig");
const network = @import("network.zig");
const system = @import("system.zig");
const uevent = @import("uevent.zig");
const vmspec_mod = @import("vmspec.zig");
const VmSpec = vmspec_mod.VmSpec;
const AwsContext = @import("aws/context.zig").AwsContext;

const BootContext = dag.BootContext;

pub fn awsContextInit(ctx: *BootContext) !void {
    ctx.aws_ctx = try AwsContext.init(ctx.allocator);
}

pub fn networkInit(ctx: *BootContext) !void {
    try network.initializeNetwork(ctx.allocator, ctx.aws_ctx.?.getImds());
}

pub fn fetchUserData(ctx: *BootContext) anyerror!void {
    ctx.user_data = init_mod.fetchUserData(&ctx.aws_ctx.?) catch |err| blk: {
        std.log.warn("failed to fetch user data: {s}, continuing without", .{@errorName(err)});
        break :blk null;
    };
}

pub fn parseUserData(ctx: *BootContext) !void {
    const ud = ctx.user_data orelse return;
    if (VmSpec.from_yaml(ctx.allocator, ud)) |parsed| {
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
    try uevent.startUeventListener(ctx.allocator);
}

pub fn linkNvmeDevices(ctx: *BootContext) !void {
    try system.link_nvme_devices(ctx.allocator);
}

pub fn readMetadata(ctx: *BootContext) !void {
    const path = constants.DIR_ET ++ "/" ++ constants.FILE_METADATA;
    ctx.metadata = try init_mod.read_metadata(ctx.allocator, path);
}

pub fn parseConfigFile(ctx: *BootContext) !void {
    ctx.vmspec = try VmSpec.from_config_file(ctx.vmspecAllocator(), &ctx.metadata.?.parsed.value);
}

pub fn mergeVmspec(ctx: *BootContext) !void {
    if (ctx.user_vmspec_parsed) |p| {
        try ctx.vmspec.?.merge(ctx.vmspecAllocator(), p.value);
    }
}

pub fn resolveEnvFrom(ctx: *BootContext) !void {
    if (ctx.vmspec.?.@"env-from") |env_from| {
        init_mod.resolveEnvFrom(
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
    if (ctx.vmspec.?.env) |env| {
        try init_mod.expandEnvValues(ctx.allocator, ctx.vmspecAllocator(), &ctx.vmspec.?, env);
    }
}

pub fn loadModules(ctx: *BootContext) !void {
    try system.loadModules(ctx.vmspec.?.modules);
}

pub fn setSysctls(ctx: *BootContext) !void {
    try system.setSysctls(ctx.vmspec.?.sysctls);
}

pub fn resizeRootVolume(ctx: *BootContext) !void {
    system.resizeRootVolume(ctx.allocator);
}

pub fn processVolumes(ctx: *BootContext) !void {
    if (ctx.vmspec.?.volumes) |volumes| {
        try init_mod.processVolumes(&ctx.aws_ctx.?, volumes);
    }
}

pub fn runInitScripts(ctx: *BootContext) !void {
    const vmspec = ctx.vmspec.?;
    try system.runInitScripts(vmspec.@"init-scripts", vmspec.env);
}

pub fn expandCommandAndArgs(ctx: *BootContext) !void {
    const vmspec = ctx.vmspec.?;
    ctx.expanded_command = try init_mod.expandCommandAndArgs(
        ctx.allocator,
        vmspec.full_command(),
        vmspec.command_args(),
        vmspec.env,
    );
}
