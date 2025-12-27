use log::{Level, LevelFilter, Log, Metadata, Record};
use std::io::{self, Write};
use std::sync::atomic::{AtomicUsize, Ordering};

struct DynLogger {
    level: AtomicUsize,
}

impl DynLogger {
    const fn new() -> Self {
        Self {
            level: AtomicUsize::new(LevelFilter::Info as usize),
        }
    }

    fn current_level(&self) -> LevelFilter {
        match self.level.load(Ordering::Relaxed) {
            0 => LevelFilter::Off,
            1 => LevelFilter::Error,
            2 => LevelFilter::Warn,
            3 => LevelFilter::Info,
            4 => LevelFilter::Debug,
            _ => LevelFilter::Trace,
        }
    }

    fn set_level_internal(&self, level: LevelFilter) {
        let val = match level {
            LevelFilter::Off => 0,
            LevelFilter::Error => 1,
            LevelFilter::Warn => 2,
            LevelFilter::Info => 3,
            LevelFilter::Debug => 4,
            LevelFilter::Trace => 5,
        };
        self.level.store(val, Ordering::Relaxed);
    }
}

impl Log for DynLogger {
    fn enabled(&self, metadata: &Metadata) -> bool {
        metadata.level() <= self.current_level()
    }

    fn log(&self, record: &Record) {
        if self.enabled(record.metadata()) {
            let _ = writeln!(io::stderr(), "[{}] {}", record.level(), record.args());
        }
    }

    fn flush(&self) {
        let _ = io::stderr().flush();
    }
}

static LOGGER: DynLogger = DynLogger::new();

pub fn init_logger(level: Level) -> Result<(), log::SetLoggerError> {
    log::set_logger(&LOGGER)?;
    log::set_max_level(LevelFilter::Trace);
    set_log_level(level);
    Ok(())
}

pub fn set_log_level(level: Level) {
    let lf = level.to_level_filter();
    LOGGER.set_level_internal(lf);
}
