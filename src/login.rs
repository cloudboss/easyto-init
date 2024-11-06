use std::fmt;
use std::io::{BufRead, BufReader, Read};
use std::path::Path;

use rustix::fs::{chown, mkdir, Gid, Mode, Uid};
use rustix::io::Errno;
use rustix::process::umask;

type Result<T> = std::result::Result<T, Error>;

#[derive(Debug)]
pub enum Error {
    Errno(Errno),
    ParseError(String),
}

impl From<Errno> for Error {
    fn from(errno: Errno) -> Self {
        Error::Errno(errno)
    }
}

impl std::error::Error for Error {}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match self {
            Self::Errno(e) => write!(f, "Errno: {}", e),
            Self::ParseError(details) => write!(f, "Invalid format: {}", details),
        }
    }
}

type UserId = u32;
type GroupId = u32;

#[derive(Debug, Clone, PartialEq)]
pub struct PasswdEntry {
    pub user_name: String,
    pub password: String,
    pub uid: UserId,
    pub gid: GroupId,
    pub comment: String,
    pub home_dir: String,
    pub shell: String,
}

impl fmt::Display for PasswdEntry {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(
            f,
            "{}:{}:{}:{}:{}:{}:{}",
            self.user_name,
            self.password,
            self.uid,
            self.gid,
            self.comment,
            self.home_dir,
            self.shell
        )
    }
}

pub trait Find<T> {
    fn find(&self, name: &str) -> Option<T>;
}

impl Find<PasswdEntry> for Vec<PasswdEntry> {
    fn find(&self, name: &str) -> Option<PasswdEntry> {
        for entry in self.iter() {
            if entry.user_name == name {
                return Some(entry.clone());
            }
        }
        None
    }
}

fn parse_passwd_line(line: &str, line_number: usize) -> Result<PasswdEntry> {
    let fields: Vec<&str> = line.split(":").collect();
    if fields.len() != 7 {
        return Err(Error::ParseError(format!(
            "expected 7 fields on passwd line {}, got {}",
            line_number + 1,
            fields.len()
        )));
    }
    let uid = fields[2].parse::<UserId>().map_err(|e| {
        Error::ParseError(format!(
            "expected an integer in UID field on passwd line {}, got {}: {}",
            line_number + 1,
            fields[2],
            e
        ))
    })?;
    let gid = fields[3].parse::<GroupId>().map_err(|e| {
        Error::ParseError(format!(
            "expected an integer in GID field on passwd line {}, got {}: {}",
            line_number + 1,
            fields[3],
            e
        ))
    })?;
    Ok(PasswdEntry {
        user_name: fields[0].into(),
        password: fields[1].into(),
        uid,
        gid,
        comment: fields[4].into(),
        home_dir: fields[5].into(),
        shell: fields[6].into(),
    })
}

pub fn parse_passwd_lines<R: Read>(reader: R) -> Result<Vec<PasswdEntry>> {
    let mut entry_list = Vec::new();
    let buf_reader = BufReader::new(reader);

    let lines = buf_reader.lines();
    for (i, line) in lines.map_while(|l| l.ok()).enumerate() {
        let entry = parse_passwd_line(&line, i + 1)?;
        entry_list.push(entry);
    }
    Ok(entry_list)
}

pub fn create_home_dir(home_dir: &Path, uid: u32, gid: u32) -> Result<()> {
    let old_mask = umask(Mode::empty());
    let parent = home_dir.parent().ok_or_else(|| {
        Error::ParseError(format!(
            "unable to determine parent directory of {}",
            home_dir.display()
        ))
    })?;
    let ssh_dir = &home_dir.join(".ssh");
    mkdir(parent, Mode::from_bits(0o755).unwrap())?;
    mkdir(home_dir, Mode::from_bits(0o700).unwrap())?;
    mkdir(ssh_dir, Mode::from_bits(0o700).unwrap())?;
    let (uid, gid) = unsafe { (Uid::from_raw(uid), Gid::from_raw(gid)) };
    chown(home_dir, Some(uid), Some(gid))?;
    chown(ssh_dir, Some(uid), Some(gid))?;
    umask(old_mask);
    Ok(())
}

pub fn user_group_id<T: Read>(rdr: BufReader<T>, name: &str) -> Result<u32> {
    fn is_numeric(s: &str) -> bool {
        s.chars().all(|c| c.is_ascii_digit())
    }
    if is_numeric(name) {
        return name.parse::<u32>().map_err(|e| {
            Error::ParseError(format!(
                "unable to parse ID of user or group {} into an integer: {}",
                name, e
            ))
        });
    }
    let mut id = 0;
    let mut found = false;
    for line in rdr.lines().map_while(|l| l.ok()) {
        let fields: Vec<&str> = line.split(":").collect();
        if fields[0] == name {
            id = fields[2].parse::<u32>().map_err(|e| {
                Error::ParseError(format!(
                    "unable to parse ID of user or group {} into an integer, got {}: {}",
                    name, fields[2], e
                ))
            })?;
            found = true;
            break;
        }
    }
    if !found {
        return Err(Error::ParseError(format!("id for {} not found", name)));
    }
    Ok(id)
}

#[cfg(test)]
mod test {
    use pretty_assertions::assert_eq;

    use super::*;

    #[test]
    fn test_parse_passwd_lines_empty() {
        let contents = "";
        let reader = contents.as_bytes();
        match parse_passwd_lines(reader) {
            Ok(entries) => {
                assert_eq!(entries, Vec::new());
            }
            Err(e) => panic!("unexpected error: {}", e),
        }
    }

    #[test]
    fn test_parse_passwd_lines_single_user() {
        let contents = vec!["cloudboss:x:1234:1234:cloudboss:/home/cloudboss:/bin/bash"].join("\n");
        let reader = contents.as_bytes();
        match parse_passwd_lines(reader) {
            Ok(entries) => {
                assert_eq!(
                    entries,
                    vec![PasswdEntry {
                        user_name: "cloudboss".into(),
                        password: "x".into(),
                        uid: 1234,
                        gid: 1234,
                        comment: "cloudboss".into(),
                        home_dir: "/home/cloudboss".into(),
                        shell: "/bin/bash".into(),
                    }]
                );
            }
            Err(e) => panic!("unexpected error: {}", e),
        }
    }

    #[test]
    fn test_parse_passwd_lines_multiple_users() {
        let contents = vec![
            "root:x:0:0:root:/root:/bin/sh",
            "cloudboss:x:1234:1234:cloudboss:/home/cloudboss:/bin/bash",
        ]
        .join("\n");
        let reader = contents.as_bytes();
        match parse_passwd_lines(reader) {
            Ok(entries) => {
                assert_eq!(
                    entries,
                    vec![
                        PasswdEntry {
                            user_name: "root".into(),
                            password: "x".into(),
                            uid: 0,
                            gid: 0,
                            comment: "root".into(),
                            home_dir: "/root".into(),
                            shell: "/bin/sh".into(),
                        },
                        PasswdEntry {
                            user_name: "cloudboss".into(),
                            password: "x".into(),
                            uid: 1234,
                            gid: 1234,
                            comment: "cloudboss".into(),
                            home_dir: "/home/cloudboss".into(),
                            shell: "/bin/bash".into(),
                        },
                    ]
                );
            }
            Err(e) => panic!("unexpected error: {}", e),
        }
    }

    #[test]
    fn test_parse_passwd_lines_bad_uid() {
        let contents = vec![
            "root:x:bad_uid:0:root:/root:/bin/sh",
            "cloudboss:x:1234:1234:cloudboss:/home/cloudboss:/bin/bash",
        ]
        .join("\n");
        let reader = contents.as_bytes();
        assert_eq!(true, parse_passwd_lines(reader).is_err());
    }

    #[test]
    fn test_parse_passwd_lines_bad_gid() {
        let contents = vec![
            "root:x:0:0:root:/root:/bin/sh",
            "cloudboss:x:1234:bad_gid:cloudboss:/home/cloudboss:/bin/bash",
        ]
        .join("\n");
        let reader = contents.as_bytes();
        assert_eq!(true, parse_passwd_lines(reader).is_err());
    }
}
