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
//! - `host_init_commands` masquerades the clone pool out the configured uplink,
//!   drops guest traffic addressed to the cloud metadata IP
//!   (`169.254.169.254`), and drops all clone-pool-sourced traffic addressed to
//!   the host itself on the INPUT hook (distinct from FORWARD — see that
//!   function's doc), so no VM can ever reach it or a host-local service.
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
/// here). `allow_failure` marks a step whose non-zero exit must not stop the
/// sequence — used only by the leading `nft delete table ip hyper` in
/// [`host_init_commands`], since that command's whole purpose is to clear
/// state that may not exist yet.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Command {
    pub bin: Which,
    pub argv: Vec<String>,
    pub allow_failure: bool,
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
            allow_failure: false,
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
            allow_failure: false,
        }
    }

    /// An `nft` step whose non-zero exit is tolerated — see the `allow_failure`
    /// doc on [`Command`].
    fn nft_allow_failure(argv: Vec<String>) -> Self {
        Self {
            allow_failure: true,
            ..Self::nft(argv)
        }
    }

    /// An `ip` step whose non-zero exit is tolerated — for idempotent deletes
    /// (`ip netns del`, `ip link del`) issued speculatively where the target may
    /// not exist. See the `allow_failure` doc on [`Command`].
    fn ip_allow_failure(argv: Vec<String>) -> Self {
        Self {
            allow_failure: true,
            ..Self::ip(argv)
        }
    }

    /// `ip netns exec <netns> <nft> ...` — runs an `nft` operation inside the
    /// VM's netns, kept as a [`Which::Ip`] command so only `ip` and `nft` are
    /// ever the privileged binary named directly. `nft` is the *absolute* path
    /// to the nft binary, not the bare name: the helper spawns every command
    /// with a cleared environment (no `PATH`), so `ip netns exec` could not
    /// resolve a bare `nft`, and the config names the exact binary anyway.
    fn nft_ns(netns: &str, nft: &str, argv: Vec<String>) -> Self {
        let mut full = argv!["netns", "exec", netns, nft];
        full.extend(argv);
        Self::ip(full)
    }

    /// `ip netns exec <netns> <sysctl> ...` — runs a `sysctl` write inside the
    /// VM's netns. Like [`nft_ns`], it stays a [`Which::Ip`] command (only `ip`
    /// and `nft` are ever the directly-named privileged binary) and takes the
    /// *absolute* sysctl path, since the helper clears `PATH` before spawning.
    fn sysctl_ns(netns: &str, sysctl: &str, argv: Vec<String>) -> Self {
        let mut full = argv!["netns", "exec", netns, sysctl];
        full.extend(argv);
        Self::ip(full)
    }
}

/// Bring up the VM's netns, host/ns veth pair, TAP device, and in-netns NAT so
/// the guest's inner address (`addr::INNER_GUEST_IP`) can reach the host's
/// uplink. The default route is requested last, after the host veth end
/// (`hv<slot>`) is up, so the route's target is already reachable.
pub fn prepare_commands(plan: &Plan, nft: &str, sysctl: &str) -> Vec<Command> {
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
        // A fresh netns defaults net.ipv4.ip_forward to 0 (independent of the
        // host's setting), so without this the netns silently drops every
        // packet it would route between the guest's tap and the veth uplink —
        // i.e. all guest egress. Enable it once the netns exists.
        Command::sysctl_ns(netns, sysctl, argv!["-w", "net.ipv4.ip_forward=1"]),
    ];
    commands.extend(nft_prepare_commands(netns, veth_ns, veth_ns_ip, nft));
    commands
}

/// The in-netns NAT: SNAT the guest's inner source address to the netns's own
/// veth IP on the way out (so the host sees a source unique to this VM), and
/// DNAT return traffic addressed to that veth IP back to the guest.
fn nft_prepare_commands(
    netns: &str,
    veth_ns: &str,
    veth_ns_ip: std::net::Ipv4Addr,
    nft: &str,
) -> Vec<Command> {
    vec![
        Command::nft_ns(netns, nft, argv!["add", "table", "ip", "nat"]),
        Command::nft_ns(
            netns,
            nft,
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
            nft,
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
            nft,
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
            nft,
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
///
/// Both deletes tolerate a missing target: `Daemon` runs teardown speculatively
/// in `clear_jail` *before* launching a fresh VM (to clear any stale prior
/// incarnation), so on a first boot the netns and veth do not exist yet —
/// `ip netns del` on a missing namespace exits non-zero, which must not fail
/// the launch. Like the chroot removal it sits beside, teardown is idempotent
/// cleanup; a genuine leak is backstopped by `Hyper.Node.Reaper`.
pub fn teardown_commands(plan: &Plan) -> Vec<Command> {
    vec![
        Command::ip_allow_failure(argv!["netns", "del", plan.netns.as_str()]),
        Command::ip_allow_failure(argv!["link", "del", plan.veth_host.as_str()]),
    ]
}

/// Tear down an *orphan* VM's netns by vm_id alone — no `uid`, so no [`Plan`]
/// and no host-veth `link del` (that command needs the derived `hv<slot>`
/// name, which needs the uid). Deleting the netns is sufficient on its own:
/// it reclaims the ns-side veth peer, the TAP device, and any in-netns
/// nftables state, and the kernel removes the host-side veth end along with
/// its peer's netns. See `teardown_orphan`'s module doc for why the caller
/// (`Hyper.Node.Reaper`) has no uid to give here.
pub fn teardown_orphan_commands(netns: &str) -> Vec<Command> {
    vec![Command::ip(argv!["netns", "del", netns])]
}

/// One-time host setup: a `hyper` nftables table that masquerades the clone
/// pool out `uplink`, a forward-chain default-drop policy that only admits
/// the pool's own traffic — explicitly dropping anything addressed to the
/// cloud metadata IP (`169.254.169.254`), so no VM can ever reach it — and an
/// input-chain rule that drops all clone-pool-sourced traffic addressed to
/// the host itself.
///
/// The input-chain drop closes a distinct hook from the forward-chain policy:
/// a guest packet addressed to a *host-owned* IP (the guest's own gateway
/// address, or any other address the host answers for) is locally delivered
/// and hits the kernel's INPUT hook, never FORWARD — so without this rule a
/// guest could reach host-local services (epmd, distribution, Postgres, the
/// gRPC listener) regardless of the forward-chain policy above. The input
/// chain's own policy stays `accept` so unrelated host traffic (SSH, other
/// subnets) is untouched; only clone-pool-sourced packets are dropped. This
/// does not affect guest egress (which is FORWARDed, never delivered to
/// INPUT) or ARP (an L2 protocol the `ip` family's INPUT hook never sees), and
/// the guest's DNS queries are forwarded to an external resolver, not
/// terminated on the host, so they are unaffected too.
///
/// Reconciles to desired state rather than diffing: the first command
/// unconditionally deletes the `hyper` table (tolerating "no such file" when
/// it doesn't exist yet), and every command after it rebuilds the table from
/// scratch. This makes host-init idempotent by construction — the table is
/// always either absent or complete, never partially applied — so a
/// crash/interruption mid-sequence on one run can never strand a later run
/// with, say, NAT but no forward-chain drop policy (or no input-chain
/// isolation).
pub fn host_init_commands(uplink: &str, clone_pool: &str) -> Vec<Command> {
    vec![
        Command::nft_allow_failure(argv!["delete", "table", "ip", "hyper"]),
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
        Command::nft(argv![
            "add", "chain", "ip", "hyper", "input", "{", "type", "filter", "hook", "input",
            "priority", "0", ";", "policy", "accept", ";", "}"
        ]),
        Command::nft(argv![
            "add", "rule", "ip", "hyper", "input", "ip", "saddr", clone_pool, "drop"
        ]),
    ]
}
