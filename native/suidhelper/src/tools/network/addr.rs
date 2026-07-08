//! Pure address & interface-name math for per-VM egress networking.
//!
//! Laws (see `tests/tools/network_addr.rs`):
//! - the derived clone `/30` always lands inside the configured pool, never in
//!   the inner `172.30.0.0/30` constant space;
//! - `veth` names always satisfy `IFNAMSIZ` (<= 15);
//! - a `uid` below the accepted range, or a `slot` past the pool's capacity, is
//!   *always* refused — never wrapped into another VM's address.
use crate::tools::jailer::VmId;
use std::net::Ipv4Addr;
use thiserror::Error;

pub const INNER_TAP_IP: Ipv4Addr = Ipv4Addr::new(172, 30, 0, 1);
pub const INNER_GUEST_IP: Ipv4Addr = Ipv4Addr::new(172, 30, 0, 2);
pub const INNER_PREFIX: u8 = 30;
pub const TAP_NAME: &str = "tap0";
pub const GUEST_IFACE: &str = "eth0";

#[derive(Debug, Error)]
pub enum AddrError {
    #[error("uid {uid} is below the accepted range floor {floor}")]
    UidBelowRange { uid: u32, floor: u32 },
    #[error("slot {slot} does not fit the clone pool")]
    SlotOutOfPool { slot: u32 },
}

#[derive(Debug, Clone)]
pub struct Plan {
    pub slot: u32,
    pub netns: String,
    pub veth_host: String,
    pub veth_ns: String,
    pub veth_host_ip: Ipv4Addr,
    pub veth_ns_ip: Ipv4Addr,
}

impl Plan {
    pub fn derive(
        uid: u32,
        uid_range: (u32, u32),
        clone_pool: Ipv4Addr,
        vm_id: &VmId,
    ) -> Result<Self, AddrError> {
        let floor = uid_range.0;
        if uid < floor {
            return Err(AddrError::UidBelowRange { uid, floor });
        }
        let slot = uid - floor;
        // Each VM consumes a /30 (4 addresses). The block's last address must
        // stay within the 32-bit space above the pool base.
        let base = u32::from(clone_pool);
        let block = base
            .checked_add(
                slot.checked_mul(4)
                    .ok_or(AddrError::SlotOutOfPool { slot })?,
            )
            .ok_or(AddrError::SlotOutOfPool { slot })?;
        // Guard against overflowing the pool's own /16 (65_536 addresses).
        if slot >= (1u32 << 16) / 4 {
            return Err(AddrError::SlotOutOfPool { slot });
        }
        let veth_host_ip = block
            .checked_add(1)
            .ok_or(AddrError::SlotOutOfPool { slot })?;
        let veth_ns_ip = block
            .checked_add(2)
            .ok_or(AddrError::SlotOutOfPool { slot })?;
        Ok(Self {
            slot,
            netns: vm_id.to_string(),
            veth_host: format!("hv{slot}"),
            veth_ns: format!("hp{slot}"),
            veth_host_ip: Ipv4Addr::from(veth_host_ip),
            veth_ns_ip: Ipv4Addr::from(veth_ns_ip),
        })
    }
}
