use std::{thread, time::Duration};

use easyto_init::init;
use rustix::system::{RebootCommand, reboot};

fn main() {
    if let Err(e) = init::initialize() {
        // Use eprintln! here in case logger does not initialize.
        eprintln!("Failed to initialize: {}", e);
    }
    // Sleep to let console output catch up.
    thread::sleep(Duration::from_secs(1));
    let _ = reboot(RebootCommand::PowerOff);
}
