use std::{
    ffi::c_int,
    fs::File,
    io::{self, ErrorKind, Read, Write},
    os::unix::process::CommandExt,
    path::Path,
    process::{Command, ExitStatus},
    sync::{Arc, Mutex, Once},
    thread::{self, sleep},
    time::Duration,
};

use anyhow::{anyhow, Result};
use crossbeam::channel::{bounded, Receiver, Select, Sender};
use log::{debug, error, info, warn};
use minaws::imds::Imds;
use rustix::{
    fs::{chmod, chown, stat, Dir, FileType, Gid, Mode, Uid},
    io::Errno,
    mount::{mount_remount, MountFlags},
    process::{kill_process, wait, Signal, WaitOptions},
    thread::Pid,
};
use signal_hook::iterator::Signals;

use crate::{
    constants,
    fs::mkdir_p,
    login::{self, Find},
    vmspec::{NameValues, VmSpec},
};

// Signal sent by the "ACPI tiny power button" kernel driver, which causes the
// kernel to send a signal to init. The kernel must be compiled to use this.
const SIGPOWEROFF: c_int = 38;

// Process flag for kernel threads, from include/linux/sched.h in kernel source.
const PF_KTHREAD: u32 = 0x00200000;

#[derive(Debug)]
struct ServiceBase {
    args: Vec<String>,
    env: NameValues,
    gid: Gid,
    init: Option<fn() -> Result<()>>,
    init_rx: Receiver<()>,
    init_tx: Sender<()>,
    optional: bool,
    pid: Option<u32>,
    start_rx: Receiver<()>,
    start_tx: Sender<()>,
    stop_rx: Receiver<io::Result<ExitStatus>>,
    stop_tx: Sender<io::Result<ExitStatus>>,
    shutdown: bool,
    uid: Uid,
    working_dir: String,
}

impl ServiceBase {
    fn command(&self) -> Command {
        let args = &self.args;
        let mut cmd = Command::new(&args[0]);
        cmd.args(&args[1..]);
        cmd.current_dir(&self.working_dir);
        for nv in &self.env {
            cmd.env(nv.name.clone(), nv.value.clone());
        }
        cmd.gid(self.gid.as_raw());
        cmd.uid(self.uid.as_raw());
        cmd
    }
}

impl Default for ServiceBase {
    fn default() -> Self {
        let (err_send, err_recv) = bounded(1);
        let (init_send, init_recv) = bounded(1);
        let (start_send, start_recv) = bounded(1);
        Self {
            args: Vec::new(),
            working_dir: "/".into(),
            env: Vec::new(),
            gid: Gid::from_raw(0),
            uid: Uid::from_raw(0),
            init: None,
            stop_rx: err_recv,
            stop_tx: err_send,
            init_rx: init_recv,
            init_tx: init_send,
            pid: None,
            start_rx: start_recv,
            start_tx: start_send,
            optional: false,
            shutdown: false,
        }
    }
}

fn wait_stop(rx: Receiver<io::Result<ExitStatus>>) -> io::Result<ExitStatus> {
    match rx.recv() {
        Ok(Ok(status)) => Ok(status),
        Ok(Err(e)) => Err(e),
        Err(e) => Err(io::Error::new(io::ErrorKind::BrokenPipe, e)),
    }
}

trait Service: Send + Sync {
    fn base(&self) -> &ServiceBase;

    fn base_mut(&mut self) -> &mut ServiceBase;

    fn command(&self) -> Command {
        self.base().command()
    }

    fn init_fn(&self) -> Option<fn() -> Result<()>> {
        self.base().init
    }

    fn init_rx(&self) -> Receiver<()> {
        self.base().init_rx.clone()
    }

    fn init_tx(&self) -> Sender<()> {
        self.base().init_tx.clone()
    }

    fn is_shutdown(&self) -> bool {
        self.base().shutdown
    }

    fn name(&self) -> String;

    fn start_rx(&self) -> Receiver<()> {
        self.base().start_rx.clone()
    }

    fn start_tx(&self) -> Sender<()> {
        self.base().start_tx.clone()
    }

    fn stop_rx(&self) -> Receiver<io::Result<ExitStatus>> {
        self.base().stop_rx.clone()
    }

    fn stop_tx(&self) -> Sender<io::Result<ExitStatus>> {
        self.base().stop_tx.clone()
    }

    fn stop(&mut self) {
        self.base_mut().shutdown = true;
    }

    fn optional(&self) -> bool {
        self.base().optional
    }

    fn pid(&self) -> Option<u32> {
        self.base().pid
    }
}

#[derive(Debug)]
pub struct Main(ServiceBase);

unsafe impl Send for Main {}
unsafe impl Sync for Main {}

impl Service for Main {
    fn base(&self) -> &ServiceBase {
        &self.0
    }

    fn base_mut(&mut self) -> &mut ServiceBase {
        &mut self.0
    }

    fn name(&self) -> String {
        "main".into()
    }
}

impl Main {
    pub fn new(
        args: Vec<String>,
        working_dir: String,
        env: NameValues,
        gid: Gid,
        uid: Uid,
    ) -> Self {
        Self(ServiceBase {
            args,
            env,
            gid,
            uid,
            working_dir,
            ..Default::default()
        })
    }
}

#[derive(Debug, Default)]
struct Chrony(ServiceBase);

unsafe impl Send for Chrony {}
unsafe impl Sync for Chrony {}

impl Service for Chrony {
    fn base(&self) -> &ServiceBase {
        &self.0
    }

    fn base_mut(&mut self) -> &mut ServiceBase {
        &mut self.0
    }

    fn name(&self) -> String {
        "chrony".into()
    }
}

impl Chrony {
    fn init() -> Result<()> {
        info!("Initializing chrony");

        let passwd_file = File::open(constants::FILE_ETC_PASSWD)?;
        let user = login::parse_passwd_lines(passwd_file)?
            .find(constants::USER_NAME_CHRONY)
            .ok_or_else(|| anyhow!("user {} not found", constants::USER_NAME_CHRONY))?;

        let chrony_run_path = Path::new(constants::DIR_ET_RUN).join("chrony");
        mkdir_p(&chrony_run_path, Mode::from(0o750))?;

        let (uid, gid) = (Uid::from_raw(user.uid), (Gid::from_raw(user.gid)));
        chown(&chrony_run_path, Some(uid), Some(gid))?;

        Ok(())
    }

    pub fn new() -> Self {
        let path = Path::new(constants::DIR_ET_SBIN)
            .join("chronyd")
            .to_string_lossy()
            .to_string();
        let args = vec![path, "-d".into()];
        Self(ServiceBase {
            args,
            init: Some(Self::init),
            ..Default::default()
        })
    }
}

#[derive(Debug, Default)]
struct Ssh(ServiceBase);

unsafe impl Send for Ssh {}
unsafe impl Sync for Ssh {}

impl Service for Ssh {
    fn base(&self) -> &ServiceBase {
        &self.0
    }

    fn base_mut(&mut self) -> &mut ServiceBase {
        &mut self.0
    }

    fn name(&self) -> String {
        "ssh".into()
    }
}

impl Ssh {
    pub fn new() -> Self {
        let path = Path::new(constants::DIR_ET_SBIN).join("sshd");
        let sshd_config = Path::new(constants::DIR_ET_ETC)
            .join("ssh")
            .join("sshd_config");
        let args = vec![
            path.to_string_lossy().to_string(),
            "-D".to_string(),
            "-f".to_string(),
            sshd_config.to_string_lossy().to_string(),
            "-e".to_string(),
        ];
        Self(ServiceBase {
            args,
            init: Some(Self::init),
            optional: true,
            ..Default::default()
        })
    }

    fn init() -> Result<()> {
        info!("Initializing sshd");

        let login_user = Self::get_login_user()?;
        let passwd_file = File::open(constants::FILE_ETC_PASSWD)?;
        let user = login::parse_passwd_lines(passwd_file)?
            .find(&login_user)
            .ok_or_else(|| anyhow!("user {} not found", login_user))?;

        let ssh_dir = Path::new(&user.home_dir).join(".ssh");
        let (uid, gid) = (Uid::from_raw(user.uid), (Gid::from_raw(user.gid)));
        Self::ssh_write_pub_key(&ssh_dir, uid, gid)?;

        let rsa_key_path = Path::new(constants::DIR_ET_ETC)
            .join("ssh")
            .join("ssh_host_rsa_key");
        if let Err(Errno::NOENT) = stat(&rsa_key_path) {
            Self::ssh_keygen("rsa", &rsa_key_path)?;
        }

        let ed25519_key_path = Path::new(constants::DIR_ET_ETC)
            .join("ssh")
            .join("ssh_host_ed25519_key");
        if let Err(Errno::NOENT) = stat(&ed25519_key_path) {
            Self::ssh_keygen("ed25519", &ed25519_key_path)?;
        }

        Ok(())
    }

    fn ssh_keygen<P: AsRef<Path>>(key_type: &str, key_path: P) -> Result<()> {
        let path = Path::new(constants::DIR_ET_BIN).join("ssh-keygen");
        Command::new(path)
            .arg("-t")
            .arg(key_type)
            .arg("-f")
            .arg(key_path.as_ref())
            .arg("-N")
            .arg("")
            .status()
            .map_err(|e| anyhow!("unable to run ssh-keygen: {}", e))?;
        Ok(())
    }

    fn ssh_write_pub_key(dir: &Path, uid: Uid, gid: Gid) -> Result<()> {
        let pub_key = Self::get_ssh_key()?;
        let key_path = Path::new(dir).join("authorized_keys");
        let mut file = File::options()
            .create(true)
            .write(true)
            .truncate(true)
            .open(&key_path)
            .map_err(|e| anyhow!("unable to open {:?}: {}", key_path, e))?;
        chown(&key_path, Some(uid), Some(gid))
            .map_err(|e| anyhow!("unable to change ownership of {:?}: {}", key_path, e))?;
        chmod(&key_path, Mode::from(0o640))
            .map_err(|e| anyhow!("unable to change permissions on {:?}: {}", key_path, e))?;
        file.write_all(pub_key.as_bytes())
            .map_err(|e| anyhow!("unable to write {:?}: {}", key_path, e))?;
        Ok(())
    }

    // Return the login username for the system. If the image was built with ssh
    // enabled, this will be the name of the single directory under /.easyto/home.
    fn get_login_user() -> Result<String> {
        let dir_fd = File::open(constants::DIR_ET_HOME)?;
        for entry_res in Dir::read_from(dir_fd)? {
            let entry = entry_res?;
            let entry_name = entry.file_name().to_string_lossy().to_string();
            if entry_name == "." || entry_name == ".." {
                continue;
            }
            return Ok(entry_name);
        }
        Err(anyhow!("login user not found"))
    }

    fn get_ssh_key() -> Result<String> {
        Imds::default()
            .get_metadata(Path::new("public-keys/0/openssh-key"))
            .map_err(Into::into)
    }
}

pub struct SupervisorBase {
    main_ref: Arc<Mutex<dyn Service>>,
    readonly_root_fs: bool,
    service_refs: Vec<Arc<Mutex<dyn Service>>>,
    shutdown: bool,
    shutdown_grace_period: u64,
    shutdown_mutex: Mutex<()>,
}

impl SupervisorBase {
    fn is_kernel_thread<R: Read>(mut reader: R) -> Result<bool> {
        const FLAGS_FIELD_INDEX: usize = 8;
        const N_STAT_FIELDS: usize = 52;

        let mut buf = String::with_capacity(400);
        reader.read_to_string(&mut buf)?;
        let fields = buf.split_whitespace().collect::<Vec<&str>>();
        if fields.len() != N_STAT_FIELDS {
            return Err(anyhow!("wrong number of fields in process stat file"));
        }
        let flags_field = fields[FLAGS_FIELD_INDEX];
        let flags = flags_field.parse::<u32>()?;

        Ok(flags & PF_KTHREAD != 0)
    }

    fn kill(&self) -> Result<()> {
        self.signal(Signal::KILL)
    }

    // Return the PIDs of all current non-kernel processes excluding init.
    fn pids(&self) -> Result<Vec<u32>> {
        let mut pids = Vec::with_capacity(100);
        let dir_fd = File::open(constants::DIR_PROC)?;
        for dir_entry_res in Dir::read_from(dir_fd)? {
            let dir_entry = dir_entry_res?;
            if dir_entry.file_type() != FileType::Directory {
                continue;
            }
            let dir_name = dir_entry.file_name().to_string_lossy();
            if dir_name == "1" {
                continue; // Ignore ourself.
            }
            if let Ok(pid) = dir_name.parse::<u32>() {
                let stat_file_path = Path::new(constants::DIR_PROC)
                    .join(dir_name.to_string())
                    .join("stat");
                let f = match File::open(&stat_file_path) {
                    Ok(f) => f,
                    Err(e) if e.kind() == ErrorKind::NotFound => continue,
                    Err(e) => return Err(e.into()),
                };
                match Self::is_kernel_thread(f) {
                    Ok(false) => pids.push(pid),
                    Ok(true) => continue,
                    Err(e) => return Err(e),
                }
            }
        }
        Ok(pids)
    }

    fn start(&mut self) -> Result<()> {
        for service_ref in &self.service_refs {
            match start_service(service_ref.clone()) {
                Ok(_) => (),
                Err(e) => {
                    let service = service_ref.lock().unwrap();
                    if !service.optional() {
                        return Err(e);
                    } else {
                        info!(
                            "Optional service {} failed to start: {}",
                            &service.name(),
                            e
                        )
                    }
                }
            }
        }

        if self.readonly_root_fs {
            // Ensure services are initialized before remounting readonly.
            for service_ref in &self.service_refs {
                let init_rx = service_ref.lock().unwrap().init_rx().clone();
                let _ = init_rx.recv();
            }
            mount_remount(constants::DIR_ROOT, MountFlags::RDONLY, "")?;
        }

        start_main(self.main_ref.clone())
    }

    fn signal(&self, signal: Signal) -> Result<()> {
        for service_ref in &self.service_refs {
            service_ref.lock().unwrap().stop();
        }
        // Attempt to get all PIDs, but on error fall back to getting
        // just the tracked PIDs so a best-effort shutdown can be done.
        let pids = self.pids().unwrap_or_else(|_| self.tracked_pids());
        for pid in pids {
            if let Some(p) = Pid::from_raw(pid as i32) {
                match kill_process(p, signal) {
                    Ok(_) => (),
                    Err(Errno::SRCH) => (), // Process has already exited.
                    Err(e) => return Err(e.into()),
                }
            }
        }
        Ok(())
    }

    // This method should be called only once, but may be
    // called from multiple threads, hence the mutex.
    fn stop(&mut self, timeout_tx: Sender<()>) {
        {
            let _locked = self.shutdown_mutex.lock();
            if self.shutdown {
                return;
            } else {
                self.shutdown = true;
            }
        }

        info!("Shutting down all processes");
        if let Err(e) = self.signal(Signal::TERM) {
            error!("Error sending TERM signal: {}", e);
        }

        // Start the shutdown grace period countdown.
        let shutdown_grace_period = self.shutdown_grace_period;
        thread::spawn(move || {
            debug!(
                "Starting {} second shutdown grace period countdown",
                shutdown_grace_period
            );
            sleep(Duration::from_secs(shutdown_grace_period));
            let _ = timeout_tx.send(());
        });
    }

    // Return the PIDs of direct child processes started by the supervisor.
    fn tracked_pids(&self) -> Vec<u32> {
        let mut pids: Vec<u32> = self
            .service_refs
            .iter()
            .map(|service_ref| service_ref.lock().unwrap().pid())
            .filter(Option::is_some)
            .flatten()
            .collect();
        if let Some(main_pid) = self.main_ref.lock().unwrap().pid() {
            pids.push(main_pid);
        }
        pids
    }
}

pub struct Supervisor {
    base_ref: Arc<Mutex<SupervisorBase>>,
}

impl Supervisor {
    pub fn new(vmspec: VmSpec, command: Vec<String>, env: NameValues) -> Result<Self> {
        let (uid, gid) = (
            Uid::from_raw(vmspec.security.run_as_user_id.unwrap()),
            Gid::from_raw(vmspec.security.run_as_group_id.unwrap()),
        );
        let working_dir = vmspec.working_dir.clone();
        let main = Main::new(command, working_dir, env, gid, uid);

        let service_refs = find_enabled_services(
            Path::new(constants::DIR_ET_SERVICES),
            &vmspec.disable_services,
        )?;

        let readonly_root_fs = vmspec.security.readonly_root_fs.unwrap_or_default();
        let shutdown_grace_period = vmspec.shutdown_grace_period;

        drop(vmspec);

        Ok(Self {
            base_ref: Arc::new(Mutex::new(SupervisorBase {
                main_ref: Arc::new(Mutex::new(main)),
                readonly_root_fs,
                service_refs,
                shutdown: false,
                shutdown_grace_period,
                shutdown_mutex: Mutex::new(()),
            })),
        })
    }

    pub fn start(&self) -> Result<()> {
        self.base_ref.lock().unwrap().start()
    }

    pub fn wait(&mut self) {
        let (done_tx, done_rx) = bounded(1);
        let (timeout_tx, timeout_rx) = bounded(1);

        let wait_poweroff_base_ref = self.base_ref.clone();
        let wait_poweroff_timeout_tx = timeout_tx.clone();
        thread::spawn(move || {
            debug!("Starting thread to wait for a poweroff signal");
            Self::wait_poweroff(wait_poweroff_base_ref, wait_poweroff_timeout_tx);
        });

        let wait_main_base_ref = self.base_ref.clone();
        let wait_main_timeout_tx = timeout_tx.clone();
        thread::spawn(move || {
            debug!("Starting thread to wait for the main process");
            Self::wait_main(wait_main_base_ref, wait_main_timeout_tx);
        });

        let main_start_rx = self.main_start_rx();
        thread::spawn(move || {
            debug!("Starting thread to reap child processes");
            Self::wait_children(main_start_rx, done_tx);
        });

        let mut stopped = false;
        let mut select = Select::new();
        select.recv(&done_rx);
        select.recv(&timeout_rx);

        while !stopped {
            match select.ready() {
                0 => {
                    info!("All processes have exited");
                    stopped = true;
                }
                1 => {
                    info!("Timeout waiting for a graceful shutdown");
                    let _ = self.base_ref.lock().unwrap().kill();
                    stopped = true;
                }
                _ => unreachable!(),
            }
        }
    }

    fn main_start_rx(&self) -> Receiver<()> {
        self.base_ref
            .lock()
            .unwrap()
            .main_ref
            .lock()
            .unwrap()
            .start_rx()
            .clone()
    }

    // Wait for a poweroff signal. If one is received, trigger a shutdown of all processes.
    fn wait_poweroff(base_ref: Arc<Mutex<SupervisorBase>>, timeout_tx: Sender<()>) {
        let mut signals = Signals::new([SIGPOWEROFF]).unwrap();
        signals.forever().next();
        base_ref.lock().unwrap().stop(timeout_tx);
        signals.handle().close();
    }

    // Wait for the main process to exit. If it does, trigger a shutdown of all processes.
    fn wait_main(base_ref: Arc<Mutex<SupervisorBase>>, timeout_tx: Sender<()>) {
        let stop_rx = base_ref
            .lock()
            .unwrap()
            .main_ref
            .lock()
            .unwrap()
            .stop_rx()
            .clone();
        let err = match wait_stop(stop_rx) {
            Ok(_) => None,
            Err(e) if e.raw_os_error() == Some(10) => None, // ECHILD
            Err(e) => Some(e),
        };
        if err.is_some() {
            info!("Main process exited with error: {:?}", err.unwrap());
        } else {
            info!("Main process exited");
        }
        base_ref.lock().unwrap().stop(timeout_tx);
    }

    // Reap child processes. If none are left, write a message to the done channel.
    fn wait_children(main_start_rx: Receiver<()>, done_tx: Sender<()>) {
        // Don't start reaping processes until the main process has started,
        // otherwise the system may shut down before it starts, especially
        // in cases where there are no services besides the main process.
        let _ = main_start_rx.recv();
        debug!("Finished waiting for the main process to start");

        loop {
            let wait_status = wait(WaitOptions::empty());
            debug!("Reaped process: {:?}", &wait_status);
            if let Err(Errno::CHILD) = wait_status {
                break;
            }
        }
        let _ = done_tx.send(());
    }
}

fn start_main(service_ref: Arc<Mutex<dyn Service>>) -> Result<()> {
    {
        let service = service_ref.lock().unwrap();
        info!("Starting main process {:?}", service.base().args);
    }

    let thread_service_ref = service_ref.clone();

    thread::spawn(move || {
        let mut cmd = thread_service_ref.lock().unwrap().command();
        let result = cmd.spawn();
        let _ = thread_service_ref.lock().unwrap().start_tx().send(());
        match result {
            Err(e) => {
                let _ = thread_service_ref.lock().unwrap().stop_tx().send(Err(e));
            }
            Ok(mut child) => {
                thread_service_ref.lock().unwrap().base_mut().pid = Some(child.id());
                let wait_result = child.wait();
                let _ = thread_service_ref
                    .lock()
                    .unwrap()
                    .stop_tx()
                    .send(wait_result);
            }
        }
    });

    Ok(())
}

fn start_service(service_ref: Arc<Mutex<dyn Service>>) -> Result<()> {
    let result = match service_ref.lock().unwrap().init_fn() {
        Some(init_fn) => init_fn(),
        None => Ok(()),
    };
    let _ = service_ref.lock().unwrap().init_tx().send(());
    result?;

    let thread_service_ref = service_ref.clone();

    thread::spawn(move || {
        let oncer = Once::new();

        loop {
            let mut cmd = thread_service_ref.lock().unwrap().command();
            debug!(
                "Starting service: {:?} {:?}",
                cmd.get_program(),
                cmd.get_args()
            );
            let result = match cmd.spawn() {
                Err(e) => {
                    if thread_service_ref.lock().unwrap().is_shutdown() {
                        let _ = thread_service_ref.lock().unwrap().stop_tx().send(Err(e));
                        return;
                    }
                    Err(e)
                }
                Ok(mut child) => {
                    thread_service_ref.lock().unwrap().base_mut().pid = Some(child.id());
                    let oncer_service_ref = thread_service_ref.clone();
                    oncer.call_once(move || {
                        let _ = oncer_service_ref.lock().unwrap().start_tx().send(());
                    });
                    let wait_result = child.wait();
                    if thread_service_ref.lock().unwrap().is_shutdown() {
                        let _ = thread_service_ref
                            .lock()
                            .unwrap()
                            .stop_tx()
                            .send(wait_result);
                        return;
                    }
                    wait_result
                }
            };
            info!(
                "Service {} exited, will restart. Exit status: {:?}",
                thread_service_ref.lock().unwrap().name(),
                result
            );
            sleep(Duration::from_secs(5));
        }
    });
    Ok(())
}

fn find_enabled_services(
    path: &Path,
    disabled_services: &[String],
) -> Result<Vec<Arc<Mutex<dyn Service>>>> {
    let mut services: Vec<Arc<Mutex<dyn Service>>> = Vec::new();
    let fd = File::open(path)?;
    for entry_res in Dir::read_from(fd)? {
        let entry = entry_res?;
        let entry_name = entry.file_name().to_string_lossy().to_string();
        if entry_name == "." || entry_name == ".." {
            continue;
        } else if disabled_services.contains(&entry_name) {
            info!("Disabling service {}", entry_name);
            continue;
        } else if entry_name == "chrony" {
            services.push(Arc::new(Mutex::new(Chrony::new())));
        } else if entry_name == "ssh" {
            services.push(Arc::new(Mutex::new(Ssh::new())));
        } else {
            warn!("Unknown service {}", entry_name);
        }
    }
    Ok(services)
}
