const std = @import("std");
const Allocator = std.mem.Allocator;

const AwsContext = @import("aws/context.zig").AwsContext;
const init_mod = @import("init.zig");
const tasks = @import("tasks.zig");
const vmspec_mod = @import("vmspec.zig");
const VmSpec = vmspec_mod.VmSpec;

pub const TaskId = enum(u8) {
    aws_context_init,
    network_init,
    fetch_user_data,
    parse_user_data,
    enable_debug_logging,
    start_uevent_listener,
    link_nvme_devices,
    read_metadata,
    parse_config_file,
    merge_vmspec,
    resolve_env_from,
    expand_env_values,
    load_modules,
    set_sysctls,
    resize_root_volume,
    process_volumes,
    run_init_scripts,
    expand_command_and_args,

    pub const count = @typeInfo(TaskId).@"enum".fields.len;
};

pub const TaskDescriptor = struct {
    name: []const u8,
    deps: []const TaskId,
    run_fn: *const fn (*BootContext) anyerror!void,
};

pub const task_descriptors = blk: {
    var descs: [TaskId.count]TaskDescriptor = undefined;

    descs[@intFromEnum(TaskId.aws_context_init)] = .{
        .name = "aws_context_init",
        .deps = &.{},
        .run_fn = &tasks.awsContextInit,
    };
    descs[@intFromEnum(TaskId.network_init)] = .{
        .name = "network_init",
        .deps = &.{.aws_context_init},
        .run_fn = &tasks.networkInit,
    };
    descs[@intFromEnum(TaskId.fetch_user_data)] = .{
        .name = "fetch_user_data",
        .deps = &.{.network_init},
        .run_fn = &tasks.fetchUserData,
    };
    descs[@intFromEnum(TaskId.parse_user_data)] = .{
        .name = "parse_user_data",
        .deps = &.{.fetch_user_data},
        .run_fn = &tasks.parseUserData,
    };
    descs[@intFromEnum(TaskId.enable_debug_logging)] = .{
        .name = "enable_debug_logging",
        .deps = &.{.parse_user_data},
        .run_fn = &tasks.enableDebugLogging,
    };
    descs[@intFromEnum(TaskId.start_uevent_listener)] = .{
        .name = "start_uevent_listener",
        .deps = &.{},
        .run_fn = &tasks.startUeventListener,
    };
    descs[@intFromEnum(TaskId.link_nvme_devices)] = .{
        .name = "link_nvme_devices",
        .deps = &.{.start_uevent_listener},
        .run_fn = &tasks.linkNvmeDevices,
    };
    descs[@intFromEnum(TaskId.read_metadata)] = .{
        .name = "read_metadata",
        .deps = &.{},
        .run_fn = &tasks.readMetadata,
    };
    descs[@intFromEnum(TaskId.parse_config_file)] = .{
        .name = "parse_config_file",
        .deps = &.{.read_metadata},
        .run_fn = &tasks.parseConfigFile,
    };
    descs[@intFromEnum(TaskId.merge_vmspec)] = .{
        .name = "merge_vmspec",
        .deps = &.{ .parse_user_data, .parse_config_file },
        .run_fn = &tasks.mergeVmspec,
    };
    descs[@intFromEnum(TaskId.resolve_env_from)] = .{
        .name = "resolve_env_from",
        .deps = &.{ .network_init, .merge_vmspec },
        .run_fn = &tasks.resolveEnvFrom,
    };
    descs[@intFromEnum(TaskId.expand_env_values)] = .{
        .name = "expand_env_values",
        .deps = &.{.resolve_env_from},
        .run_fn = &tasks.expandEnvValues,
    };
    descs[@intFromEnum(TaskId.load_modules)] = .{
        .name = "load_modules",
        .deps = &.{.merge_vmspec},
        .run_fn = &tasks.loadModules,
    };
    descs[@intFromEnum(TaskId.set_sysctls)] = .{
        .name = "set_sysctls",
        .deps = &.{ .merge_vmspec, .load_modules },
        .run_fn = &tasks.setSysctls,
    };
    descs[@intFromEnum(TaskId.resize_root_volume)] = .{
        .name = "resize_root_volume",
        .deps = &.{},
        .run_fn = &tasks.resizeRootVolume,
    };
    descs[@intFromEnum(TaskId.process_volumes)] = .{
        .name = "process_volumes",
        .deps = &.{ .network_init, .merge_vmspec, .expand_env_values },
        .run_fn = &tasks.processVolumes,
    };
    descs[@intFromEnum(TaskId.run_init_scripts)] = .{
        .name = "run_init_scripts",
        .deps = &.{
            .expand_env_values,
            .load_modules,
            .set_sysctls,
            .resize_root_volume,
            .process_volumes,
        },
        .run_fn = &tasks.runInitScripts,
    };
    descs[@intFromEnum(TaskId.expand_command_and_args)] = .{
        .name = "expand_command_and_args",
        .deps = &.{.expand_env_values},
        .run_fn = &tasks.expandCommandAndArgs,
    };

    validateDag(&descs);

    break :blk descs;
};

fn validateDag(descs: *const [TaskId.count]TaskDescriptor) void {
    // Check for cycles using DFS with coloring: 0=unvisited, 1=in progress, 2=done.
    var color: [TaskId.count]u8 = .{0} ** TaskId.count;
    for (0..TaskId.count) |i| {
        if (color[i] == 0) {
            validateNoCycle(descs, i, &color);
        }
    }
}

fn validateNoCycle(
    descs: *const [TaskId.count]TaskDescriptor,
    node: usize,
    color: *[TaskId.count]u8,
) void {
    color[node] = 1;
    for (descs[node].deps) |dep| {
        const dep_idx = @intFromEnum(dep);
        if (color[dep_idx] == 1) {
            @compileError("cycle detected in DAG");
        }
        if (color[dep_idx] == 0) {
            validateNoCycle(descs, dep_idx, color);
        }
    }
    color[node] = 2;
}

pub const BootContext = struct {
    allocator: Allocator,
    vmspec_arena: std.heap.ArenaAllocator,

    aws_ctx: ?AwsContext = null,
    user_data: ?[]const u8 = null,
    user_vmspec_parsed: ?VmSpec.ParsedYaml = null,
    metadata: ?init_mod.Metadata = null,
    vmspec: ?VmSpec = null,
    expanded_command: ?init_mod.ExpandedCommand = null,

    pub fn init(allocator: Allocator) BootContext {
        return .{
            .allocator = allocator,
            .vmspec_arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *BootContext) void {
        if (self.expanded_command) |ec| ec.deinit(self.allocator);
        if (self.metadata) |*m| m.deinit();
        if (self.user_vmspec_parsed) |p| p.deinit();
        if (self.user_data) |ud| self.allocator.free(ud);
        if (self.aws_ctx) |*ctx| ctx.deinit();
        self.vmspec_arena.deinit();
    }

    pub fn vmspecAllocator(self: *BootContext) Allocator {
        return self.vmspec_arena.allocator();
    }
};

const TaskState = enum(u8) {
    pending,
    completed,
    failed,
};

pub const DagExecutor = struct {
    const Self = @This();
    const max_workers = TaskId.count;

    pending_deps: [TaskId.count]std.atomic.Value(u32),
    task_states: [TaskId.count]TaskState,
    task_errors: [TaskId.count]?anyerror,

    queue_mutex: std.Thread.Mutex,
    queue_cond: std.Thread.Condition,
    queue_buf: [TaskId.count]TaskId,
    queue_head: usize,
    queue_tail: usize,
    queue_len: usize,

    completed_count: std.atomic.Value(u32),
    fatal_error: std.atomic.Value(bool),
    first_error: ?anyerror,
    error_task: ?TaskId,
    ctx: *BootContext,

    pub fn init(ctx: *BootContext) Self {
        var self: Self = .{
            .pending_deps = undefined,
            .task_states = .{.pending} ** TaskId.count,
            .task_errors = .{null} ** TaskId.count,
            .queue_mutex = .{},
            .queue_cond = .{},
            .queue_buf = undefined,
            .queue_head = 0,
            .queue_tail = 0,
            .queue_len = 0,
            .completed_count = std.atomic.Value(u32).init(0),
            .fatal_error = std.atomic.Value(bool).init(false),
            .first_error = null,
            .error_task = null,
            .ctx = ctx,
        };

        for (0..TaskId.count) |i| {
            self.pending_deps[i] =
                std.atomic.Value(u32).init(@intCast(task_descriptors[i].deps.len));
        }

        return self;
    }

    pub fn run(self: *Self) !void {
        // Enqueue root tasks (zero dependencies).
        for (0..TaskId.count) |i| {
            if (self.pending_deps[i].load(.acquire) == 0) {
                self.enqueue(@enumFromInt(i));
            }
        }

        const cpu_count = std.Thread.getCpuCount() catch 4;
        const num_workers = @min(cpu_count, max_workers);
        var threads: [max_workers]std.Thread = undefined;
        var spawned: usize = 0;

        for (0..num_workers) |i| {
            threads[i] = std.Thread.spawn(
                .{ .stack_size = 2 * 1024 * 1024 },
                workerLoop,
                .{self},
            ) catch |err| {
                std.log.err("failed to spawn worker thread {d}: {s}", .{ i, @errorName(err) });
                if (spawned == 0) return err;
                break;
            };
            spawned += 1;
        }

        for (threads[0..spawned]) |t| {
            t.join();
        }

        if (self.first_error) |err| {
            const task_name = task_descriptors[@intFromEnum(self.error_task.?)].name;
            std.log.err("boot failed at task {s}: {s}", .{ task_name, @errorName(err) });
            return err;
        }
    }

    fn workerLoop(self: *Self) void {
        while (true) {
            if (self.fatal_error.load(.acquire)) return;
            if (self.completed_count.load(.acquire) >= TaskId.count) return;

            const task_id = self.dequeue() orelse return;
            self.executeTask(task_id);
        }
    }

    fn executeTask(self: *Self, task_id: TaskId) void {
        const idx = @intFromEnum(task_id);
        const desc = task_descriptors[idx];

        std.log.info("task started: {s}", .{desc.name});
        const start = std.time.Instant.now() catch unreachable;

        if (desc.run_fn(self.ctx)) {
            const elapsed_ns = (std.time.Instant.now() catch unreachable).since(start);
            const elapsed_ms = elapsed_ns / std.time.ns_per_ms;
            if (elapsed_ms > 0) {
                std.log.info("task completed: {s} ({d}ms)", .{ desc.name, elapsed_ms });
            } else if (elapsed_ns >= 1000) {
                std.log.info(
                    "task completed: {s} ({d}\xc2\xb5s)",
                    .{ desc.name, elapsed_ns / 1000 },
                );
            } else {
                std.log.info("task completed: {s} ({d}ns)", .{ desc.name, elapsed_ns });
            }
            self.task_states[idx] = .completed;
            _ = self.completed_count.fetchAdd(1, .acq_rel);
            self.notifyDependents(task_id);
        } else |err| {
            std.log.err("task failed: {s}: {s}", .{ desc.name, @errorName(err) });
            self.task_states[idx] = .failed;
            self.task_errors[idx] = err;
            if (!self.fatal_error.swap(true, .acq_rel)) {
                self.first_error = err;
                self.error_task = task_id;
            }
            self.queue_cond.broadcast();
        }
    }

    fn notifyDependents(self: *Self, completed_task: TaskId) void {
        for (0..TaskId.count) |i| {
            const desc = task_descriptors[i];
            for (desc.deps) |dep| {
                if (dep == completed_task) {
                    const prev = self.pending_deps[i].fetchSub(1, .acq_rel);
                    if (prev == 1) {
                        self.enqueue(@enumFromInt(i));
                    }
                    break;
                }
            }
        }
    }

    fn enqueue(self: *Self, task_id: TaskId) void {
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();

        self.queue_buf[self.queue_tail] = task_id;
        self.queue_tail = (self.queue_tail + 1) % TaskId.count;
        self.queue_len += 1;

        self.queue_cond.signal();
    }

    fn dequeue(self: *Self) ?TaskId {
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();

        while (self.queue_len == 0) {
            if (self.fatal_error.load(.acquire)) return null;
            if (self.completed_count.load(.acquire) >= TaskId.count) return null;

            self.queue_cond.timedWait(&self.queue_mutex, 500 * std.time.ns_per_ms) catch {};
        }

        if (self.queue_len == 0) return null;

        const task_id = self.queue_buf[self.queue_head];
        self.queue_head = (self.queue_head + 1) % TaskId.count;
        self.queue_len -= 1;
        return task_id;
    }
};
