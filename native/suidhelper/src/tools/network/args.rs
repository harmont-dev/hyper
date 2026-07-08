//! Pure `ip`/`nft` argv builders for per-VM egress networking.
//!
//! Each step is data — a [`Command`] naming which privileged binary runs it and
//! its exact argv — so the sequences below can be asserted in
//! `tests/tools/network_args.rs` without root or a real network device.
//! Execution (actually invoking the binaries) lands in Task 4; this module only
//! builds the argv.
//!
//! Laws (tested):
//! - `prepare_commands` creates the netns first, and only requests the in-netns
//!   default route after the host veth (`hv<slot>`) is brought up — the guest's
//!   route target must already be reachable when the route is added.
//! - `teardown_commands` always deletes the netns, which reclaims the ns-side
//!   veth peer, the TAP device, and any in-netns nftables state.
//! - `host_init_commands` masquerades the clone pool out the configured uplink
//!   and drops guest traffic addressed to the cloud metadata IP
//!   (`169.254.169.254`), so no VM can ever reach it.
use super::addr::{self, Plan};

/// Which privileged binary a [`Command`] invokes. Kept to exactly two — `ip`
/// and `nft` — so the setuid helper's whitelist never grows past what egress
/// networking needs. In-netns `nft` operations still run as `ip netns exec <ns>
/// nft ...`, so they are represented as [`Which::Ip`] commands.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Which {
    Ip,
    Nft,
}

/// One step of a prepare/teardown/host-init sequence: the binary to run and its
/// exact argv (argv[0] is the binary itself, named by [`Which`], not repeated
/// here).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Command {
    pub bin: Which,
    pub argv: Vec<String>,
}

macro_rules! argv {
    ($($x:expr),* $(,)?) => {
        vec![$($x.to_string()),*]
    };
}

impl Command {
    fn ip(argv: Vec<String>) -> Self {
        Self {
            bin: Which::Ip,
            argv,
        }
    }

    /// `ip -n <netns> ...` — runs an `ip` operation inside the VM's netns.
    fn ip_ns(netns: &str, argv: Vec<String>) -> Self {
        let mut full = argv!["-n", netns];
        full.extend(argv);
        Self::ip(full)
    }

    fn nft(argv: Vec<String>) -> Self {
        Self {
            bin: Which::Nft,
            argv,
        }
    }

    /// `ip netns exec <netns> nft ...` — runs an `nft` operation inside the
    /// VM's netns, kept as a [`Which::Ip`] command so only `ip` and `nft` are
    /// ever the privileged binary named directly.
    fn nft_ns(netns: &str, argv: Vec<String>) -> Self {
        let mut full = argv!["netns", "exec", netns, "nft"];
        full.extend(argv);
        Self::ip(full)
    }
}

/// Bring up the VM's netns, host/ns veth pair, TAP device, and in-netns NAT so
/// the guest's inner address (`addr::INNER_GUEST_IP`) can reach the host's
/// uplink. The default route is requested last, after the host veth end
/// (`hv<slot>`) is up, so the route's target is already reachable.
pub fn prepare_commands(plan: &Plan) -> Vec<Command> {
    let netns = plan.netns.as_str();
    let veth_host = plan.veth_host.as_str();
    let veth_ns = plan.veth_ns.as_str();
    let veth_host_ip = plan.veth_host_ip;
    let veth_ns_ip = plan.veth_ns_ip;

    let mut commands = vec![
        Command::ip(argv!["netns", "add", netns]),
        Command::ip(argv![
            "link", "add", veth_host, "type", "veth", "peer", "name", veth_ns
        ]),
        Command::ip(argv!["link", "set", veth_ns, "netns", netns]),
        Command::ip(argv![
            "addr",
            "add",
            format!("{veth_host_ip}/{}", addr::INNER_PREFIX),
            "dev",
            veth_host
        ]),
        Command::ip(argv!["link", "set", veth_host, "up"]),
        Command::ip_ns(
            netns,
            argv![
                "addr",
                "add",
                format!("{veth_ns_ip}/{}", addr::INNER_PREFIX),
                "dev",
                veth_ns
            ],
        ),
        Command::ip_ns(netns, argv!["link", "set", veth_ns, "up"]),
        Command::ip_ns(netns, argv!["tuntap", "add", addr::TAP_NAME, "mode", "tap"]),
        Command::ip_ns(
            netns,
            argv![
                "addr",
                "add",
                format!("{}/{}", addr::INNER_TAP_IP, addr::INNER_PREFIX),
                "dev",
                addr::TAP_NAME
            ],
        ),
        Command::ip_ns(netns, argv!["link", "set", addr::TAP_NAME, "up"]),
        Command::ip_ns(netns, argv!["link", "set", "lo", "up"]),
        Command::ip_ns(netns, argv!["route", "add", "default", "via", veth_host_ip]),
    ];
    commands.extend(nft_prepare_commands(netns, veth_ns, veth_ns_ip));
    commands
}

/// The in-netns NAT: SNAT the guest's inner source address to the netns's own
/// veth IP on the way out (so the host sees a source unique to this VM), and
/// DNAT return traffic addressed to that veth IP back to the guest.
fn nft_prepare_commands(
    netns: &str,
    veth_ns: &str,
    veth_ns_ip: std::net::Ipv4Addr,
) -> Vec<Command> {
    vec![
        Command::nft_ns(netns, argv!["add", "table", "ip", "nat"]),
        Command::nft_ns(
            netns,
            argv![
                "add",
                "chain",
                "ip",
                "nat",
                "post",
                "{",
                "type",
                "nat",
                "hook",
                "postrouting",
                "priority",
                "100",
                ";",
                "}"
            ],
        ),
        Command::nft_ns(
            netns,
            argv![
                "add",
                "rule",
                "ip",
                "nat",
                "post",
                "ip",
                "saddr",
                addr::INNER_GUEST_IP,
                "oifname",
                veth_ns,
                "snat",
                "to",
                veth_ns_ip
            ],
        ),
        Command::nft_ns(
            netns,
            argv![
                "add",
                "chain",
                "ip",
                "nat",
                "pre",
                "{",
                "type",
                "nat",
                "hook",
                "prerouting",
                "priority",
                "-100",
                ";",
                "}"
            ],
        ),
        Command::nft_ns(
            netns,
            argv![
                "add",
                "rule",
                "ip",
                "nat",
                "pre",
                "ip",
                "daddr",
                veth_ns_ip,
                "dnat",
                "to",
                addr::INNER_GUEST_IP
            ],
        ),
    ]
}

/// Tear down a VM's netns. Deleting the netns reclaims the ns-side veth peer,
/// the TAP device, and any in-netns nftables state with it; the host-side veth
/// end usually goes with it too, but `ip link del` is issued explicitly in
/// case it lingers (a no-op if already gone).
pub fn teardown_commands(plan: &Plan) -> Vec<Command> {
    vec![
        Command::ip(argv!["netns", "del", plan.netns.as_str()]),
        Command::ip(argv!["link", "del", plan.veth_host.as_str()]),
    ]
}

/// One-time host setup: a `hyper` nftables table that masquerades the clone
/// pool out `uplink`, and a forward-chain default-drop policy that only admits
/// the pool's own traffic — explicitly dropping anything addressed to the
/// cloud metadata IP (`169.254.169.254`), so no VM can ever reach it.
pub fn host_init_commands(uplink: &str, clone_pool: &str) -> Vec<Command> {
    vec![
        Command::nft(argv!["add", "table", "ip", "hyper"]),
        Command::nft(argv![
            "add",
            "chain",
            "ip",
            "hyper",
            "postrouting",
            "{",
            "type",
            "nat",
            "hook",
            "postrouting",
            "priority",
            "100",
            ";",
            "}"
        ]),
        Command::nft(argv![
            "add",
            "rule",
            "ip",
            "hyper",
            "postrouting",
            "ip",
            "saddr",
            clone_pool,
            "oifname",
            uplink,
            "masquerade"
        ]),
        Command::nft(argv![
            "add", "chain", "ip", "hyper", "forward", "{", "type", "filter", "hook", "forward",
            "priority", "0", ";", "policy", "drop", ";", "}"
        ]),
        // Must precede the broad egress accept below: `accept` is a
        // terminating verdict in nftables, so a rule reachable before this
        // one would let a guest packet to the metadata IP exit via the
        // uplink before this drop is ever evaluated.
        Command::nft(argv![
            "add",
            "rule",
            "ip",
            "hyper",
            "forward",
            "ip",
            "saddr",
            clone_pool,
            "ip",
            "daddr",
            "169.254.169.254",
            "drop"
        ]),
        Command::nft(argv![
            "add", "rule", "ip", "hyper", "forward", "ip", "saddr", clone_pool, "oifname", uplink,
            "accept"
        ]),
        Command::nft(argv![
            "add",
            "rule",
            "ip",
            "hyper",
            "forward",
            "ip",
            "daddr",
            clone_pool,
            "ct",
            "state",
            "established,related",
            "accept"
        ]),
    ]
}
