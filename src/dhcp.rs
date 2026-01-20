use std::io::{self, Write};
use std::net::{IpAddr, Ipv4Addr, SocketAddrV4};
use std::slice;
use std::time::{Duration, Instant};

use anyhow::{Context, Result, anyhow};
use dhcproto::v4::{self, DhcpOption, Message, MessageType, OptionCode};
use dhcproto::{Decodable, Decoder, Encodable};
use log::{info, warn};
use rand::TryRngCore;
use rand::rngs::OsRng;
use socket2::{Domain, Protocol, SockAddr, Socket, Type};

use crate::backoff::RetryBackoff;
use crate::constants::FILE_ETC_RESOLV_CONF;
use crate::fs::atomic_write;
use crate::network::NetlinkConnection;

fn subnet_mask_to_prefix(mask: Ipv4Addr) -> u8 {
    let m = u32::from_be_bytes(mask.octets());
    m.count_ones() as u8
}

async fn configure_address_and_route(
    nl: &NetlinkConnection,
    ifindex: u32,
    addr: Ipv4Addr,
    prefix: u8,
    gateway: Ipv4Addr,
) -> Result<()> {
    nl.address_add(ifindex, IpAddr::V4(addr), prefix)
        .await
        .context("failed to add IP address")?;
    nl.route_add(
        ifindex,
        IpAddr::V4(Ipv4Addr::new(0, 0, 0, 0)),
        IpAddr::V4(gateway),
        0,
    )
    .await
    .context("failed to add default route")?;
    Ok(())
}

fn write_resolv_conf(
    domain_name: &Option<String>,
    search_list: &[String],
    servers: &[Ipv4Addr],
) -> Result<()> {
    atomic_write(FILE_ETC_RESOLV_CONF, |mut f| {
        if let Some(dn) = domain_name {
            writeln!(f, "domain {}", dn)?;
        }
        if !search_list.is_empty() {
            writeln!(f, "search {}", search_list.join(" "))?;
        }
        for s in servers {
            writeln!(f, "nameserver {}", s)?;
        }
        Ok(())
    })
}

pub(crate) async fn run_dhcp_on_interface(
    nl: &NetlinkConnection,
    interface: &str,
    ifindex: u32,
    mac: [u8; 6],
) -> Result<()> {
    let timeout = Duration::from_secs(30);
    let cap = Duration::from_secs(5);
    let start = Instant::now();
    let mut backoff = RetryBackoff::new(cap);
    let mut buf: [std::mem::MaybeUninit<u8>; 1500] = [std::mem::MaybeUninit::uninit(); 1500];
    let mut last_error: Option<_>;

    loop {
        let sock = match create_dhcp_socket(interface) {
            Ok(s) => s,
            Err(e) => {
                warn!(
                    "DHCP attempt on {}: failed to create socket: {}",
                    interface, e
                );
                last_error = Some(e);
                if start.elapsed() >= timeout {
                    break;
                }
                backoff.wait();
                continue;
            }
        };

        match attempt_dhcp_exchange(&sock, &mut buf, interface, ifindex, mac, nl).await {
            Ok(()) => return Ok(()),
            Err(e) => {
                warn!("DHCP attempt failed on {}: {}", interface, e);
                last_error = Some(e);
                if start.elapsed() >= timeout {
                    break;
                }
                backoff.wait();
            }
        }
    }

    Err(last_error.unwrap_or_else(|| anyhow!("DHCP timed out after {:?}", timeout)))
}

fn create_dhcp_socket(interface: &str) -> Result<Socket> {
    let sock = Socket::new(Domain::IPV4, Type::DGRAM, Some(Protocol::UDP))?;
    sock.set_reuse_address(true)?;
    sock.set_reuse_port(true)?;
    sock.bind_device(Some(interface.as_bytes()))?;
    sock.set_broadcast(true)?;
    sock.bind(&SockAddr::from(SocketAddrV4::new(
        Ipv4Addr::UNSPECIFIED,
        v4::CLIENT_PORT,
    )))?;
    sock.set_read_timeout(Some(Duration::from_secs(3)))?;
    Ok(sock)
}

async fn attempt_dhcp_exchange(
    sock: &Socket,
    buf: &mut [std::mem::MaybeUninit<u8>; 1500],
    interface: &str,
    ifindex: u32,
    mac: [u8; 6],
    nl: &NetlinkConnection,
) -> Result<()> {
    // Generate transaction ID.
    let xid = OsRng
        .try_next_u32()
        .context("failed to generate DHCP transaction ID")?;

    // Send DHCPDISCOVER and wait for DHCPOFFER.
    let offer_msg = send_dhcpdiscover(sock, buf, interface, xid, mac).await?;

    // Extract info from offer.
    let offered_ip = offer_msg.yiaddr();
    let server_id = offer_msg
        .opts()
        .get(OptionCode::ServerIdentifier)
        .and_then(|dhcp_option| {
            if let DhcpOption::ServerIdentifier(ip) = dhcp_option {
                return Some(ip);
            }
            None
        })
        .ok_or_else(|| anyhow!("no server ID returned from DHCP server"))?;

    // Send DHCPREQUEST and wait for DHCPACK.
    let ack_msg = send_dhcprequest(sock, buf, interface, xid, mac, offered_ip, *server_id).await?;

    // Parse and apply configuration.
    apply_dhcp_config(nl, ifindex, &ack_msg).await
}

async fn send_dhcpdiscover(
    sock: &Socket,
    buf: &mut [std::mem::MaybeUninit<u8>; 1500],
    interface: &str,
    xid: u32,
    mac: [u8; 6],
) -> Result<Message> {
    let mut discover = Message::new_with_id(
        xid,
        Ipv4Addr::UNSPECIFIED,
        Ipv4Addr::UNSPECIFIED,
        Ipv4Addr::UNSPECIFIED,
        Ipv4Addr::UNSPECIFIED,
        &mac,
    );
    discover
        .set_htype(v4::HType::Eth)
        .set_flags(v4::Flags::default().set_broadcast())
        .opts_mut()
        .insert(DhcpOption::MessageType(MessageType::Discover));
    discover
        .opts_mut()
        .insert(DhcpOption::ParameterRequestList(vec![
            OptionCode::SubnetMask,
            OptionCode::Router,
            OptionCode::DomainNameServer,
            OptionCode::DomainName,
            OptionCode::DomainSearch,
        ]));
    discover.opts_mut().insert(DhcpOption::MaxMessageSize(1500));

    let discover_bytes = discover
        .to_vec()
        .context("failed to encode DHCPDISCOVER message to bytes")?;

    let server_addr = SockAddr::from(SocketAddrV4::new(Ipv4Addr::BROADCAST, v4::SERVER_PORT));
    let sent = sock.send_to(&discover_bytes, &server_addr)?;
    info!("Sent DHCPDISCOVER ({} bytes) on {}", sent, interface);

    wait_for_dhcp_message(sock, buf, xid, MessageType::Offer)
}

async fn send_dhcprequest(
    sock: &Socket,
    buf: &mut [std::mem::MaybeUninit<u8>; 1500],
    interface: &str,
    xid: u32,
    mac: [u8; 6],
    offered_ip: Ipv4Addr,
    server_id: Ipv4Addr,
) -> Result<Message> {
    let mut request = Message::new_with_id(
        xid,
        Ipv4Addr::UNSPECIFIED,
        Ipv4Addr::UNSPECIFIED,
        Ipv4Addr::UNSPECIFIED,
        Ipv4Addr::UNSPECIFIED,
        &mac,
    );
    request
        .set_htype(v4::HType::Eth)
        .set_flags(v4::Flags::default().set_broadcast())
        .opts_mut()
        .insert(DhcpOption::MessageType(MessageType::Request));
    request
        .opts_mut()
        .insert(DhcpOption::RequestedIpAddress(offered_ip));
    request
        .opts_mut()
        .insert(DhcpOption::ServerIdentifier(server_id));
    request.opts_mut().insert(DhcpOption::MaxMessageSize(1500));

    let request_bytes = request
        .to_vec()
        .context("failed to encode DHCPREQUEST message to bytes")?;

    let server_addr = SockAddr::from(SocketAddrV4::new(Ipv4Addr::BROADCAST, v4::SERVER_PORT));
    let sent = sock.send_to(&request_bytes, &server_addr)?;
    info!("Sent DHCPREQUEST ({} bytes) on {}", sent, interface);

    wait_for_dhcp_message(sock, buf, xid, MessageType::Ack)
}

fn wait_for_dhcp_message(
    sock: &Socket,
    buf: &mut [std::mem::MaybeUninit<u8>; 1500],
    xid: u32,
    msg_type: MessageType,
) -> Result<Message> {
    let start = Instant::now();
    let timeout = Duration::from_secs(10);
    let cap = Duration::from_secs(1);
    let mut backoff = RetryBackoff::new(cap);

    loop {
        match sock.recv_from(buf) {
            Ok((n, _from)) => {
                // SAFETY: Socket::recv_from writes to the buffer and returns the number of bytes written.
                // The first `n` bytes are guaranteed to be initialized by the recv_from operation.
                let bytes = unsafe { slice::from_raw_parts(buf.as_ptr() as *const u8, n) };
                match Message::decode(&mut Decoder::new(bytes)) {
                    Ok(msg) => {
                        if msg.xid() == xid && msg.opts().has_msg_type(msg_type) {
                            return Ok(msg);
                        }
                    }
                    Err(e) => {
                        warn!("failed to decode DHCP message {:?}: {}", msg_type, e);
                    }
                }
            }
            Err(e) if is_error_retryable(&e) => {
                if start.elapsed() >= timeout {
                    return Err(anyhow!("timeout waiting for DHCP message {:?}", msg_type));
                }
                backoff.wait();
            }
            Err(e) => return Err(e.into()),
        }
    }
}

fn is_error_retryable(error: &io::Error) -> bool {
    let kind = error.kind();
    kind == io::ErrorKind::WouldBlock || kind == io::ErrorKind::TimedOut
}

async fn apply_dhcp_config(nl: &NetlinkConnection, ifindex: u32, ack_msg: &Message) -> Result<()> {
    let addr = ack_msg.yiaddr();

    let subnet = ack_msg
        .opts()
        .get(OptionCode::SubnetMask)
        .and_then(|dhcp_option| {
            if let DhcpOption::SubnetMask(mask) = dhcp_option {
                return Some(*mask);
            }
            None
        })
        .ok_or_else(|| anyhow!("no subnet returned from DHCP server"))?;
    let gateway = ack_msg
        .opts()
        .get(OptionCode::Router)
        .and_then(|dhcp_option| {
            if let DhcpOption::Router(routers) = dhcp_option
                && let Some(gw) = routers.first()
            {
                return Some(*gw);
            }
            None
        })
        .ok_or_else(|| anyhow!("no gateway returned from DHCP server"))?;
    let dns_servers: Vec<Ipv4Addr> = match ack_msg.opts().get(OptionCode::DomainNameServer) {
        Some(DhcpOption::DomainNameServer(v)) => v.clone(),
        _ => Vec::new(),
    };
    let domain_name: Option<String> = match ack_msg.opts().get(OptionCode::DomainName) {
        Some(DhcpOption::DomainName(name)) => Some(name.clone()),
        _ => None,
    };
    let search_list: Vec<String> = match ack_msg.opts().get(OptionCode::DomainSearch) {
        Some(DhcpOption::DomainSearch(list)) => list.iter().map(|n| n.to_string()).collect(),
        _ => Vec::new(),
    };

    let prefix = subnet_mask_to_prefix(subnet);

    configure_address_and_route(nl, ifindex, addr, prefix, gateway).await?;

    if !dns_servers.is_empty() {
        write_resolv_conf(&domain_name, &search_list, &dns_servers)?;
    }

    Ok(())
}
