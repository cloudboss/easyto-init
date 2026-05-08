//! Exponential backoff with jitter.
//! Based on https://www.awsarchitectureblog.com/2015/03/backoff.html

const std = @import("std");
const Io = std.Io;

/// Exponential backoff with full jitter.
pub const RetryBackoff = struct {
    attempt: u32,
    base_ms: u64,
    cap_ms: u64,

    pub fn init(cap_ms: u64) RetryBackoff {
        return .{
            .attempt = 0,
            .base_ms = 100,
            .cap_ms = cap_ms,
        };
    }

    pub fn wait(self: *RetryBackoff, io: Io) void {
        const shift: u6 = @intCast(@min(self.attempt, 63));
        const max_wait = @min(self.cap_ms, self.base_ms *| (@as(u64, 1) << shift));
        var rand_bytes: [8]u8 = undefined;
        io.random(&rand_bytes);
        const rand_u64 = std.mem.readInt(u64, &rand_bytes, .little);
        const wait_ms = if (max_wait > 0) rand_u64 % max_wait else 0;
        const wait_dur = Io.Duration.fromNanoseconds(@intCast(wait_ms * std.time.ns_per_ms));
        Io.sleep(io, wait_dur, .awake) catch {};
        self.attempt = self.attempt +| 1;
    }

    /// Calculate max wait for current attempt without sleeping. For testing.
    pub fn maxWaitMs(self: *const RetryBackoff) u64 {
        const shift: u6 = @intCast(@min(self.attempt, 63));
        return @min(self.cap_ms, self.base_ms *| (@as(u64, 1) << shift));
    }
};

test "max wait calculation" {
    var backoff = RetryBackoff.init(10000);

    // attempt 0: min(10000, 100 * 2^0) = 100
    try std.testing.expectEqual(@as(u64, 100), backoff.maxWaitMs());

    backoff.attempt = 1;
    // attempt 1: min(10000, 100 * 2^1) = 200
    try std.testing.expectEqual(@as(u64, 200), backoff.maxWaitMs());

    backoff.attempt = 2;
    // attempt 2: min(10000, 100 * 2^2) = 400
    try std.testing.expectEqual(@as(u64, 400), backoff.maxWaitMs());

    backoff.attempt = 7;
    // attempt 7: min(10000, 100 * 2^7) = min(10000, 12800) = 10000 (capped)
    try std.testing.expectEqual(@as(u64, 10000), backoff.maxWaitMs());
}

test "attempt saturates" {
    var backoff = RetryBackoff.init(10000);
    backoff.attempt = std.math.maxInt(u32);
    backoff.wait(std.testing.io);
    try std.testing.expectEqual(std.math.maxInt(u32), backoff.attempt);
}
