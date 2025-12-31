use std::{
    fs::File,
    io::{self, Read},
    path::Path,
};

use anyhow::{Result, anyhow};
use rustix::fs::{Gid, Mode, OpenOptionsExt, Uid, chown};

use crate::fs::{JoinRelative, mkdir_p_own};

pub trait Writable
where
    Self: Read,
{
    fn name(&self) -> &str;
    fn is_secret(&self) -> bool;

    fn write(&mut self, dest: &Path, user_id: u32, group_id: u32) -> Result<()> {
        let mode_dir = Mode::from(if self.is_secret() { 0o700 } else { 0o755 });
        let mode_file = Mode::from(if self.is_secret() { 0o600 } else { 0o644 });
        let name = self.name();
        let final_dest = if name.is_empty() {
            dest.to_path_buf()
        } else {
            dest.join_relative(name)
        };
        let dest_dir = final_dest.parent().ok_or(anyhow!("no parent directory"))?;

        let (uid, gid) = (Uid::from_raw(user_id), Gid::from_raw(group_id));
        mkdir_p_own(dest_dir, mode_dir, Some(uid), Some(gid))?;

        let mut f = File::options()
            .create(true)
            .write(true)
            .truncate(true)
            .mode(mode_file.as_raw_mode())
            .open(&final_dest)?;

        io::copy(self, &mut f)?;

        chown(final_dest, Some(uid), Some(gid))?;

        Ok(())
    }
}
