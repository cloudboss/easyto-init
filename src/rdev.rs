use std::{
    fs::{metadata, symlink_metadata, File},
    path::{Path, PathBuf},
};

use anyhow::{anyhow, Result};
use rustix::fs::{Dir, FileTypeExt, MetadataExt};

// Rust version of find_root_device.c in busybox.

pub fn find_block_device<P: AsRef<Path>>(path: P) -> Result<PathBuf> {
    let stat = metadata(path)?;
    let is_block = stat.file_type().is_block_device();
    let device = if is_block { stat.rdev() } else { stat.dev() };
    find_block_device_in_dir("/dev", device)
}

pub fn find_block_device_in_dir<P: AsRef<Path>>(search_dir: P, device: u64) -> Result<PathBuf> {
    let fd = File::open(&search_dir)?;
    for dir_res in Dir::read_from(&fd)? {
        let dir = dir_res?;
        let file_name = dir.file_name().to_string_lossy();
        let stat_path = &search_dir.as_ref().join(file_name.as_ref());
        if let Ok(stat) = symlink_metadata(stat_path) {
            if stat.file_type().is_block_device() && stat.rdev() == device {
                return Ok(stat_path.into());
            }
            if stat.file_type().is_dir() {
                if file_name == "." || file_name == ".." {
                    continue;
                }
                if let Ok(bdev) = find_block_device_in_dir(stat_path, device) {
                    return Ok(bdev);
                }
            }
        }
    }
    Err(anyhow!("block device not found"))
}
