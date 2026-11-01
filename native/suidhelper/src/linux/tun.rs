use crate::fs::dev::{DeviceNode, DeviceNumber};
use crate::fs::file::IsCharDevice;
use crate::fs::path::StrictComponent;
use nix::sys::stat::Mode;

// `/dev/net/tun`'s well-known major:minor, per Linux's `Documentation/admin-guide/devices.txt`.
pub const NODE: DeviceNode<IsCharDevice> =
    DeviceNode::new(DeviceNumber::new(10, 200), Mode::from_bits_truncate(0o666));

pub const DEV: &StrictComponent = StrictComponent::from_static("dev");
pub const NET: &StrictComponent = StrictComponent::from_static("net");
pub const NAME: &StrictComponent = StrictComponent::from_static("tun");
