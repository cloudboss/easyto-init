//! Spot instance termination monitor.
//!
//! Polls IMDS for spot termination notices and triggers graceful shutdown
//! when a termination is imminent. AWS provides a 2-minute warning before
//! spot instance termination.

const std = @import("std");

const aws = @import("aws");

const service = @import("service.zig");

const scoped_log = std.log.scoped(.spot);

/// Default polling interval for spot termination notices (5 seconds).
const POLL_INTERVAL_NS: u64 = 5 * std.time.ns_per_s;

/// IMDS path for spot instance action (termination/stop notices).
const SPOT_INSTANCE_ACTION_PATH = "/latest/meta-data/spot/instance-action";

/// Starts the spot termination monitor in a background thread.
///
/// The monitor polls IMDS every 5 seconds for spot termination notices.
/// When a termination notice is detected, it triggers a graceful shutdown
/// via the supervisor's shutdown_requested atomic.
pub fn startSpotTerminationMonitor() void {
    const thread = std.Thread.spawn(
        .{ .stack_size = 1024 * 1024 },
        monitorLoop,
        .{},
    ) catch |err| {
        scoped_log.err("failed to spawn spot termination monitor thread: {s}", .{@errorName(err)});
        return;
    };
    thread.detach();
    scoped_log.debug("spot termination monitor started (polling every 5s)", .{});
}

/// Main monitoring loop that polls IMDS for spot termination notices.
/// Creates its own IMDS client because this runs in a detached thread that may
/// outlive the caller's aws_ctx. Sharing the main IMDS client would risk
/// use-after-free when the main thread cleans up.
fn monitorLoop() void {
    const allocator = std.heap.page_allocator;
    var imds_client = aws.ImdsClient.init(allocator, .{}) catch |err| {
        scoped_log.err("failed to initialize IMDS client for spot monitor: {s}", .{@errorName(err)});
        return;
    };
    defer imds_client.deinit();

    while (true) {
        std.Thread.sleep(POLL_INTERVAL_NS);

        if (service.isShutdownRequested()) {
            scoped_log.debug("shutdown already requested, stopping spot monitor", .{});
            return;
        }

        switch (checkSpotTermination(&imds_client)) {
            .termination_scheduled => {
                scoped_log.info("initiating graceful shutdown due to spot termination", .{});
                service.requestShutdown();
                return;
            },
            .no_termination => {},
            .check_error => |err_name| {
                scoped_log.warn("failed to check spot termination status: {s}", .{err_name});
            },
        }
    }
}

/// Result of checking spot termination status.
const CheckResult = union(enum) {
    termination_scheduled: void,
    no_termination: void,
    check_error: []const u8,
};

fn checkSpotTermination(imds_client: *aws.ImdsClient) CheckResult {
    var diagnostic: aws.imds.ServiceError = undefined;
    const response = imds_client.getMetadata(
        SPOT_INSTANCE_ACTION_PATH,
        .{ .diagnostic = &diagnostic },
    ) catch |err| {
        if (err == error.HttpError and diagnostic.httpStatus() == 404) {
            return .no_termination;
        }
        return .{ .check_error = @errorName(err) };
    };
    defer std.heap.page_allocator.free(response);

    // Parse JSON response: {"action": "terminate", "time": "2024-01-15T12:00:00Z"}
    const parsed = std.json.parseFromSlice(
        struct { action: []const u8, time: []const u8 },
        std.heap.page_allocator,
        response,
        .{ .ignore_unknown_fields = true },
    ) catch {
        return .{ .check_error = "invalid JSON response" };
    };
    defer parsed.deinit();

    // Log before deinit frees the parsed strings
    scoped_log.info("Spot termination notice received: action={s}, time={s}", .{
        parsed.value.action,
        parsed.value.time,
    });

    return .termination_scheduled;
}

test "CheckResult union works correctly" {
    const no_term: CheckResult = .no_termination;
    try std.testing.expect(no_term == .no_termination);

    const err_result: CheckResult = .{ .check_error = "test error" };
    try std.testing.expectEqualStrings("test error", err_result.check_error);

    const term: CheckResult = .termination_scheduled;
    try std.testing.expect(term == .termination_scheduled);
}
