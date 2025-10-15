use std::thread;

use anyhow::{anyhow, Result};
use log::{debug, error};
use rustix::fd::AsFd;
use rustix::net::netlink::{SocketAddrNetlink, KOBJECT_UEVENT};
use rustix::net::{bind, recv, socket, AddressFamily, RecvFlags, SocketType};

use crate::system::{link_nvme_device, DeviceInfo};

const DELIM: &str = "=";
const DEVNAME: &str = "DEVNAME";
const PARTN: &str = "PARTN";
const SUBSYSTEM: &str = "SUBSYSTEM";
const SUBSYSTEM_BLOCK: &str = "block";

pub fn start_uevent_listener() -> Result<()> {
    let fd = socket(
        AddressFamily::NETLINK,
        SocketType::DGRAM,
        Some(KOBJECT_UEVENT),
    )?;
    let addr = SocketAddrNetlink::new(0, 1);
    bind(fd.as_fd(), &addr)?;
    thread::spawn(|| {
        debug!("starting uevent listener");
        recv_messages(fd);
    });
    Ok(())
}

fn recv_messages<Fd: AsFd>(fd: Fd) {
    let mut buf = [0u8; 4096];
    loop {
        match recv(fd.as_fd(), &mut buf, RecvFlags::empty()) {
            Ok((len, _)) => match handle_message(&buf, len) {
                Ok(Some(dev)) => {
                    if let Err(e) = link_nvme_device(&dev) {
                        error!("error linking device {:?}: {}", &dev, e);
                    }
                }
                Ok(None) => (),
                Err(e) => error!("error handling netlink message: {}", e),
            },
            Err(e) => error!("error receiving netlink message: {}", e),
        }
    }
}

fn handle_message(buf: &[u8], len: usize) -> Result<Option<DeviceInfo>> {
    let mut devname = String::new();
    let mut partn = String::new();

    // Only handle "add@" messages.
    if len < 4 {
        return Err(anyhow!("unexpected length of netlink message: {}", len));
    }
    if buf[..4] != [b'a', b'd', b'd', b'@'] {
        return Ok(None);
    }

    for var in buf[..len].split(|&b| b == 0) {
        if var.is_empty() {
            continue;
        }
        let message = String::from_utf8_lossy(var);
        debug!("uevent message: {}", message);
        let fields: Vec<&str> = message.split(DELIM).collect();
        if fields.len() != 2 {
            continue;
        }
        if fields[0] == SUBSYSTEM {
            if fields[1] != SUBSYSTEM_BLOCK {
                return Ok(None);
            }
            continue;
        }
        if fields[0] == DEVNAME {
            devname = fields[1].into();
            continue;
        }
        if fields[0] == PARTN {
            partn = fields[1].into();
        }
    }
    if devname.len() == 0 {
        return Ok(None);
    }
    Ok(Some(DeviceInfo {
        name: devname,
        part_num: if partn.len() > 0 { Some(partn) } else { None },
    }))
}
