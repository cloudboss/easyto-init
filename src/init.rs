use std::collections::HashMap;
use std::ffi::{c_char, CStr, CString};
use std::fs::File;
use std::io::{BufRead, BufReader, Read};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Arc;
use std::thread;
use std::time::Duration;

use anyhow::{anyhow, Result};
use base64::prelude::*;
use crossbeam::channel::{bounded, Select};
use crossbeam::sync::WaitGroup;
use k8s_expand::{expand, mapping_func_for};
use log::{debug, error, info, Level};
use minaws::imds::{Credentials, Imds};
use rustix::fs::{chown, remount, stat, symlink, unmount, Gid, Mode, Uid, UnmountFlags};
use rustix::io::Errno;
use rustix::mount::{mount, MountFlags};
use rustix::process::{chdir, umask};
use rustix::runtime::execve;
use rustix::thread::{set_thread_gid, set_thread_uid};

use crate::aws::asm::AsmClient;
use crate::aws::s3::S3Client;
use crate::aws::ssm::SsmClient;
use crate::fs::{mkdir_p, Link, Mount};
use crate::service::Supervisor;
use crate::system::{device_has_fs, link_nvme_devices, resize_root_volume};
use crate::vmspec::{
    EbsVolumeSource, EnvFromSources, ImdsEnvSource, NameValue, NameValues, NameValuesExt,
    S3EnvSource, S3VolumeSource, SecretsManagerEnvSource, SecretsManagerVolumeSource, SsmEnvSource,
    SsmVolumeSource, UserData, VmSpec,
};
use crate::writable::Writable;
use crate::{constants, container};

pub fn initialize() -> Result<()> {
    let base_dir = "/";

    let imds_client = Imds::default();
    let user_data =
        UserData::from_imds(&imds_client).map_err(|e| anyhow!("unable to get user data: {}", e))?;

    simple_logger::init_with_level(if user_data.debug.unwrap_or_default() {
        Level::Trace
    } else {
        Level::Info
    })
    .map_err(|e| anyhow!("unable to initialize logger: {}", e))?;
    debug!("Initialized logger");

    base_mounts()?;
    base_links()?;
    link_nvme_devices()?;

    let config_file_path = Path::new(constants::DIR_ET).join(constants::FILE_METADATA);
    let config_file = read_config_file(&config_file_path).map_err(|e| {
        anyhow!(
            "unable to read image config file {:?}: {}",
            config_file_path,
            e
        )
    })?;
    let mut vmspec = VmSpec::from_config_file(&config_file)
        .map_err(|e| anyhow!("unable to configure instance: {}", e))?;
    vmspec.merge_user_data(user_data);
    debug!("VM spec: {:?}", vmspec);

    vmspec.set_sysctls(base_dir)?;
    let aws_region = imds_client
        .get_region()
        .map_err(|e| anyhow!("unable to get AWS region from IMDS: {}", e))?;
    debug!("AWS region: {}", aws_region);

    resize_root_volume().map_err(|e| anyhow!("unable to resize root volume: {}", e))?;

    let credentials = imds_client
        .get_credentials()
        .map_err(|e| anyhow!("unable to get AWS credentials from IMDS: {}", e))?;
    for volume in &vmspec.volumes {
        debug!("Processing volume {:?}", volume);
        if let Some(source) = &volume.ebs {
            handle_volume_ebs(source)?;
        }
        if let Some(source) = &volume.s3 {
            handle_volume_s3(
                Path::new(base_dir),
                source,
                credentials.clone(),
                &aws_region,
            )?;
        }
        if let Some(source) = &volume.secrets_manager {
            handle_volume_secretsmanager(
                Path::new(base_dir),
                source,
                credentials.clone(),
                &aws_region,
            )?;
        }
        if let Some(source) = &volume.ssm {
            handle_volume_ssm(
                Path::new(base_dir),
                source,
                credentials.clone(),
                &aws_region,
            )?;
        }
    }

    let resolved_env = resolve_all_envs(
        &imds_client,
        credentials,
        &aws_region,
        &vmspec.env,
        &vmspec.env_from,
    )
    .map_err(|e| {
        anyhow!(
            "unable to resolve environment variables from external sources: {}",
            e
        )
    })?;
    debug!("Resolved environment: {:?}", resolved_env);

    let command = vmspec.full_command(&resolved_env)?;
    debug!("Full command: {:?}", command);

    vmspec.run_init_scripts(base_dir, &resolved_env)?;

    if vmspec.replace_init {
        replace_init(vmspec, command, resolved_env)?;
    } else {
        supervise(vmspec, command, resolved_env)?;
    }

    Ok(())
}

fn base_links() -> Result<()> {
    let ls = vec![
        Link {
            target: "/proc/self/fd",
            path: "/dev/fd",
        },
        Link {
            target: "/proc/self/fd/0",
            path: "/dev/stdin",
        },
        Link {
            target: "/proc/self/fd/1",
            path: "/dev/stdout",
        },
        Link {
            target: "/proc/self/fd/2",
            path: "/dev/stderr",
        },
    ];
    for l in ls {
        debug!("Linking {} to {}", l.target, l.path);
        symlink(l.target, l.path)
            .map_err(|e| anyhow!("unable to link {} to {}: {}", l.target, l.path, e))?;
    }
    Ok(())
}

fn base_mounts() -> Result<()> {
    let ms = vec![
        Mount {
            source: "devtmpfs",
            flags: MountFlags::NOSUID,
            fs_type: "devtmpfs",
            mode: Mode::from(0o755),
            options: None,
            target: PathBuf::from(constants::DIR_DEV),
        },
        Mount {
            source: "devpts",
            flags: MountFlags::NOATIME | MountFlags::NOEXEC | MountFlags::NOSUID,
            fs_type: "devpts",
            mode: Mode::from(0o755),
            options: Some("mode=0620,gid=5,ptmxmode=666"),
            target: PathBuf::from(constants::DIR_DEV_PTS),
        },
        Mount {
            source: "mqueue",
            flags: MountFlags::NODEV | MountFlags::NOEXEC | MountFlags::NOSUID,
            fs_type: "mqueue",
            mode: Mode::from(0o755),
            options: None,
            target: PathBuf::from(constants::DIR_DEV_MQUEUE),
        },
        Mount {
            source: "tmpfs",
            flags: MountFlags::NODEV | MountFlags::NOSUID,
            fs_type: "tmpfs",
            mode: Mode::from(0o1777),
            options: None,
            target: PathBuf::from(constants::DIR_DEV_SHM),
        },
        Mount {
            source: "hugetlbfs",
            flags: MountFlags::RELATIME,
            fs_type: "hugetlbfs",
            mode: Mode::from(0o755),
            options: None,
            target: PathBuf::from(constants::DIR_DEV_HUGEPAGES),
        },
        Mount {
            source: "proc",
            flags: MountFlags::NODEV
                | MountFlags::NOEXEC
                | MountFlags::RELATIME
                | MountFlags::NOSUID,
            fs_type: "proc",
            mode: Mode::from(0o555),
            options: None,
            target: PathBuf::from(constants::DIR_PROC),
        },
        Mount {
            source: "sys",
            flags: MountFlags::NODEV | MountFlags::NOEXEC | MountFlags::NOSUID,
            fs_type: "sysfs",
            mode: Mode::from(0o555),
            options: None,
            target: PathBuf::from(constants::DIR_SYS),
        },
        Mount {
            source: "tmpfs",
            flags: MountFlags::NODEV | MountFlags::NOSUID,
            fs_type: "tmpfs",
            mode: Mode::from(0o755),
            options: Some("mode=0755"),
            target: PathBuf::from(constants::DIR_ET_RUN),
        },
        Mount {
            source: "cgroup2",
            flags: MountFlags::NODEV
                | MountFlags::NOEXEC
                | MountFlags::RELATIME
                | MountFlags::NOSUID,
            fs_type: "cgroup2",
            mode: Mode::from(0o555),
            options: Some("nsdelegate"),
            target: PathBuf::from(constants::DIR_SYS_FS_CGROUP),
        },
        Mount {
            source: "debugfs",
            flags: MountFlags::NODEV
                | MountFlags::NOEXEC
                | MountFlags::RELATIME
                | MountFlags::NOSUID,
            fs_type: "debugfs",
            mode: Mode::from(0o500),
            options: None,
            target: PathBuf::from(constants::DIR_SYS_KERNEL_DEBUG),
        },
    ];

    let old_mask = umask(Mode::empty());
    for m in ms {
        debug!("Processing mount {:?}", m);
        m.execute()?;
    }
    umask(old_mask);
    Ok(())
}

fn read_config_file(path: &Path) -> Result<container::ConfigFile> {
    let config = File::open(path).and_then(|f| serde_json::from_reader(f).map_err(Into::into))?;
    Ok(config)
}

fn parse_mode(mode: &str) -> Result<Mode> {
    let m = u32::from_str_radix(mode, 8)?;
    Ok(Mode::from(m))
}

fn handle_volume_ebs(volume: &EbsVolumeSource) -> Result<()> {
    info!("Handling volume {:?}", volume);

    if volume.device.is_empty() {
        return Err(anyhow!("volume must have a device"));
    }

    if volume.fs_type.is_none() {
        return Err(anyhow!("volume must have a filesystem type"));
    }

    if volume.mount.destination.is_empty() {
        return Err(anyhow!("volume must have a mount point"));
    }

    let mode = parse_mode(volume.mount.mode.as_ref().unwrap())?;
    debug!("Parsed mode, before: {:?}, after: {:?}", volume, mode);

    mkdir_p(&volume.mount.destination, mode)?;
    debug!("Created mount point {:?}", volume.mount.destination);

    let (owner, group) = unsafe {
        (
            volume.mount.user_id.map(|u| Uid::from_raw(u)),
            volume.mount.group_id.map(|g| Gid::from_raw(g)),
        )
    };
    chown(&volume.mount.destination, owner, group).map_err(|e| {
        anyhow!(
            "unable to change ownership of {}: {}",
            &volume.mount.destination,
            e
        )
    })?;
    debug!(
        "Changed ownership of mount point {:?}",
        volume.mount.destination
    );

    try_mkfs(&volume.device, volume.fs_type.as_ref().unwrap())?;

    mount(
        &volume.device,
        &volume.mount.destination,
        volume.fs_type.as_ref().unwrap(),
        MountFlags::empty(),
        "",
    )
    .map_err(|e| {
        anyhow!(
            "unable to mount {} on {}: {}",
            &volume.device,
            &volume.mount.destination,
            e
        )
    })?;
    info!(
        "Mounted volume {} on {}",
        &volume.device, &volume.mount.destination
    );

    Ok(())
}

fn try_mkfs(device: &str, fs_type: &str) -> Result<()> {
    let has_fs = device_has_fs(Path::new(device))
        .map_err(|e| anyhow!("unable to check if {} has a filesystem: {}", device, e))?;
    if !has_fs {
        let mkfs_path = Path::new(constants::DIR_ET_SBIN).join(format!("mkfs.{}", fs_type));
        match stat(&mkfs_path) {
            Err(Errno::NOENT) => {
                return Err(anyhow!("unsupported filesystem {} for {}", fs_type, device));
            }
            Err(e) => {
                return Err(anyhow!("unable to stat {:?}: {}", mkfs_path, e));
            }
            Ok(_) => {
                Command::new(&mkfs_path)
                    .arg(device)
                    .output()
                    .map_err(|e| anyhow!("unable to create a filesystem on {}: {}", device, e))?;
            }
        }
        info!("Created filesystem on device {:?}", device);
    }
    Ok(())
}

fn handle_volume_ssm(
    base_dir: &Path,
    volume: &SsmVolumeSource,
    credentials: Credentials,
    region: &str,
) -> Result<()> {
    let client = SsmClient::new(credentials, region)?;
    match client.get_parameter_list(&volume.path) {
        Ok(mut parameters) => {
            debug!("SSM parameters: {:?}", parameters);
            for parameter in parameters.iter_mut() {
                let dest = Path::new(base_dir).join(&volume.mount.destination);
                parameter.write(
                    dest.as_path(),
                    volume.mount.user_id.unwrap(),
                    volume.mount.group_id.unwrap(),
                )?;
            }
            Ok(())
        }
        Err(e) if volume.optional.unwrap_or_default() => {
            debug!("volume {} is optional, skipping: {}", volume.path, e);
            Ok(())
        }
        Err(e) => Err(e),
    }
}

fn handle_volume_secretsmanager(
    base_dir: &Path,
    volume: &SecretsManagerVolumeSource,
    credentials: Credentials,
    region: &str,
) -> Result<()> {
    let client = AsmClient::new(credentials, region)?;
    match client.get_secret_list(&volume.secret_id) {
        Ok(mut secrets) => {
            debug!("Secrets Manager secrets: {:?}", secrets);
            for secret in secrets.iter_mut() {
                let dest = Path::new(base_dir).join(&volume.mount.destination);
                secret.write(
                    dest.as_path(),
                    volume.mount.user_id.unwrap(),
                    volume.mount.group_id.unwrap(),
                )?;
            }
            Ok(())
        }
        Err(e) if volume.optional.unwrap_or_default() => {
            debug!("volume {} is optional, skipping: {}", volume.secret_id, e);
            Ok(())
        }
        Err(e) => Err(e),
    }
}

fn handle_volume_s3(
    base_dir: &Path,
    volume: &S3VolumeSource,
    credentials: Credentials,
    region: &str,
) -> Result<()> {
    let client = S3Client::new(credentials, region)
        .map_err(|e| anyhow!("unable to create S3 client: {}", e))?;
    let s3_url = format!("s3://{}/{}", volume.bucket, volume.key_prefix);
    match client.get_object_list(&volume.bucket, &volume.key_prefix) {
        Ok(mut objects) => {
            debug!("S3 objects: {:?}", objects);
            for object in objects.iter_mut() {
                let dest = Path::new(base_dir).join(&volume.mount.destination);
                debug!("S3 object dest: {:?}", &dest);
                object
                    .write(
                        dest.as_path(),
                        volume.mount.user_id.unwrap(),
                        volume.mount.group_id.unwrap(),
                    )
                    .map_err(|e| {
                        anyhow!("unable to write S3 object {} to {:?}: {}", s3_url, dest, e)
                    })?;
            }
            Ok(())
        }
        Err(e) if volume.optional.unwrap_or_default() => {
            debug!("volume {} is optional, skipping: {}", s3_url, e);
            Ok(())
        }
        Err(e) => Err(anyhow!(
            "unable to list S3 objects in bucket {}: {}",
            &volume.bucket,
            e
        )),
    }
}

fn resolve_env_from<GetBytes, GetMap>(
    name: &str,
    b64_encode: bool,
    get_bytes: GetBytes,
    get_map: GetMap,
) -> Result<NameValues>
where
    GetBytes: FnOnce() -> Result<Vec<u8>>,
    GetMap: FnOnce() -> Result<HashMap<String, String>>,
{
    if !name.is_empty() {
        let buf = get_bytes()?;
        let value = if b64_encode {
            BASE64_STANDARD.encode(&buf)
        } else {
            String::from_utf8(buf)?
        };
        let nv = vec![NameValue {
            name: name.into(),
            value,
        }];
        debug!("Resolved NameValue: {:?}", nv);
        Ok(nv)
    } else {
        get_map().map(|m| {
            debug!("Map: {:?}", m);
            m.iter()
                .map(|(k, v)| NameValue {
                    name: k.clone(),
                    value: v.clone(),
                })
                .collect()
        })
    }
}

fn resolve_env_from_imds(source: &ImdsEnvSource, imds: &Imds) -> Result<NameValues> {
    let value = imds.get_metadata(Path::new(&source.path))?;
    let nv = NameValue {
        name: source.name.clone(),
        value,
    };
    Ok(vec![nv])
}

fn resolve_env_from_s3(
    source: &S3EnvSource,
    credentials: Credentials,
    region: &str,
) -> Result<NameValues> {
    let get_bytes = || {
        let client = S3Client::new(credentials.clone(), region)?;
        client.get_object_bytes(&source.bucket, &source.key)
    };
    let get_map = || {
        let client = S3Client::new(credentials.clone(), region)?;
        client.get_object_map(&source.bucket, &source.key)
    };
    resolve_env_from(
        source.name.as_ref().unwrap_or(&"".into()),
        source.base64_encode.unwrap_or_default(),
        get_bytes,
        get_map,
    )
}

fn resolve_env_from_secretsmanager(
    source: &SecretsManagerEnvSource,
    credentials: Credentials,
    region: &str,
) -> Result<NameValues> {
    let client = &AsmClient::new(credentials, region)?;
    let get_bytes = || client.get_secret_value(&source.secret_id);
    let get_map = || client.get_secret_map(&source.secret_id);
    resolve_env_from(
        source.name.as_ref().unwrap_or(&"".into()),
        source.base64_encode.unwrap_or_default(),
        get_bytes,
        get_map,
    )
}

fn resolve_env_from_ssm(
    source: &SsmEnvSource,
    credentials: Credentials,
    region: &str,
) -> Result<NameValues> {
    let client = &SsmClient::new(credentials, region)?;
    let get_bytes = || client.get_parameter_value(&source.path);
    let get_map = || client.get_parameter_map(&source.path);
    resolve_env_from(
        source.name.as_ref().unwrap_or(&"".into()),
        source.base64_encode.unwrap_or_default(),
        get_bytes,
        get_map,
    )
}

fn resolve_all_envs(
    imds: &Imds,
    credentials: Credentials,
    region: &str,
    env: &NameValues,
    env_from: &EnvFromSources,
) -> Result<NameValues> {
    let mut resolved_env = Vec::with_capacity(env_from.len());

    for source in env_from.iter() {
        if let Some(imds_source) = &source.imds {
            match resolve_env_from_imds(imds_source, imds) {
                Ok(imds_env) => resolved_env.extend(imds_env),
                Err(_) if imds_source.optional.unwrap_or_default() => (),
                Err(e) => return Err(e),
            }
        }
        if let Some(s3_source) = &source.s3 {
            match resolve_env_from_s3(s3_source, credentials.clone(), region) {
                Ok(s3_env) => resolved_env.extend(s3_env),
                Err(_) if s3_source.optional.unwrap_or_default() => (),
                Err(e) => return Err(e),
            }
        }
        if let Some(asm_source) = &source.secrets_manager {
            match resolve_env_from_secretsmanager(asm_source, credentials.clone(), region) {
                Ok(asm_env) => resolved_env.extend(asm_env),
                Err(_) if asm_source.optional.unwrap_or_default() => (),
                Err(e) => return Err(e),
            }
        }
        if let Some(ssm_source) = &source.ssm {
            match resolve_env_from_ssm(ssm_source, credentials.clone(), region) {
                Ok(ssm_env) => resolved_env.extend(ssm_env),
                Err(_) if ssm_source.optional.unwrap_or_default() => (),
                Err(e) => return Err(e),
            }
        }
    }

    let mut all_env: NameValues = expand_env(env, &resolved_env);
    debug!("Expanded environment: {:?}", &all_env);

    all_env.extend(resolved_env);
    debug!("Resolved environment after extending: {:?}", all_env);

    if (&all_env).find("PATH").is_none() {
        all_env.push(NameValue {
            name: "PATH".into(),
            value: constants::ENV_PATH.into(),
        });
    }

    Ok(all_env)
}

fn expand_env(env: &NameValues, resolved_env: &NameValues) -> NameValues {
    let env_refs = HashMap::from_iter(env.to_map_rc());
    let resolved_env_refs = HashMap::from_iter(resolved_env.to_map_rc());

    let maps = vec![&env_refs, &resolved_env_refs];
    let mapping = mapping_func_for(&maps);

    env.iter()
        .map(|nv| NameValue {
            name: nv.name.clone(),
            value: expand(&nv.value, &mapping),
        })
        .collect()
}

fn replace_init(vmspec: VmSpec, command: Vec<String>, env: NameValues) -> Result<()> {
    if command.is_empty() {
        return Err(anyhow!("command is empty"));
    }

    if let Some(true) = vmspec.security.readonly_root_fs {
        remount(constants::DIR_ROOT, MountFlags::RDONLY, "")
            .map_err(|e| anyhow!("unable to remount root filesystem as readonly: {}", e))?;
    }

    chdir(&vmspec.working_dir)
        .map_err(|e| anyhow!("unable to chdir to {}: {}", &vmspec.working_dir, e))?;

    let (uid, gid) = unsafe {
        (
            Uid::from_raw(vmspec.security.run_as_user_id.unwrap()),
            Gid::from_raw(vmspec.security.run_as_group_id.unwrap()),
        )
    };
    // This calls setgid and setuid only for the current thread, but since this thread
    // is calling execve(), the new process will inherit the new user and group.
    set_thread_gid(gid).map_err(|e| {
        anyhow!(
            "unable to setgid to {}: {}",
            vmspec.security.run_as_group_id.unwrap(),
            e
        )
    })?;
    set_thread_uid(uid).map_err(|e| {
        anyhow!(
            "unable to setuid to {}: {}",
            vmspec.security.run_as_user_id.unwrap(),
            e
        )
    })?;

    exec(command, env)
}

fn exec(command: Vec<String>, env: Vec<NameValue>) -> Result<(), anyhow::Error> {
    let argv_cstrings: Vec<CString> = command
        .into_iter()
        .map(|arg| CString::new(arg).unwrap())
        .collect();
    let mut argv_ptrs: Vec<*const c_char> = argv_cstrings.iter().map(|arg| arg.as_ptr()).collect();
    argv_ptrs.push(std::ptr::null());
    let argv = argv_ptrs.as_ptr() as *const *const u8;

    let env_cstrings: Vec<CString> = (&env)
        .to_env_strings()
        .into_iter()
        .map(|ev| CString::new(ev).unwrap())
        .collect();
    let mut env_ptrs: Vec<*const c_char> = env_cstrings.iter().map(|ev| ev.as_ptr()).collect();
    env_ptrs.push(std::ptr::null());
    let envp = env_ptrs.as_ptr() as *const *const u8;

    let errno = unsafe {
        let path = CStr::from_ptr(argv_cstrings[0].as_ptr());
        execve(path, argv, envp)
    };

    if errno.raw_os_error() != 0 {
        return Err(anyhow!("unable to run command: {}", errno));
    }
    Ok(())
}

fn supervise(vmspec: VmSpec, command: Vec<String>, env: NameValues) -> Result<()> {
    // Collect the EBS mount points for later, before the supervisor drops the VmSpec.
    let mount_points: Vec<String> = vmspec
        .volumes
        .iter()
        .filter(|v| v.ebs.is_some())
        .map(|v| v.ebs.as_ref().unwrap().mount.destination.clone())
        .collect();

    let mut supervisor = Supervisor::new(vmspec, command, env)?;
    supervisor.start()?;
    supervisor.wait();

    unmount_all(&mount_points)?;
    wait_for_unmounts(
        &Path::new(constants::DIR_PROC).join("mounts"),
        &mount_points,
        Duration::from_secs(10),
    )
}

fn unmount_all(mount_points: &[String]) -> Result<()> {
    let mut error_count = 0;

    if let Err(e) = remount(constants::DIR_ROOT, MountFlags::RDONLY, "") {
        error_count += 1;
        error!(
            "unable to remount {} as read-only: {}",
            constants::DIR_ROOT,
            e
        );
    }

    for mount_point in mount_points {
        if let Err(e) = unmount(mount_point, UnmountFlags::empty()) {
            error_count += 1;
            error!("unable to unmount {}: {}", mount_point, e);
        }
    }

    if error_count == mount_points.len() + 1 {
        // Only return an error if all unmounts failed so we can wait
        // for those that did not fail.
        return Err(anyhow!("unable to unmount filesystems"));
    }

    Ok(())
}

fn wait_for_unmounts(mtab: &Path, mount_points: &[String], timeout: Duration) -> Result<()> {
    let mtab_file = File::open(mtab)?;

    let mtab_file_ref = Arc::new(mtab_file);
    let wait_group = WaitGroup::new();
    let (timeout_tx, timeout_rx) = bounded::<()>(1);
    let (done_tx, done_rx) = bounded::<()>(1);

    // Start a thread for each mount point check.
    for mount_point in mount_points {
        let mp = mount_point.clone();
        let reader = mtab_file_ref.clone();
        let wg = wait_group.clone();

        thread::spawn(move || {
            loop {
                match is_mounted(&mp, reader.clone()) {
                    Err(e) => {
                        error!("Unable to check if {} is mounted: {}", &mp, e);
                        break;
                    }
                    Ok(false) => break,
                    Ok(true) => thread::sleep(Duration::from_secs(1)),
                }
            }
            drop(wg);
        });
    }

    // Start a thread to wait for the unmounts.
    thread::spawn(move || {
        wait_group.wait();
        let _ = done_tx.send(());
    });

    // Start the timeout countdown.
    thread::spawn(move || {
        thread::sleep(timeout);
        let _ = timeout_tx.send(());
    });

    let mut select = Select::new();
    select.recv(&done_rx);
    select.recv(&timeout_rx);

    match select.ready() {
        0 => {
            info!("All filesystems unmounted");
            Ok(())
        }
        1 => Err(anyhow!("Timeout waiting for filesystems to unmount")),
        _ => unreachable!(),
    }
}

fn is_mounted<R: Read>(mount_point: &str, mtab_reader: R) -> Result<bool> {
    let buf_reader = BufReader::new(mtab_reader);
    let lines = buf_reader.lines();
    for line in lines.map_while(Result::ok) {
        let mut fields = line.split_whitespace();
        if fields.next().is_none() {
            continue; // Ignore empty line.
        }
        let mount_point_field = fields
            .next()
            .ok_or_else(|| anyhow!("invalid line in mtab: {}", line))?;
        if mount_point_field == mount_point {
            return Ok(true);
        }
    }
    Ok(false)
}

#[cfg(test)]
mod test {
    use pretty_assertions::assert_eq;

    use super::*;

    #[test]
    fn test_parse_mode() {
        struct Case<'a> {
            err: bool,
            mode: &'a str,
            expected: Mode,
        }
        let cases = [
            Case {
                err: true,
                mode: "",
                expected: Mode::from(0),
            },
            Case {
                err: true,
                mode: "abc",
                expected: Mode::from(0),
            },
            Case {
                err: false,
                mode: "0",
                expected: Mode::from(0),
            },
            Case {
                err: false,
                mode: "0755",
                expected: Mode::from(0o755),
            },
        ];
        for case in cases {
            let mode = parse_mode(case.mode);
            if case.err {
                assert_eq!(mode.is_err(), case.err);
            } else {
                assert_eq!(case.expected, mode.unwrap());
            }
        }
    }

    #[test]
    fn test_is_mounted() {
        struct Case<'a> {
            err: bool,
            expected: bool,
            mtab: &'a str,
            mount_point: &'a str,
        }
        let cases = [
            Case {
                err: false,
                expected: false,
                mtab: "",
                mount_point: "/dev",
            },
            Case {
                err: true,
                expected: false,
                mtab: r#"
                  devtmpfs/devdevtmpfsrw,seclabel,nosuid,size=4096k,nr_inodes=4074091,mode=755,inode6400
                  tmpfs/dev/shmtmpfsrw,seclabel,nosuid,nodev,inode6400
                  devpts/dev/ptsdevptsrw,seclabel,nosuid,noexec,relatime,gid=5,mode=620,ptmxmode=00000
                  sysfs/syssysfsrw,seclabel,nosuid,nodev,noexec,relatime00
                  securityfs/sys/kernel/securitysecurityfsrw,nosuid,nodev,noexec,relatime00
                  cgroup2/sys/fs/cgroupcgroup2rw,seclabel,nosuid,nodev,noexec,relatime,nsdelegate,memory_recursiveprot00
                  proc/procprocrw,nosuid,nodev,noexec,relatime00
                "#,
                mount_point: "/dev",
            },
            Case {
                err: false,
                expected: true,
                mtab: r#"
                  devtmpfs /dev devtmpfs rw,seclabel,nosuid,size=4096k,nr_inodes=4074091,mode=755,inode64 0 0
                  tmpfs /dev/shm tmpfs rw,seclabel,nosuid,nodev,inode64 0 0
                  devpts /dev/pts devpts rw,seclabel,nosuid,noexec,relatime,gid=5,mode=620,ptmxmode=000 0 0
                  sysfs /sys sysfs rw,seclabel,nosuid,nodev,noexec,relatime 0 0
                  securityfs /sys/kernel/security securityfs rw,nosuid,nodev,noexec,relatime 0 0
                  cgroup2 /sys/fs/cgroup cgroup2 rw,seclabel,nosuid,nodev,noexec,relatime,nsdelegate,memory_recursiveprot 0 0
                  proc /proc proc rw,nosuid,nodev,noexec,relatime 0 0
                "#,
                mount_point: "/dev",
            },
            Case {
                err: false,
                expected: false,
                mtab: r#"
                  devtmpfs /dev devtmpfs rw,seclabel,nosuid,size=4096k,nr_inodes=4074091,mode=755,inode64 0 0
                  tmpfs /dev/shm tmpfs rw,seclabel,nosuid,nodev,inode64 0 0
                  devpts /dev/pts devpts rw,seclabel,nosuid,noexec,relatime,gid=5,mode=620,ptmxmode=000 0 0
                  sysfs /sys sysfs rw,seclabel,nosuid,nodev,noexec,relatime 0 0
                  securityfs /sys/kernel/security securityfs rw,nosuid,nodev,noexec,relatime 0 0
                  cgroup2 /sys/fs/cgroup cgroup2 rw,seclabel,nosuid,nodev,noexec,relatime,nsdelegate,memory_recursiveprot 0 0
                  proc /proc proc rw,nosuid,nodev,noexec,relatime 0 0
                "#,
                mount_point: "/notfound",
            },
        ];
        for case in cases {
            let reader = case.mtab.as_bytes();
            let mounted = is_mounted(case.mount_point, reader);
            if case.err {
                assert!(mounted.is_err());
            } else {
                assert_eq!(case.expected, mounted.unwrap());
            }
        }
    }
}
