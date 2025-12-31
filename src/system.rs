use std::fs::{File, write};
use std::io::{ErrorKind, Read};
use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::{Result, anyhow};
use blkpg::resize_partition as kernel_reread_partition;
use gpt::GptConfig;
use gpt::disk::LogicalBlockSize;
use log::{debug, info};
use nvme_amz::Nvme;
use rustix::cstr;
use rustix::fs::{Dir, FileType, stat, symlink};

use crate::constants;
use crate::rdev::find_block_device;

const SYS_BLOCK_PATH: &str = "/sys/block";

pub fn find_executable_in_path(executable: &str, path_var: &str) -> Option<PathBuf> {
    for dir in path_var.split(":") {
        let try_path = PathBuf::from_iter([constants::DIR_ROOT, dir, executable]);
        if let Ok(st) = stat(&try_path)
            && st.st_mode & 0o111 != 0
        {
            return Some(try_path);
        }
    }
    None
}

// Write a sysctl value to the relevant file under /proc/sys.
pub fn sysctl<P: AsRef<Path>>(base_dir: P, key: &str, value: &str) -> Result<()> {
    let proc_path = proc_path_from_dotted(key);
    let full_path = base_dir.as_ref().join(proc_path);
    write(&full_path, value)
        .map_err(|e| anyhow!("unable to write {} to {:?}: {}", value, full_path, e))?;
    Ok(())
}

// Convert e.g. "net.ipv4.tcp_syncookies" to "/proc/sys/net/ipv4/tcp_syncookies".
fn proc_path_from_dotted(key: &str) -> PathBuf {
    let mut fields = vec![constants::DIR_PROC, "sys"];
    fields.extend(key.split("."));
    PathBuf::from_iter(fields)
}

pub fn device_has_fs(path: &Path) -> Result<bool> {
    let blkid_path = Path::new(constants::DIR_ET_SBIN).join("blkid");
    let blkid_result = Command::new(&blkid_path)
        .args([path])
        .output()
        .map_err(|e| anyhow!("unable to run {:?}: {}", &blkid_path, e))?;
    match blkid_result.status.code() {
        Some(0) => Ok(true),
        Some(2) => Ok(false),
        Some(code) => Err(anyhow!(
            "blkid failed with exit code {}: {}",
            code,
            String::from_utf8_lossy(&blkid_result.stderr)
        )),
        None => Err(anyhow!("blkid terminated by signal")),
    }
}

pub fn link_nvme_devices() -> Result<()> {
    let dir_fd = File::open(SYS_BLOCK_PATH)
        .map_err(|e| anyhow!("unable to open {}: {}", SYS_BLOCK_PATH, e))?;
    let dir = Dir::read_from(dir_fd)
        .map_err(|e| anyhow!("unable to read from directory {}: {}", SYS_BLOCK_PATH, e))?;
    for entry_res in dir {
        let entry = entry_res.map_err(|e| {
            anyhow!(
                "unable to read directory entry in {}: {}",
                SYS_BLOCK_PATH,
                e
            )
        })?;
        let device_name = entry.file_name().to_string_lossy().to_string();
        let disk_device = DeviceInfo {
            name: device_name.clone(),
            part_num: None,
        };
        link_nvme_device(&disk_device)?;
        let partition_devices = disk_partitions(&device_name)
            .map_err(|e| anyhow!("unable to get partitions of {:?}: {}", &device_name, e))?;
        for partition_device in partition_devices {
            link_nvme_device(&partition_device)?;
        }
    }
    Ok(())
}

pub fn link_nvme_device(device: &DeviceInfo) -> Result<()> {
    let device_path = Path::new("/dev").join(&device.name);
    let device_fd = File::open(&device_path)
        .map_err(|e| anyhow!("unable to open {:?}: {}", &device_path, e))?;
    if let Ok(nvme) = Nvme::try_from(device_fd) {
        debug!("nvme device: {:?}", nvme);
        let ec2_device_name = nvme.name();
        let link_device_name = &device
            .part_num
            .as_ref()
            .map(|n| {
                if has_digit_suffix(ec2_device_name) {
                    format!("{}p{}", ec2_device_name, n)
                } else {
                    format!("{}{}", ec2_device_name, n)
                }
            })
            .unwrap_or(ec2_device_name.into());
        let link_path = Path::new("/dev").join(link_device_name);
        debug!("linking {} to {:?}", &device.name, &link_path);
        if let Err(e) = symlink(&device.name, &link_path)
            && e.kind() != ErrorKind::AlreadyExists
        {
            return Err(anyhow!(
                "unable to link {} to {:?}: {}",
                &device.name,
                &link_path,
                e
            ));
        }
    }
    Ok(())
}

pub fn resize_root_volume() -> Result<()> {
    let (root_partition_device_name, root_disk_device_name) = find_root_devices()?;
    let root_disk_device_path = Path::new("/dev").join(&root_disk_device_name);
    debug!("root disk device path: {}", root_disk_device_path.display());

    let root_disk_device = File::options()
        .read(true)
        .write(true)
        .open(&root_disk_device_path)
        .map_err(|e| {
            anyhow!(
                "unable to open {:?} for resize: {}",
                &root_disk_device_path,
                e
            )
        })?;

    let logical_block_size = logical_block_size(&root_disk_device_name)
        .map_err(|e| anyhow!("unable to get sector size of root disk: {}", e))?;
    let logical_block_size_cfg = match logical_block_size {
        512 => LogicalBlockSize::Lb512,
        4096 => LogicalBlockSize::Lb4096,
        _ => return Err(anyhow!("unsupported sector size {}", logical_block_size)),
    };

    let mut root_disk = GptConfig::new()
        .logical_block_size(logical_block_size_cfg)
        .writable(true)
        .open_from_device(&root_disk_device)?;

    let disk_sectors = disk_sectors(&root_disk_device_name)
        .map_err(|e| anyhow!("unable to get sectors of root disk: {}", e))?;

    let align = root_disk.calculate_alignment() as i64;

    let gpt = root_disk.header();

    let first_usable_sector = gpt.first_usable as i64;
    debug!("first usable sector: {}", &first_usable_sector);

    let last_usable_sector = last_usable_sector(disk_sectors, first_usable_sector, align);
    debug!("last usable sector: {}", &last_usable_sector);

    let mut partitions = root_disk.take_partitions();
    debug!("partitions: {:?}", partitions);

    let root_part_num = partitions
        .iter()
        .filter(|(_, p)| p.name == "root")
        .map(|(n, _)| n)
        .next()
        .cloned()
        .ok_or_else(|| anyhow!("root partition not found"))?;

    let mut first_lba = 0;
    let mut resized = false;
    for (i, part) in partitions.iter_mut() {
        if *i != root_part_num {
            continue;
        }
        let fudge = 1024 * 1024; // A la growpart; don't resize if within this threshold.
        if part.last_lba < last_usable_sector - fudge {
            info!(
                "resizing partition from sector {} to sector {}",
                part.last_lba, last_usable_sector
            );
            part.last_lba = last_usable_sector;
            first_lba = part.first_lba;
            resized = true;
            break;
        }
    }

    if resized {
        debug!("partitions after resizing: {:?}", partitions);
        root_disk
            .update_partitions(partitions)
            .map_err(|e| anyhow!("unable to update partitions: {}", e))?;
        root_disk
            .write()
            .map_err(|e| anyhow!("unable to write disk: {}", e))?;
        kernel_reread_partition(
            &root_disk_device,
            root_part_num as i32,
            first_lba as i64,
            last_usable_sector as i64,
            logical_block_size,
        )
        .map_err(|e| anyhow!("unable to reread partition table: {}", e))?;
        debug!("growing root filesystem");
        grow_filesystem(&Path::new("/dev").join(root_partition_device_name))
            .map_err(|e| anyhow!("unable to grow root filesystem: {}", e))?;
    }
    Ok(())
}

fn last_usable_sector(disk_sectors: i64, first_usable_sector: i64, align: i64) -> u64 {
    // Assume the last sector of the GPT is the one before the first usable sector.
    // Subtract one for that and another for the protective MBR to get the length.
    let gpt_len = first_usable_sector - 2;
    ((disk_sectors - gpt_len - 1) / align * align) as u64
}

fn int_from_file<P: AsRef<Path>>(path: P) -> Result<i64> {
    let mut f =
        File::open(&path).map_err(|e| anyhow!("unable to open {:?}: {}", path.as_ref(), e))?;
    let mut buf = String::new();
    f.read_to_string(&mut buf)
        .map_err(|e| anyhow!("unable to read {:?}: {}", path.as_ref(), e))?;
    buf.trim()
        .parse()
        .map_err(|e| anyhow!("unable to parse the contents of {:?}: {}", path.as_ref(), e))
}

fn logical_block_size(device: &str) -> Result<i64> {
    let path = Path::new(SYS_BLOCK_PATH)
        .join(device)
        .join("queue/logical_block_size");
    int_from_file(path)
}

fn disk_sectors(device: &str) -> Result<i64> {
    let path = Path::new(SYS_BLOCK_PATH).join(device).join("size");
    int_from_file(path)
}

// Find the root partition device and its parent device.
fn find_root_devices() -> Result<(String, String)> {
    let root_partition_device = find_block_device(constants::DIR_ROOT)
        .map_err(|e| anyhow!("unable to get device of root partition: {}", e))?;
    debug!("root partition: {:?}", root_partition_device);
    let root_partition_name = root_partition_device.file_name().ok_or_else(|| {
        anyhow!(
            "invalid root partition path: {}",
            root_partition_device.display()
        )
    })?;

    let dir_fd = File::open(SYS_BLOCK_PATH)
        .map_err(|e| anyhow!("unable to open directory {}: {}", SYS_BLOCK_PATH, e))?;
    // Iterate over the devices in /sys/block to find the parent disk device.
    let dir = Dir::read_from(dir_fd)
        .map_err(|e| anyhow!("unable to read from directory {}: {}", SYS_BLOCK_PATH, e))?;
    for entry_res in dir {
        let entry = entry_res
            .map_err(|e| anyhow!("unable to get directory entry in {}: {}", SYS_BLOCK_PATH, e))?;
        if entry.file_name() == cstr!(".") || entry.file_name() == cstr!("..") {
            continue;
        }
        let device_name = entry.file_name().to_string_lossy();
        // If /sys/block/<device_name>/<root_partition_name> exists,
        // then we know that <device_name> is the parent disk device.
        let stat_path = Path::new(SYS_BLOCK_PATH)
            .join(device_name.as_ref())
            .join(root_partition_name);
        if File::open(stat_path).is_ok() {
            let root_partition_device_string = root_partition_name.to_string_lossy();
            return Ok((root_partition_device_string.to_string(), device_name.into()));
        }
    }
    Err(anyhow!("unable to find parent device of root partition"))
}

fn grow_filesystem(path: &PathBuf) -> Result<()> {
    let resize2fs_path = Path::new(constants::DIR_ET_SBIN).join("resize2fs");
    Command::new(resize2fs_path)
        .arg(path)
        .spawn()?
        .wait_with_output()?;
    Ok(())
}

#[derive(Debug, Eq, Ord, PartialEq, PartialOrd)]
pub struct DeviceInfo {
    pub name: String,
    pub part_num: Option<String>,
}

fn disk_partitions(device: &str) -> Result<Vec<DeviceInfo>> {
    let mut partitions = Vec::new();
    let sys_device_dir = Path::new(SYS_BLOCK_PATH).join(device);
    let dir_fd = File::open(&sys_device_dir)?;
    for entry_res in Dir::read_from(dir_fd)? {
        let entry = entry_res?;
        let name = entry.file_name().to_string_lossy().into_owned();

        if !(entry.file_type() == FileType::Directory && name.starts_with(device)) {
            continue;
        }

        let partition_path = sys_device_dir.join(&name).join("partition");
        match File::open(partition_path) {
            Err(e) if e.kind() == ErrorKind::NotFound => continue,
            Err(e) => return Err(e.into()),
            Ok(mut f) => {
                let mut contents = String::new();
                f.read_to_string(&mut contents)?;
                contents.truncate(contents.trim_end().len());
                partitions.push(DeviceInfo {
                    name,
                    part_num: Some(contents),
                });
            }
        };
    }
    Ok(partitions)
}

fn has_digit_suffix(string: &str) -> bool {
    string.chars().last().is_some_and(|c| c.is_ascii_digit())
}

#[cfg(test)]
mod tests {
    use pretty_assertions::assert_eq;

    use super::*;

    #[test]
    fn test_has_digit_suffix() {
        assert_eq!(has_digit_suffix(""), false);
        assert_eq!(has_digit_suffix("sda"), false);
        assert_eq!(has_digit_suffix("sda1"), true);
        assert_eq!(has_digit_suffix("sda10"), true);
    }
}
