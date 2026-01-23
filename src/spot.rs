//! Spot instance termination monitor.
//!
//! Polls IMDS for spot termination notices and triggers graceful shutdown
//! when a termination is imminent. AWS provides a 2-minute warning before
//! spot instance termination.

use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use crossbeam::channel::Sender;
use log::{debug, info, warn};

use crate::aws::imds::ImdsClient;
use crate::service::SupervisorBase;

/// Default polling interval for spot termination notices.
const POLL_INTERVAL: Duration = Duration::from_secs(5);

/// IMDS path for spot instance action (termination/stop notices).
const SPOT_INSTANCE_ACTION_PATH: &str = "spot/instance-action";

/// Starts the spot termination monitor in a background thread.
///
/// The monitor polls IMDS every 5 seconds for spot termination notices.
/// When a termination notice is detected, it triggers a graceful shutdown
/// via the supervisor.
pub fn start_spot_termination_monitor(
    imds_client: ImdsClient,
    base_ref: Arc<Mutex<SupervisorBase>>,
    timeout_tx: Sender<()>,
) {
    thread::spawn(move || {
        debug!(
            "Starting spot termination monitor (polling every {:?})",
            POLL_INTERVAL
        );
        monitor_loop(imds_client, base_ref, timeout_tx);
    });
}

/// Main monitoring loop that polls IMDS for spot termination notices.
fn monitor_loop(
    imds_client: ImdsClient,
    base_ref: Arc<Mutex<SupervisorBase>>,
    timeout_tx: Sender<()>,
) {
    loop {
        thread::sleep(POLL_INTERVAL);

        match check_spot_termination(&imds_client) {
            Ok(Some(action)) => {
                info!(
                    "Spot termination notice received: action={}, time={}",
                    action.action, action.time
                );
                info!("Initiating graceful shutdown due to spot termination");
                base_ref.lock().unwrap().stop(timeout_tx);
                return;
            }
            Ok(None) => {
                // No termination scheduled, continue polling.
            }
            Err(e) => {
                // Log warning but continue polling - could be transient network issue
                warn!("Failed to check spot termination status: {}", e);
            }
        }
    }
}

/// Spot instance action details returned by IMDS.
#[derive(Debug)]
struct SpotAction {
    action: String,
    time: String,
}

/// Checks IMDS for a spot termination notice.
///
/// Returns:
/// - `Ok(Some(SpotAction))` if termination is scheduled
/// - `Ok(None)` if no termination is scheduled (404 from IMDS)
/// - `Err` if there was an error querying IMDS
fn check_spot_termination(imds_client: &ImdsClient) -> anyhow::Result<Option<SpotAction>> {
    match imds_client.get_metadata(SPOT_INSTANCE_ACTION_PATH) {
        Ok(response) => {
            // Parse the JSON response: {"action": "terminate", "time": "2024-01-15T12:00:00Z"}
            let response_str: &str = response.as_ref();
            let parsed: serde_json::Value = serde_json::from_str(response_str)
                .map_err(|e| anyhow::anyhow!("failed to parse spot action response: {}", e))?;

            let action = parsed["action"].as_str().unwrap_or("unknown").to_string();
            let time = parsed["time"].as_str().unwrap_or("unknown").to_string();

            Ok(Some(SpotAction { action, time }))
        }
        Err(e) => {
            // Check if it's a 404 (no termination scheduled) vs actual error
            let err_str = e.to_string();
            if err_str.contains("404") {
                Ok(None)
            } else {
                Err(e)
            }
        }
    }
}
