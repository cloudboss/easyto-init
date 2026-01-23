use std::{
    ffi::CString,
    fs::{File, create_dir, rename},
    path::{MAIN_SEPARATOR_STR, Path, PathBuf},
};

use anyhow::{Context, Result, anyhow};
use log::debug;
use rustix::{
    fs::{Gid, Mode, Uid, chmod, chown},
    mount::{MountFlags, mount},
};

#[derive(Debug)]
pub struct Link<'a> {
    pub path: &'a str,
    pub target: &'a str,
}

#[derive(Debug)]
pub struct Mount<'a> {
    pub source: &'a str,
    pub flags: MountFlags,
    pub fs_type: &'a str,
    pub mode: Mode,
    pub options: Option<&'a str>,
    pub target: PathBuf,
}

impl<'a> Mount<'a> {
    pub fn execute(&self) -> Result<()> {
        let path = Path::new(&self.target);
        mkdir_p(path, self.mode)?;
        let options_cstring = self.options.map(|s| CString::new(s).unwrap());
        let options_cstr = options_cstring.as_deref();
        match mount(self.source, path, self.fs_type, self.flags, options_cstr) {
            Ok(()) => Ok(()),
            Err(rustix::io::Errno::BUSY) => {
                // Already mounted, this is OK. This can happen in integration tests
                // where init-wrapper mounts filesystems before handing off to init.
                debug!("Mount point {:?} already mounted, skipping", path);
                Ok(())
            }
            Err(e) => Err(anyhow!(
                "unable to mount {} on {:?}: {}",
                self.source,
                path,
                e
            )),
        }
    }
}

pub fn mkdir_p<P: AsRef<Path>>(path: P, mode: Mode) -> Result<()> {
    mkdir_p_own(path, mode, None, None)
}

pub fn mkdir_p_own<P: AsRef<Path>>(
    path: P,
    mode: Mode,
    owner: Option<Uid>,
    group: Option<Gid>,
) -> Result<()> {
    for dir in descending_dirs(path.as_ref().to_str().unwrap()) {
        debug!("Creating directory: {}", &dir);
        match create_dir(&dir) {
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => (),
            Err(e) => return Err(anyhow!("unable to create directory {}: {}", dir, e)),
            Ok(_) => {
                chmod(&dir, mode)
                    .map_err(|e| anyhow!("unable to change mode of {}: {}", dir, e))?;
                chown(&dir, owner, group)
                    .map_err(|e| anyhow!("unable to change ownership of {}: {}", dir, e))?;
            }
        }
    }
    Ok(())
}

// Given a path, return a list of it and its parents in descending order.
// For example, "/a/b/c", returns the Vector ["/a", "/a/b", "/a/b/c"].
fn descending_dirs(path: &str) -> Vec<String> {
    let dirs = path.split("/").collect::<Vec<&str>>();
    (1..=dirs.len())
        .map(|i| dirs[..i].join("/"))
        .filter(|s| !s.is_empty())
        .collect()
}

// The behavior of Path::join is surprising, as it does not actually join paths
// when the path argument is absolute, rather it returns the absolute one. This
// version joins the paths as expected.
pub trait JoinRelative {
    fn join_relative<P: AsRef<Path>>(&self, path: P) -> PathBuf;
}

impl JoinRelative for Path {
    fn join_relative<P: AsRef<Path>>(&self, path: P) -> PathBuf {
        let p = path.as_ref();
        if p.is_absolute() {
            let relative = p.strip_prefix(MAIN_SEPARATOR_STR).unwrap();
            Path::join(self, relative)
        } else {
            Path::join(self, p)
        }
    }
}

pub fn atomic_write<P: AsRef<Path>>(
    path: P,
    write: impl FnOnce(&File) -> Result<()>,
) -> Result<()> {
    let p = path.as_ref();
    let p_str = p.to_string_lossy();

    let dir_name = if p.is_absolute() {
        p.parent().unwrap_or(Path::new("/"))
    } else {
        p.parent()
            .map(|d| {
                if d.to_string_lossy().is_empty() {
                    Path::new(".")
                } else {
                    d
                }
            })
            .ok_or_else(|| anyhow!("invalid path {}", p_str))?
    };
    let file_name = p
        .file_name()
        .ok_or_else(|| anyhow!("invalid path {}", p_str))?;
    let file_name_tmp = dir_name.join(format!(".{}.tmp", file_name.to_string_lossy()));

    {
        let f = File::create(&file_name_tmp)?;
        write(&f).context(format!("unable to write {}", p_str))?;
        f.sync_all().context(format!("unable to sync {}", p_str))?;
    }

    rename(&file_name_tmp, p).context(format!(
        "unable to rename {} to {}",
        file_name_tmp.to_string_lossy(),
        p_str
    ))?;
    let dir_name_str = dir_name.to_string_lossy();
    let dir = File::open(dir_name).context(format!("unable to open directory {}", dir_name_str))?;
    dir.sync_all()
        .context(format!("unable to sync directory {}", dir_name_str))
}

#[cfg(test)]
mod tests {
    use pretty_assertions::assert_eq;

    use super::*;

    #[test]
    fn test_descending_dirs() {
        struct Case<'a> {
            path: &'a str,
            expected: Vec<String>,
        }
        let cases = [
            Case {
                path: "",
                expected: vec![],
            },
            Case {
                path: "a",
                expected: ["a"].iter().map(|s| s.to_string()).collect(),
            },
            Case {
                path: "/a",
                expected: ["/a"].iter().map(|s| s.to_string()).collect(),
            },
            Case {
                path: "/a/b",
                expected: ["/a", "/a/b"].iter().map(|s| s.to_string()).collect(),
            },
            Case {
                path: "/a/b/",
                expected: ["/a", "/a/b", "/a/b/"]
                    .iter()
                    .map(|s| s.to_string())
                    .collect(),
            },
            Case {
                path: "/a/b/c/d",
                expected: ["/a", "/a/b", "/a/b/c", "/a/b/c/d"]
                    .iter()
                    .map(|s| s.to_string())
                    .collect(),
            },
        ];
        for case in cases {
            let result = descending_dirs(case.path);
            assert_eq!(case.expected, result);
        }
    }

    #[test]
    fn test_path_ext_join_relative() {
        struct Case<'a> {
            base: &'a str,
            join: &'a str,
            expected: PathBuf,
        }
        let cases = [
            Case {
                base: "/a",
                join: "",
                expected: PathBuf::from("/a/"),
            },
            Case {
                base: "/a",
                join: "b",
                expected: PathBuf::from("/a/b"),
            },
            Case {
                base: "/a",
                join: "/b",
                expected: PathBuf::from("/a/b"),
            },
        ];
        for case in cases {
            let joined = Path::new(case.base).join_relative(case.join);
            assert_eq!(case.expected, joined);
        }
    }
}
