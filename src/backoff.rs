use std::time::Duration;

use rand::TryRngCore;
use rand::rngs::OsRng;

/// Exponential backoff with jitter.
/// Based on https://www.awsarchitectureblog.com/2015/03/backoff.html.
pub(crate) struct RetryBackoff {
    attempt: u32,
    base_ms: u64,
    cap_ms: u64,
}

impl RetryBackoff {
    pub(crate) fn new(cap: Duration) -> Self {
        Self {
            attempt: 0,
            base_ms: 100,
            cap_ms: cap.as_millis() as u64,
        }
    }

    pub(crate) fn wait(&mut self) {
        let shift = self.attempt.min(63);
        let max_wait = self.cap_ms.min(self.base_ms.saturating_mul(1u64 << shift));
        let wait_ms = if max_wait > 0 {
            OsRng.try_next_u64().unwrap_or(0) % max_wait
        } else {
            0
        };
        std::thread::sleep(Duration::from_millis(wait_ms));
        self.attempt = self.attempt.saturating_add(1);
    }
}

#[cfg(test)]
mod test {
    use super::*;

    #[test]
    fn test_retry_backoff_max_wait_calculation() {
        let cap = Duration::from_secs(10);
        let backoff = RetryBackoff::new(cap);

        // base_ms = 100, cap_ms = 10000
        // attempt 0: min(10000, 100 * 2^0) = min(10000, 100) = 100
        // attempt 1: min(10000, 100 * 2^1) = min(10000, 200) = 200
        // attempt 2: min(10000, 100 * 2^2) = min(10000, 400) = 400
        // attempt 3: min(10000, 100 * 2^3) = min(10000, 800) = 800
        // attempt 4: min(10000, 100 * 2^4) = min(10000, 1600) = 1600
        // attempt 5: min(10000, 100 * 2^5) = min(10000, 3200) = 3200
        // attempt 6: min(10000, 100 * 2^6) = min(10000, 6400) = 6400
        // attempt 7: min(10000, 100 * 2^7) = min(10000, 12800) = 10000 (capped)

        assert_eq!(backoff.attempt, 0);
        assert_eq!(
            backoff.cap_ms.min(backoff.base_ms.saturating_mul(1 << 0)),
            100
        );
        assert_eq!(
            backoff.cap_ms.min(backoff.base_ms.saturating_mul(1 << 1)),
            200
        );
        assert_eq!(
            backoff.cap_ms.min(backoff.base_ms.saturating_mul(1 << 7)),
            10000
        );
    }

    #[test]
    fn test_retry_backoff_attempt_increments() {
        let cap = Duration::from_millis(1); // Very small cap to make test fast
        let mut backoff = RetryBackoff::new(cap);

        assert_eq!(backoff.attempt, 0);
        backoff.wait();
        assert_eq!(backoff.attempt, 1);
        backoff.wait();
        assert_eq!(backoff.attempt, 2);
    }

    #[test]
    fn test_retry_backoff_saturates() {
        let cap = Duration::from_secs(10);
        let mut backoff = RetryBackoff::new(cap);
        backoff.attempt = u32::MAX;
        // Should not panic on overflow
        backoff.wait();
        assert_eq!(backoff.attempt, u32::MAX);
    }
}
