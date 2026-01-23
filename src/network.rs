use anyhow::{Context, Result, anyhow};
use chrono::Utc;
use futures::{Stream, StreamExt};
use log::{info, warn};
use netlink_packet_route::address::{AddressAttribute as AddrAttr, AddressMessage};
use netlink_packet_route::link::{InfoKind, LinkInfo};
use netlink_packet_route::link::{LinkAttribute, LinkMessage};
use netlink_packet_route::route::RouteAddress;
use rtnetlink::{
    Error as NlError, Handle as NlHandle, LinkUnspec, RouteMessageBuilder, new_connection,
};
use rustix::fs::Mode;
use rustix::system::sethostname;
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::collections::HashMap;
use std::fs;
use std::io::Write;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use std::path::Path;
use std::time::SystemTime;
use std::time::{Duration, Instant};
use tokio::runtime::Handle as RtHandle;

use crate::aws::imds::ImdsClientAsync;
use crate::backoff::RetryBackoff;
use crate::constants::DIR_ET_ETC;
use crate::dhcp::{
    AddressConfig, DhcpLease, ResolverConfig, configure_address_and_route, run_dhcp_on_interface,
    write_resolver_config,
};
use crate::fs::{atomic_write, mkdir_p};

#[derive(Debug, Clone)]
pub(crate) struct InterfaceInfo {
    name: String,
    mac: Option<[u8; 6]>,
    is_virtual: bool,
    ifindex: u32,
}

trait InterfaceInfoSliceExt {
    fn find_by_mac(&self, target_mac: &str) -> Option<InterfaceInfo>;
}

impl InterfaceInfoSliceExt for [InterfaceInfo] {
    fn find_by_mac(&self, target_mac: &str) -> Option<InterfaceInfo> {
        for interface in self {
            if let Some(mac) = interface.mac
                && mac_to_string(mac) == target_mac
            {
                return Some(interface.clone());
            }
        }
        None
    }
}

pub(crate) struct NetlinkConnection {
    handle: NlHandle,
}

impl NetlinkConnection {
    pub(crate) fn new() -> Result<Self> {
        let rt = RtHandle::try_current().map_err(|_| anyhow!("tokio is not running"))?;
        let (connection, handle, _) =
            new_connection().map_err(|e| anyhow!("unable to create netlink socket: {}", e))?;
        rt.spawn(connection);
        Ok(Self { handle })
    }

    pub(crate) async fn get_interfaces(&self) -> Result<Vec<InterfaceInfo>> {
        let mut interfaces = Vec::new();
        let mut links = self.handle.link().get().execute();
        while let Some(link_res) = links.next().await {
            let link = link_res?;
            let interface = extract_interface(link)?;
            interfaces.push(interface);
        }
        Ok(interfaces)
    }

    pub(crate) async fn link_set(&self, message: LinkMessage) -> Result<()> {
        let err = format!("failed to set link attributes: {:?}", &message);
        self.handle.link().set(message).execute().await.context(err)
    }

    pub(crate) async fn link_up(&self, ifindex: u32) -> Result<()> {
        self.link_set(LinkUnspec::new_with_index(ifindex).up().build())
            .await
            .context("failed to set link up")
    }

    pub(crate) fn address_stream(
        &self,
        ifindex: Option<u32>,
    ) -> impl Stream<Item = Result<AddressMessage, NlError>> {
        let mut req = self.handle.address().get();
        if let Some(i) = ifindex {
            req = req.set_link_index_filter(i);
        }
        req.execute()
    }

    pub(crate) fn link_stream(&self) -> impl Stream<Item = Result<LinkMessage, NlError>> {
        self.handle.link().get().execute()
    }

    pub(crate) async fn address_add(
        &self,
        ifindex: u32,
        address: IpAddr,
        prefix_len: u8,
    ) -> Result<()> {
        self.handle
            .address()
            .add(ifindex, address, prefix_len)
            .execute()
            .await
            .context("unable to add address")
    }

    pub(crate) async fn address_del(&self, address: AddressMessage) -> Result<()> {
        self.handle
            .address()
            .del(address)
            .execute()
            .await
            .context("unable to add address")
    }

    pub(crate) async fn route_add(
        &self,
        ifindex: u32,
        address: IpAddr,
        gateway: IpAddr,
        prefix_len: u8,
    ) -> Result<()> {
        let msg = match (address, gateway) {
            (IpAddr::V4(a), IpAddr::V4(g)) => Some(
                RouteMessageBuilder::<Ipv4Addr>::default()
                    .destination_prefix(a, prefix_len)
                    .output_interface(ifindex)
                    .gateway(g)
                    .build(),
            ),
            (IpAddr::V6(a), IpAddr::V6(g)) => Some(
                RouteMessageBuilder::<Ipv6Addr>::default()
                    .destination_prefix(a, prefix_len)
                    .output_interface(ifindex)
                    .gateway(g)
                    .build(),
            ),
            _ => None,
        }
        .ok_or_else(|| anyhow!("invalid address or gateway"))?;
        self.handle
            .route()
            .add(msg)
            .execute()
            .await
            .context("failed to add route")
    }

    pub(crate) async fn route_del(
        &self,
        ifindex: u32,
        address: IpAddr,
        prefix_len: u8,
    ) -> Result<()> {
        let msg = match address {
            IpAddr::V4(a) => Some(
                RouteMessageBuilder::<Ipv4Addr>::default()
                    .destination_prefix(a, prefix_len)
                    .output_interface(ifindex)
                    .build(),
            ),
            IpAddr::V6(a) => Some(
                RouteMessageBuilder::<Ipv6Addr>::default()
                    .destination_prefix(a, prefix_len)
                    .output_interface(ifindex)
                    .build(),
            ),
        }
        .ok_or_else(|| anyhow!("invalid address or gateway"))?;
        self.handle
            .route()
            .del(msg)
            .execute()
            .await
            .context("failed to add route")
    }

    pub(crate) async fn link_rename(&self, ifindex: u32, new_name: &str) -> Result<()> {
        self.link_set(
            rtnetlink::LinkUnspec::new_with_index(ifindex)
                .name(new_name.into())
                .build(),
        )
        .await
    }

    pub(crate) async fn get_interface_address_config(&self, ifindex: u32) -> Result<AddressConfig> {
        use netlink_packet_route::address::AddressAttribute;
        use netlink_packet_route::route::{RouteAttribute, RouteMessage};

        // Get the first IPv4 address on this interface.
        let mut addrs = self.address_stream(Some(ifindex));
        let mut address: Option<Ipv4Addr> = None;
        let mut prefix_len: Option<u8> = None;
        while let Some(addr_res) = addrs.next().await {
            let addr_msg = addr_res?;
            if addr_msg.header.family == netlink_packet_route::AddressFamily::Inet {
                prefix_len = Some(addr_msg.header.prefix_len);
                for attr in &addr_msg.attributes {
                    if let AddressAttribute::Address(IpAddr::V4(v4)) = attr {
                        address = Some(*v4);
                        break;
                    }
                }
                if address.is_some() {
                    break;
                }
            }
        }

        let address = address.ok_or_else(|| anyhow!("no IPv4 address found on interface"))?;
        let prefix_len = prefix_len.ok_or_else(|| anyhow!("no prefix length found"))?;

        // Get the default gateway from the routing table.
        // Create a RouteMessage to query IPv4 routes.
        let route_msg = RouteMessageBuilder::<Ipv4Addr>::default().build();
        let mut routes = self.handle.route().get(route_msg).execute();
        let mut gateway: Option<Ipv4Addr> = None;
        while let Some(route_res) = routes.next().await {
            let route: RouteMessage = route_res?;
            // Look for default route (0.0.0.0/0) on this interface.
            if route.header.destination_prefix_length == 0 {
                let mut route_ifindex: Option<u32> = None;
                let mut route_gateway: Option<Ipv4Addr> = None;
                for attr in &route.attributes {
                    match attr {
                        RouteAttribute::Oif(idx) => route_ifindex = Some(*idx),
                        RouteAttribute::Gateway(RouteAddress::Inet(v4)) => {
                            route_gateway = Some(*v4);
                        }
                        _ => {}
                    }
                }
                if route_ifindex == Some(ifindex) {
                    gateway = route_gateway;
                    break;
                }
            }
        }

        let gateway = gateway.ok_or_else(|| anyhow!("no default gateway found for interface"))?;

        Ok(AddressConfig {
            address,
            prefix_len,
            gateway,
        })
    }
}

pub(crate) fn initialize_network(rt: RtHandle, imds_client: &ImdsClientAsync) -> Result<()> {
    rt.block_on(initialize_network_async(imds_client))
}

async fn initialize_network_async(imds_client: &ImdsClientAsync) -> Result<()> {
    let timeout = Duration::from_secs(60);
    let cap = Duration::from_secs(2);
    let start = Instant::now();
    let mut backoff = RetryBackoff::new(cap);
    let mut last_error: Option<_>;

    loop {
        match initialize_network_inner(imds_client).await {
            Ok(()) => return Ok(()),
            Err(e) => {
                warn!("Network initialization attempt failed: {}", e);
                last_error = Some(e);
                if start.elapsed() >= timeout {
                    break;
                }
                backoff.wait();
            }
        }
    }

    Err(last_error
        .unwrap_or_else(|| anyhow!("network initialization timed out after {:?}", timeout)))
}

async fn initialize_network_inner(imds_client: &ImdsClientAsync) -> Result<()> {
    let nl = NetlinkConnection::new().context("failed to create netlink connection")?;

    let persisted_state = load_persisted_state().unwrap_or_default();
    let interfaces = restore_interfaces(&nl, &persisted_state).await?;

    ensure_loopback(&nl, &interfaces).await?;

    let (primary, bootstrap_ifindex) =
        select_primary_interface(&nl, imds_client, &interfaces, &persisted_state).await?;
    let final_primary = apply_primary_naming(&nl, &interfaces, &primary, &persisted_state).await?;

    let dhcp_lease =
        configure_primary_dhcp(&nl, &final_primary, bootstrap_ifindex, &persisted_state).await?;

    // Persist interfaces with DHCP lease after successful configuration.
    let final_interfaces = nl.get_interfaces().await?;
    persist_interfaces(&final_interfaces, &final_primary.name, Some(&dhcp_lease))?;

    set_hostname(imds_client).await?;

    Ok(())
}

async fn set_hostname(imds_client: &ImdsClientAsync) -> Result<()> {
    let hostname = imds_client
        .get_metadata("local-hostname")
        .await
        .context("failed to get hostname from IMDS")?;

    let hostname_str: String = hostname.into();
    info!("Setting hostname to {}", &hostname_str);

    sethostname(hostname_str.as_bytes()).map_err(|e| anyhow!("failed to set hostname: {}", e))?;

    Ok(())
}

async fn select_primary_interface(
    nl: &NetlinkConnection,
    imds_client: &ImdsClientAsync,
    interfaces: &[InterfaceInfo],
    persisted_state: &PersistedNetworkState,
) -> Result<(InterfaceInfo, Option<u32>)> {
    // Check for persisted primary first.
    if let Some(persisted_primary_mac) = persisted_state.get_primary_mac()
        && let Some(primary) = interfaces
            .iter()
            .find(|iface| iface.mac.map(mac_to_string).as_deref() == Some(&persisted_primary_mac))
    {
        info!("Using persisted primary interface {}", primary.name);
        return Ok((primary.clone(), None));
    }

    // No persisted primary, bootstrap the first one found and then verify against IMDS.
    let bootstrap_ifindex = establish_bootstrap_connectivity(nl, interfaces).await?;
    let primary_mac = discover_primary_mac_via_imds(imds_client, Duration::from_secs(10)).await?;
    let primary = interfaces
        .find_by_mac(&primary_mac)
        .ok_or_else(|| anyhow!("failed to find interface info for MAC {}", primary_mac))?;
    info!("Using discovered primary interface {}", primary.name);

    Ok((primary, Some(bootstrap_ifindex)))
}

async fn apply_primary_naming(
    nl: &NetlinkConnection,
    interfaces: &[InterfaceInfo],
    chosen_primary: &InterfaceInfo,
    persisted_state: &PersistedNetworkState,
) -> Result<InterfaceInfo> {
    if let Some(desired) = desired_name_for_primary(&chosen_primary.name) {
        let indices = persisted_state.get_family_max_indices();
        if desired != chosen_primary.name {
            rename_interface_collision(nl, interfaces, chosen_primary.ifindex, &desired, &indices)
                .await?;
        }
    }
    // Re-enumerate after potential rename to get correct ifindex by name.
    let final_interfaces = nl.get_interfaces().await?;
    let desired_name = desired_name_for_primary(&chosen_primary.name)
        .unwrap_or_else(|| chosen_primary.name.clone());
    let primary = final_interfaces
        .iter()
        .find(|n| n.name == desired_name)
        .unwrap_or(chosen_primary)
        .clone();
    Ok(primary)
}

async fn configure_primary_dhcp(
    nl: &NetlinkConnection,
    primary: &InterfaceInfo,
    bootstrap_ifindex: Option<u32>,
    persisted_state: &PersistedNetworkState,
) -> Result<DhcpLease> {
    // Clean up bootstrap if it's different from primary.
    if let Some(bootstrap_idx) = bootstrap_ifindex {
        if bootstrap_idx != primary.ifindex {
            // Bootstrap was on a different interface - flush it and configure primary.
            flush_interface(nl, bootstrap_idx).await;
            nl.link_up(primary.ifindex).await?;
            if let Some(mac) = primary.mac {
                return run_dhcp_on_interface(nl, &primary.name, primary.ifindex, mac).await;
            }
        }
        // If bootstrap_idx == primary.ifindex, the interface is already configured.
        // Get the current address configuration from the interface.
        // Note: DNS was written by bootstrap DHCP but we don't have it here to persist.
        let address = nl.get_interface_address_config(primary.ifindex).await?;
        return Ok(DhcpLease {
            address,
            resolver: ResolverConfig::default(),
        });
    } else {
        // No bootstrap (persisted primary) - try to use persisted config.
        nl.link_up(primary.ifindex).await?;
        if let Some(lease) = persisted_state.get_primary_dhcp_lease() {
            info!(
                "Using persisted IP configuration: {}/{}",
                lease.address.address, lease.address.prefix_len
            );
            configure_address_and_route(nl, primary.ifindex, &lease.address).await?;
            write_resolver_config(&lease.resolver)?;
            return Ok(lease);
        }
        // No persisted config, run DHCP.
        if let Some(mac) = primary.mac {
            return run_dhcp_on_interface(nl, &primary.name, primary.ifindex, mac).await;
        }
    }

    Err(anyhow!("no MAC address available for primary interface"))
}

fn extract_interface(link: LinkMessage) -> Result<InterfaceInfo> {
    let mut name: String = "".into();
    let mut mac = None;
    let mut is_virtual = false;
    let ifindex = link.header.index;

    for nla in &link.attributes {
        match nla {
            LinkAttribute::IfName(n) => name = n.clone(),
            LinkAttribute::Address(addr) if addr.len() == 6 => {
                let mut mac_arr = [0u8; 6];
                mac_arr.copy_from_slice(&addr[..6]);
                mac = Some(mac_arr);
            }
            LinkAttribute::LinkInfo(infos) => {
                if let Some(kind) = infos.iter().find_map(|link_info| {
                    if let LinkInfo::Kind(k) = link_info {
                        Some(k)
                    } else {
                        None
                    }
                }) {
                    is_virtual = is_virtual_kind(kind);
                }
            }
            _ => {}
        }
    }

    Ok(InterfaceInfo {
        name,
        mac,
        is_virtual,
        ifindex,
    })
}

fn is_virtual_kind(kind: &InfoKind) -> bool {
    matches!(
        kind,
        InfoKind::Veth
            | InfoKind::Vlan
            | InfoKind::Bridge
            | InfoKind::IpVlan
            | InfoKind::IpVtap
            | InfoKind::MacVlan
            | InfoKind::MacVtap
            | InfoKind::GreTap
            | InfoKind::GreTap6
            | InfoKind::IpIp
            | InfoKind::Ip6Tnl
            | InfoKind::SitTun
            | InfoKind::GreTun
            | InfoKind::GreTun6
            | InfoKind::Vti
            | InfoKind::Vrf
            | InfoKind::Gtp
            | InfoKind::Wireguard
            | InfoKind::Xfrm
            | InfoKind::MacSec
            | InfoKind::Hsr
            | InfoKind::Geneve
            | InfoKind::Netkit
            | InfoKind::Other(_)
    )
}

async fn restore_interfaces(
    nl: &NetlinkConnection,
    persisted_state: &PersistedNetworkState,
) -> Result<Vec<InterfaceInfo>> {
    let persisted = persisted_state.get_names();
    let interfaces = nl.get_interfaces().await?;
    if persisted.is_empty() {
        return Ok(interfaces);
    }
    let family_max_indices = persisted_state.get_family_max_indices();
    let mut current = interfaces.clone();
    for interface in interfaces {
        if let Some(mac) = interface.mac {
            let mac_str = mac_to_string(mac);
            if let Some(desired) = persisted.get(&mac_str)
                && *desired != interface.name
            {
                rename_interface_collision(
                    nl,
                    &current,
                    interface.ifindex,
                    desired,
                    &family_max_indices,
                )
                .await?;
                current = nl.get_interfaces().await?;
            }
        }
    }
    Ok(current)
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum IfFamily {
    Simple { prefix: String, index: u32 },
    Protected,
}

fn parse_family(name: &str) -> IfFamily {
    // Alphabetic prefix with trailing digits is Simple, anything else is Protected.
    let chars: Vec<char> = name.chars().collect();
    let mut i = chars.len();
    while i > 0 && chars[i - 1].is_ascii_digit() {
        i -= 1;
    }
    if i == chars.len() {
        return IfFamily::Protected;
    }
    let (prefix, suffix) = name.split_at(i);
    if !prefix.chars().all(|c| c.is_ascii_alphabetic()) {
        return IfFamily::Protected;
    }
    match suffix.parse::<u32>() {
        Ok(idx) => IfFamily::Simple {
            prefix: prefix.to_string(),
            index: idx,
        },
        Err(_) => IfFamily::Protected,
    }
}

fn desired_name_for_primary(current: &str) -> Option<String> {
    match parse_family(current) {
        IfFamily::Simple { prefix, .. } => Some(format!("{}0", prefix)),
        IfFamily::Protected => None,
    }
}

fn name_in_use<'a>(interfaces: &'a [InterfaceInfo], name: &str) -> Option<&'a InterfaceInfo> {
    interfaces.iter().find(|n| n.name == name)
}

fn next_family_index(
    interfaces: &[InterfaceInfo],
    prefix: &str,
    indices: &HashMap<String, u32>,
) -> u32 {
    let mut max_idx = 0u32;
    for interface in interfaces {
        if let Some(rest) = interface.name.strip_prefix(prefix)
            && let Ok(n) = rest.parse::<u32>()
            && n > max_idx
        {
            max_idx = n;
        }
    }
    if let Some(p) = indices.get(prefix)
        && *p > max_idx
    {
        max_idx = *p;
    }
    max_idx.saturating_add(1)
}

async fn rename_interface_collision(
    nl: &NetlinkConnection,
    interfaces: &[InterfaceInfo],
    primary_index: u32,
    desired: &str,
    indices: &HashMap<String, u32>,
) -> Result<()> {
    if let Some(existing) = name_in_use(interfaces, desired) {
        if existing.ifindex == primary_index {
            return Ok(());
        }
        // Collision: move the existing to prefix<n> then rename primary to desired.
        let (prefix, n) = match parse_family(desired) {
            IfFamily::Simple { prefix, .. } => {
                let n = next_family_index(interfaces, &prefix, indices);
                (prefix, n)
            }
            IfFamily::Protected => {
                return Err(anyhow!(
                    "BUG: attempted to rename interface {}, this should never happen",
                    desired
                ));
            }
        };
        let new_existing = format!("{}{}", prefix, n);
        nl.link_rename(existing.ifindex, &new_existing).await?;
        nl.link_rename(primary_index, desired).await?;
        Ok(())
    } else {
        nl.link_rename(primary_index, desired).await
    }
}

async fn ensure_loopback(nl: &NetlinkConnection, interfaces: &[InterfaceInfo]) -> Result<()> {
    if let Some(lo) = interfaces.iter().find(|n| n.name == "lo") {
        let mut have_v4 = false;
        let mut have_v6 = false;
        let lo_ipv4 = Ipv4Addr::new(127, 0, 0, 1);
        let lo_ipv6 = Ipv6Addr::new(0, 0, 0, 0, 0, 0, 0, 1);

        nl.link_up(lo.ifindex).await?;
        let mut addresses = nl.address_stream(Some(lo.ifindex));
        while let Some(msg_res) = addresses.next().await {
            let msg = msg_res?;
            for nla in &msg.attributes {
                if let AddrAttr::Address(ip) = nla {
                    match ip {
                        IpAddr::V4(a) => {
                            if *a == lo_ipv4 {
                                have_v4 = true;
                            }
                        }
                        IpAddr::V6(a) => {
                            if *a == lo_ipv6 {
                                have_v6 = true;
                            }
                        }
                    }
                }
            }
        }
        if !have_v4 {
            info!("Adding loopback IPv4 127.0.0.1/8");
            nl.address_add(lo.ifindex, IpAddr::V4(lo_ipv4), 8).await?;
        }
        if !have_v6 {
            info!("Adding loopback IPv6 ::1/128");
            nl.address_add(lo.ifindex, IpAddr::V6(lo_ipv6), 128).await?;
        }
    }
    Ok(())
}

// Best effort removal of default route and addresses on interface.
async fn flush_interface(nl: &NetlinkConnection, ifindex: u32) {
    let _ = nl
        .route_del(ifindex, IpAddr::V4(Ipv4Addr::new(0, 0, 0, 0)), 0)
        .await;
    let mut addresses = nl.address_stream(Some(ifindex));
    while let Some(addr_result) = addresses.next().await {
        if let Ok(a) = addr_result
            && a.header.index == ifindex
        {
            let _ = nl.address_del(a).await;
        }
    }
}

async fn wait_for_carrier(nl: &NetlinkConnection, ifindex: u32, timeout: Duration) -> Result<()> {
    let start = Instant::now();
    let cap = Duration::from_millis(500);
    let mut backoff = RetryBackoff::new(cap);
    loop {
        let mut links = nl.link_stream();
        while let Some(link_res) = links.next().await {
            let link = link_res?;
            if link.header.index != ifindex {
                continue;
            }
            for nla in &link.attributes {
                if let netlink_packet_route::link::LinkAttribute::Carrier(c) = nla
                    && *c == 1
                {
                    return Ok(());
                }
            }
        }
        let elapsed = start.elapsed();
        if elapsed >= timeout {
            return Err(anyhow!(
                "no carrier detected on interface within {} seconds",
                timeout.as_secs()
            ));
        }
        backoff.wait();
    }
}

async fn establish_bootstrap_connectivity(
    nl: &NetlinkConnection,
    interfaces: &[InterfaceInfo],
) -> Result<u32> {
    let ignored_prefixes = [
        "lo", "veth", "docker", "br", "virbr", "vlan", "tun", "tap", "macvtap", "bond", "team",
        "wg", "ppp", "dummy",
    ];

    info!(
        "Found {} total interfaces for bootstrap evaluation",
        interfaces.len()
    );

    let mut candidates: Vec<&InterfaceInfo> = interfaces
        .iter()
        .filter(|interface| {
            let is_virtual = interface.is_virtual;
            let is_ignored = ignored_prefixes
                .iter()
                .any(|p| interface.name.starts_with(p));
            info!(
                "Interface {}: virtual={}, ignored={}",
                interface.name, is_virtual, is_ignored
            );
            !(is_virtual || is_ignored)
        })
        .collect();

    info!(
        "Found {} candidate interfaces for bootstrap",
        candidates.len()
    );

    // Sort by index, hoping the first index is already the primary.
    candidates.sort_by_key(|i| i.ifindex);

    for interface in candidates {
        info!("Attempting bootstrap connectivity on {}", interface.name);

        if let Err(e) = nl.link_up(interface.ifindex).await {
            warn!("Failed to bring up {}: {}", interface.name, e);
            continue;
        }
        if let Err(e) = wait_for_carrier(nl, interface.ifindex, Duration::from_secs(30)).await {
            warn!("No carrier on {}: {}", interface.name, e);
            continue;
        }
        if let Some(mac) = interface.mac
            && run_dhcp_on_interface(nl, &interface.name, interface.ifindex, mac)
                .await
                .is_ok()
        {
            info!("Bootstrap connectivity established on {}", interface.name);
            return Ok(interface.ifindex);
        }
        warn!("DHCP failed on {}", interface.name);
    }
    Err(anyhow!("failed to establish DHCP connectivity"))
}

async fn discover_primary_mac_via_imds(
    imds_client: &ImdsClientAsync,
    timeout: Duration,
) -> Result<String> {
    imds_client.wait_for(timeout).await?;

    let macs_list: String = imds_client
        .get_metadata("network/interfaces/macs/")
        .await?
        .into();
    let macs = macs_list
        .lines()
        .map(|s| s.trim_end_matches('/').to_string())
        .filter(|s| !s.is_empty());
    for mac in macs {
        let devnum: String = imds_client
            .get_metadata(&format!("network/interfaces/macs/{}/device-number", mac))
            .await?
            .into();
        if devnum.trim() == "0" {
            info!("Discovered primary MAC from IMDS: {}", mac);
            return Ok(mac);
        }
    }
    Err(anyhow!("no interface found in IMDS with device number 0"))
}

#[derive(Serialize, Deserialize, Debug, Clone)]
struct InterfaceEntry {
    iface: String,
    mac: Option<String>,
    family: String,
    index: Option<u32>,
    primary: bool,
    present: bool,
    last_seen: String,
    // IP configuration from DHCP (for skipping DHCP on subsequent boots)
    #[serde(skip_serializing_if = "Option::is_none")]
    ip_address: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    prefix_len: Option<u8>,
    #[serde(skip_serializing_if = "Option::is_none")]
    gateway: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    dns_servers: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    domain_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    search_list: Option<Vec<String>>,
}

#[derive(Serialize, Deserialize, Debug, Default)]
struct PersistedNetworkState {
    interfaces: Vec<InterfaceEntry>,
}

impl PersistedNetworkState {
    fn get_family_max_indices(&self) -> HashMap<String, u32> {
        let mut map = HashMap::new();
        for interface in &self.interfaces {
            if interface.family != "protected"
                && !interface.family.is_empty()
                && let Some(idx) = interface.index
            {
                let entry = map.entry(interface.family.clone()).or_insert(0);
                if idx > *entry {
                    *entry = idx;
                }
            }
        }
        map
    }

    fn get_primary_mac(&self) -> Option<String> {
        self.interfaces
            .iter()
            .find(|iface| iface.primary)
            .and_then(|iface| iface.mac.as_ref())
            .filter(|mac| !mac.is_empty())
            .cloned()
    }

    fn get_names(&self) -> HashMap<String, String> {
        self.interfaces
            .iter()
            .filter(|iface| iface.family != "protected" && !iface.family.is_empty())
            .filter_map(|iface| match (&iface.mac, &iface.iface) {
                (Some(mac), name) if !mac.is_empty() && !name.is_empty() => {
                    Some((mac.clone(), name.clone()))
                }
                _ => None,
            })
            .collect()
    }

    fn get_primary_dhcp_lease(&self) -> Option<DhcpLease> {
        self.interfaces
            .iter()
            .find(|iface| iface.primary)
            .and_then(
                |iface| match (&iface.ip_address, iface.prefix_len, &iface.gateway) {
                    (Some(ip), Some(prefix), Some(gw)) => {
                        let address: Ipv4Addr = ip.parse().ok()?;
                        let gateway: Ipv4Addr = gw.parse().ok()?;
                        let dns_servers: Vec<Ipv4Addr> = iface
                            .dns_servers
                            .as_ref()
                            .map(|servers| servers.iter().filter_map(|s| s.parse().ok()).collect())
                            .unwrap_or_default();
                        Some(DhcpLease {
                            address: AddressConfig {
                                address,
                                prefix_len: prefix,
                                gateway,
                            },
                            resolver: ResolverConfig {
                                dns_servers,
                                domain_name: iface.domain_name.clone(),
                                search_list: iface.search_list.clone().unwrap_or_default(),
                            },
                        })
                    }
                    _ => None,
                },
            )
    }
}

fn mac_to_string(mac: [u8; 6]) -> String {
    format!(
        "{:02x}:{:02x}:{:02x}:{:02x}:{:02x}:{:02x}",
        mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]
    )
}

fn family_info(name: &str) -> (String, Option<u32>) {
    match parse_family(name) {
        IfFamily::Simple { prefix, index } => (prefix, Some(index)),
        IfFamily::Protected => ("protected".to_string(), None),
    }
}

fn persist_interfaces(
    interfaces: &[InterfaceInfo],
    primary_name: &str,
    primary_lease: Option<&DhcpLease>,
) -> Result<()> {
    let dt: chrono::DateTime<Utc> = SystemTime::now().into();
    let now = dt.to_rfc3339();
    let entries: Vec<InterfaceEntry> = interfaces
        .iter()
        .map(|n| {
            let (family, idx) = family_info(&n.name);
            let is_primary = n.name == primary_name;
            let (ip_address, prefix_len, gateway, dns_servers, domain_name, search_list) =
                if is_primary {
                    if let Some(lease) = primary_lease {
                        let dns = if lease.resolver.dns_servers.is_empty() {
                            None
                        } else {
                            Some(
                                lease
                                    .resolver
                                    .dns_servers
                                    .iter()
                                    .map(|s| s.to_string())
                                    .collect(),
                            )
                        };
                        let search = if lease.resolver.search_list.is_empty() {
                            None
                        } else {
                            Some(lease.resolver.search_list.clone())
                        };
                        (
                            Some(lease.address.address.to_string()),
                            Some(lease.address.prefix_len),
                            Some(lease.address.gateway.to_string()),
                            dns,
                            lease.resolver.domain_name.clone(),
                            search,
                        )
                    } else {
                        (None, None, None, None, None, None)
                    }
                } else {
                    (None, None, None, None, None, None)
                };
            InterfaceEntry {
                iface: n.name.clone(),
                mac: n.mac.map(mac_to_string),
                family,
                index: idx,
                primary: is_primary,
                present: true,
                last_seen: now.clone(),
                ip_address,
                prefix_len,
                gateway,
                dns_servers,
                domain_name,
                search_list,
            }
        })
        .collect();

    let payload = json!({ "interfaces": entries });
    let dir = format!("{}/net", DIR_ET_ETC);
    mkdir_p(Path::new(&dir), Mode::from(0o755))?;
    let path = format!("{}/interfaces.json", dir);

    atomic_write(&path, |mut f| {
        let s = serde_json::to_string_pretty(&payload)
            .map_err(|e| anyhow!("unable to convert payload to string: {}", e))?;
        f.write_all(s.as_bytes())
            .map_err(|e| anyhow!("unable to write {}: {}", path, e))
    })
}

fn load_persisted_state() -> Result<PersistedNetworkState> {
    let path = format!("{}/net/interfaces.json", DIR_ET_ETC);
    let data = match fs::read_to_string(&path) {
        Ok(s) => s,
        Err(_) => return Ok(PersistedNetworkState::default()),
    };
    serde_json::from_str(&data).map_err(|e| anyhow!("unable to parse {}: {}", path, e))
}

#[cfg(test)]
mod test {
    use super::*;

    #[test]
    fn test_mac_to_string() {
        assert_eq!(
            mac_to_string([0x00, 0x11, 0x22, 0x33, 0x44, 0x55]),
            "00:11:22:33:44:55"
        );
        assert_eq!(
            mac_to_string([0xff, 0xff, 0xff, 0xff, 0xff, 0xff]),
            "ff:ff:ff:ff:ff:ff"
        );
        assert_eq!(
            mac_to_string([0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
            "00:00:00:00:00:00"
        );
        assert_eq!(
            mac_to_string([0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f]),
            "0a:0b:0c:0d:0e:0f"
        );
    }

    #[test]
    fn test_parse_family_simple() {
        assert_eq!(
            parse_family("eth0"),
            IfFamily::Simple {
                prefix: "eth".to_string(),
                index: 0
            }
        );
        assert_eq!(
            parse_family("eth123"),
            IfFamily::Simple {
                prefix: "eth".to_string(),
                index: 123
            }
        );
        assert_eq!(
            parse_family("ens5"),
            IfFamily::Simple {
                prefix: "ens".to_string(),
                index: 5
            }
        );
    }

    #[test]
    fn test_parse_family_protected() {
        assert_eq!(parse_family("lo"), IfFamily::Protected);
        assert_eq!(parse_family("eth"), IfFamily::Protected);
        assert_eq!(parse_family("docker0bridge"), IfFamily::Protected);
    }

    #[test]
    fn test_desired_name_for_primary_simple() {
        assert_eq!(desired_name_for_primary("eth0"), Some("eth0".to_string()));
        assert_eq!(desired_name_for_primary("eth5"), Some("eth0".to_string()));
        assert_eq!(desired_name_for_primary("ens192"), Some("ens0".to_string()));
    }

    #[test]
    fn test_desired_name_for_primary_protected() {
        assert_eq!(desired_name_for_primary("lo"), None);
        assert_eq!(desired_name_for_primary("docker0bridge"), None);
    }

    #[test]
    fn test_family_info_simple() {
        assert_eq!(family_info("eth0"), ("eth".to_string(), Some(0)));
        assert_eq!(family_info("ens5"), ("ens".to_string(), Some(5)));
    }

    #[test]
    fn test_family_info_protected() {
        assert_eq!(family_info("lo"), ("protected".to_string(), None));
    }

    #[test]
    fn test_is_virtual_kind() {
        assert!(is_virtual_kind(&InfoKind::Veth));
        assert!(is_virtual_kind(&InfoKind::Bridge));
        assert!(is_virtual_kind(&InfoKind::Vlan));
        assert!(is_virtual_kind(&InfoKind::Wireguard));
        assert!(!is_virtual_kind(&InfoKind::Dummy));
    }

    #[test]
    fn test_get_primary_dhcp_lease_present() {
        let state = PersistedNetworkState {
            interfaces: vec![InterfaceEntry {
                iface: "eth0".to_string(),
                mac: Some("00:11:22:33:44:55".to_string()),
                family: "eth".to_string(),
                index: Some(0),
                primary: true,
                present: true,
                last_seen: "2026-01-01T00:00:00Z".to_string(),
                ip_address: Some("10.0.2.15".to_string()),
                prefix_len: Some(24),
                gateway: Some("10.0.2.2".to_string()),
                dns_servers: Some(vec!["8.8.8.8".to_string(), "8.8.4.4".to_string()]),
                domain_name: Some("example.com".to_string()),
                search_list: Some(vec!["example.com".to_string()]),
            }],
        };

        let lease = state.get_primary_dhcp_lease();
        assert!(lease.is_some());
        let lease = lease.unwrap();
        assert_eq!(lease.address.address, Ipv4Addr::new(10, 0, 2, 15));
        assert_eq!(lease.address.prefix_len, 24);
        assert_eq!(lease.address.gateway, Ipv4Addr::new(10, 0, 2, 2));
        assert_eq!(lease.resolver.dns_servers.len(), 2);
        assert_eq!(lease.resolver.dns_servers[0], Ipv4Addr::new(8, 8, 8, 8));
        assert_eq!(lease.resolver.domain_name, Some("example.com".to_string()));
        assert_eq!(lease.resolver.search_list, vec!["example.com".to_string()]);
    }

    #[test]
    fn test_get_primary_dhcp_lease_missing_ip() {
        let state = PersistedNetworkState {
            interfaces: vec![InterfaceEntry {
                iface: "eth0".to_string(),
                mac: Some("00:11:22:33:44:55".to_string()),
                family: "eth".to_string(),
                index: Some(0),
                primary: true,
                present: true,
                last_seen: "2026-01-01T00:00:00Z".to_string(),
                ip_address: None,
                prefix_len: None,
                gateway: None,
                dns_servers: None,
                domain_name: None,
                search_list: None,
            }],
        };

        assert!(state.get_primary_dhcp_lease().is_none());
    }

    #[test]
    fn test_get_primary_dhcp_lease_no_primary() {
        let state = PersistedNetworkState {
            interfaces: vec![InterfaceEntry {
                iface: "eth0".to_string(),
                mac: Some("00:11:22:33:44:55".to_string()),
                family: "eth".to_string(),
                index: Some(0),
                primary: false,
                present: true,
                last_seen: "2026-01-01T00:00:00Z".to_string(),
                ip_address: Some("10.0.2.15".to_string()),
                prefix_len: Some(24),
                gateway: Some("10.0.2.2".to_string()),
                dns_servers: None,
                domain_name: None,
                search_list: None,
            }],
        };

        assert!(state.get_primary_dhcp_lease().is_none());
    }

    #[test]
    fn test_interface_entry_serialization_with_ip() {
        let entry = InterfaceEntry {
            iface: "eth0".to_string(),
            mac: Some("00:11:22:33:44:55".to_string()),
            family: "eth".to_string(),
            index: Some(0),
            primary: true,
            present: true,
            last_seen: "2026-01-01T00:00:00Z".to_string(),
            ip_address: Some("10.0.2.15".to_string()),
            prefix_len: Some(24),
            gateway: Some("10.0.2.2".to_string()),
            dns_servers: Some(vec!["8.8.8.8".to_string()]),
            domain_name: Some("example.com".to_string()),
            search_list: Some(vec!["example.com".to_string()]),
        };

        let json = serde_json::to_string(&entry).unwrap();
        assert!(json.contains("\"ip_address\":\"10.0.2.15\""));
        assert!(json.contains("\"prefix_len\":24"));
        assert!(json.contains("\"gateway\":\"10.0.2.2\""));
        assert!(json.contains("\"dns_servers\":[\"8.8.8.8\"]"));
        assert!(json.contains("\"domain_name\":\"example.com\""));
        assert!(json.contains("\"search_list\":[\"example.com\"]"));

        let parsed: InterfaceEntry = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.ip_address, Some("10.0.2.15".to_string()));
        assert_eq!(parsed.prefix_len, Some(24));
        assert_eq!(parsed.gateway, Some("10.0.2.2".to_string()));
        assert_eq!(parsed.dns_servers, Some(vec!["8.8.8.8".to_string()]));
        assert_eq!(parsed.domain_name, Some("example.com".to_string()));
        assert_eq!(parsed.search_list, Some(vec!["example.com".to_string()]));
    }

    #[test]
    fn test_interface_entry_serialization_without_ip() {
        let entry = InterfaceEntry {
            iface: "eth0".to_string(),
            mac: Some("00:11:22:33:44:55".to_string()),
            family: "eth".to_string(),
            index: Some(0),
            primary: true,
            present: true,
            last_seen: "2026-01-01T00:00:00Z".to_string(),
            ip_address: None,
            prefix_len: None,
            gateway: None,
            dns_servers: None,
            domain_name: None,
            search_list: None,
        };

        let json = serde_json::to_string(&entry).unwrap();
        // With skip_serializing_if, None fields should not appear
        assert!(!json.contains("ip_address"));
        assert!(!json.contains("prefix_len"));
        assert!(!json.contains("gateway"));
        assert!(!json.contains("dns_servers"));
        assert!(!json.contains("domain_name"));
        assert!(!json.contains("search_list"));

        // But parsing it back should still work
        let parsed: InterfaceEntry = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.ip_address, None);
        assert_eq!(parsed.prefix_len, None);
        assert_eq!(parsed.gateway, None);
        assert_eq!(parsed.dns_servers, None);
        assert_eq!(parsed.domain_name, None);
        assert_eq!(parsed.search_list, None);
    }
}
