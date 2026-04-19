# SR-Linux L2VPN over MPLS (LDP) Lab

A 5-node ContainerLab topology using Nokia SR-Linux with an IS-IS IGP, LDP label distribution, BGP EVPN control plane, and an LDP-signalled MPLS data plane delivering an EVPN MAC-VRF L2VPN between two Alpine hosts.

## Why L2VPN over MPLS?

Traditional VLANs are confined to a single physical Layer 2 domain. VXLAN tunnels L2 over IP/UDP — practical in data centres but it bypasses the MPLS forwarding plane entirely. **L2VPN over MPLS** (EVPN-MPLS / VPLS) pushes Ethernet frames directly into MPLS-labelled packets, so every transit hop does a pure label-swap — no IP lookup in the P nodes. This models how carrier Ethernet/MPLS networks actually work.

## Why LDP?

**LDP (Label Distribution Protocol, RFC 5036)** is the original and still widely-deployed mechanism for building MPLS LSPs. Each router independently assigns a label to each FEC (prefix), then distributes those bindings to its LDP neighbours over a dedicated TCP session. The result is a hop-by-hop label-switched path for every prefix in the IGP.

LDP differs from SR-MPLS in a few key ways:

| Aspect | LDP | SR-MPLS |
|--------|-----|---------|
| Label scope | Locally significant — each router assigns its own | Globally significant — prefix-SID + SRGB = same label everywhere |
| Control plane | Separate LDP TCP sessions per neighbour | IS-IS/OSPF TLV extensions |
| ECMP | Follows IGP ECMP paths automatically | Same |
| PHP | Implicit-null by default | Implicit-null SID |
| Fast reroute | LFA / rLFA | TI-LFA (sub-50ms, built into IS-IS) |
| Deployment era | Widely deployed since early 2000s | Greenfield / modern networks |

## Topology

Two equal-cost P paths exist between PE1 and PE2 (IS-IS cost 30 each). LDP builds LSPs over both paths, giving **ECMP** load-sharing for the L2VPN traffic.

```
                      metric 10       metric 10
               ┌──── R2 (P1) ──────── R3 (P2) ────┐
               │   10.0.12.0/30    10.0.23.0/30    │  10.0.34.0/30
               │                                    │
host1 ──── R1 (PE1)                              R4 (PE2) ──── host2
10.100.0.1  1.1.1.1                              4.4.4.4   10.100.0.2
               │   10.0.15.0/30    10.0.45.0/30    │
               └──── R5 (P3) ────────────────────┘
                      metric 15       metric 15

 Path 1: R1 ─ R2 ─ R3 ─ R4   IS-IS cost = 10+10+10 = 30
 Path 2: R1 ─ R5 ─ R4        IS-IS cost = 15+15    = 30  ← ECMP
```

```mermaid
graph TB
    subgraph overlay["L2VPN Overlay — MAC-VRF l2vpn-100 · EVI 100 · encap mpls"]
        H1["host1\n10.100.0.1"]
        H2["host2\n10.100.0.2"]
    end

    H1 -- eth1 --- R1
    H2 -- eth1 --- R4

    subgraph underlay["Underlay — IS-IS L2 · LDP LSPs · BGP EVPN iBGP AS 65000"]
        R1["R1 / PE1\n1.1.1.1"]
        R2["R2 / P1\n2.2.2.2"]
        R3["R3 / P2\n3.3.3.3"]
        R4["R4 / PE2\n4.4.4.4"]
        R5["R5 / P3\n5.5.5.5"]
    end

    R1 -- "10.0.12.0/30\nmetric 10" --- R2
    R2 -- "10.0.23.0/30\nmetric 10" --- R3
    R3 -- "10.0.34.0/30\nmetric 10" --- R4
    R1 -- "10.0.15.0/30\nmetric 15" --- R5
    R5 -- "10.0.45.0/30\nmetric 15" --- R4

    R1 -. "BGP EVPN iBGP\n(loopback-to-loopback)" .- R4
```

### How LDP builds the LSP

LDP runs **link-mode discovery** (UDP hellos on each data-plane interface). Once IS-IS has converged and all loopbacks are reachable, each router opens a TCP LDP session to its directly connected neighbours (sourced from the loopback) and exchanges label bindings for every prefix in the routing table.

The label stack on the wire (host1 → host2 via path R1-R2-R3-R4):

```
┌──────────────────────────────┬─────────────────────┬───────────────────┐
│ LDP outer label (for 4.4.4.4)│ EVPN inner svc label│  Ethernet frame   │
└──────────────────────────────┴─────────────────────┴───────────────────┘

  R1  → pushes both labels (outer = LDP FEC for 4.4.4.4, inner = EVPN allocated label)
  R2  → swaps outer label only (inner label is opaque)
  R3  → penultimate hop pop (PHP) — pops outer label, forwards on inner label alone
  R4  → pops inner EVPN label, delivers raw Ethernet frame to host2's AC port
```

### Node roles

| Node | Role | IS-IS | LDP | BGP EVPN | MAC-VRF |
|------|------|-------|-----|----------|---------|
| R1 | PE1 | L2, passive lo | e1-1, e1-3 | yes — peer R4 | yes — AC = e1-2 |
| R2 | P (transit) | L2, passive lo | e1-1, e1-2 | no | no |
| R3 | P (transit) | L2, passive lo | e1-1, e1-2 | no | no |
| R4 | PE2 | L2, passive lo | e1-1, e1-3 | yes — peer R1 | yes — AC = e1-2 |
| R5 | P (alt path) | L2, passive lo | e1-1, e1-2 | no | no |

### IP addressing

| Node | Interface | Address | IS-IS metric |
|------|-----------|---------|-------------|
| R1 | system0.0 | 1.1.1.1/32 | passive |
| R1 | ethernet-1/1.0 | 10.0.12.1/30 → R2 | 10 |
| R1 | ethernet-1/3.0 | 10.0.15.1/30 → R5 | 15 |
| R1 | ethernet-1/2 | bridged AC → host1 | — |
| R2 | system0.0 | 2.2.2.2/32 | passive |
| R2 | ethernet-1/1.0 | 10.0.12.2/30 → R1 | 10 |
| R2 | ethernet-1/2.0 | 10.0.23.1/30 → R3 | 10 |
| R3 | system0.0 | 3.3.3.3/32 | passive |
| R3 | ethernet-1/1.0 | 10.0.23.2/30 → R2 | 10 |
| R3 | ethernet-1/2.0 | 10.0.34.1/30 → R4 | 10 |
| R4 | system0.0 | 4.4.4.4/32 | passive |
| R4 | ethernet-1/1.0 | 10.0.34.2/30 → R3 | 10 |
| R4 | ethernet-1/3.0 | 10.0.45.2/30 → R5 | 15 |
| R4 | ethernet-1/2 | bridged AC → host2 | — |
| R5 | system0.0 | 5.5.5.5/32 | passive |
| R5 | ethernet-1/1.0 | 10.0.15.2/30 → R1 | 15 |
| R5 | ethernet-1/2.0 | 10.0.45.1/30 → R4 | 15 |
| host1 | eth1 | 10.100.0.1/24 | — |
| host2 | eth1 | 10.100.0.2/24 | — |

## Stack

| Layer | Technology |
|-------|-----------|
| Underlay IGP | IS-IS Level-2 (point-to-point links) |
| Label distribution | LDP — link discovery (UDP hello) + loopback transport (TCP) |
| ECMP | IS-IS equal-cost multipath → LDP LSPs on both paths |
| Control plane | BGP EVPN iBGP AS 65000 (PE1 ↔ PE2, loopback-sourced) |
| Data plane | EVPN MAC-VRF `l2vpn-100` · EVI 100 · `encap-type mpls` |
| Router image | `ghcr.io/nokia/srlinux:latest` (requires ≥ 21.11 for LDP) |
| Host image | `alpine:latest` |
| Orchestration | ContainerLab 0.73+ |

## Access

### From the ContainerLab host

```bash
# SR-Linux CLI
docker exec -it clab-srl-l2vpn-mpls-ldp-r1 sr_cli

# Bash shell (if needed)
docker exec -it clab-srl-l2vpn-mpls-ldp-r1 bash
```

### From a remote Linux machine (SSH)

ContainerLab assigns each node a management IP on `172.21.22.0/24`. Find them with:

```bash
containerlab inspect -t topology.yml
```

Then on the **remote machine**, add a route to the management subnet and SSH in:

```bash
# Add route via the ContainerLab host IP (replace with your actual host IP)
ip route add 172.21.22.0/24 via <containerlab-host-ip>

# SSH into any router
ssh admin@<node-mgmt-ip>
```

SR-Linux default credentials:

| Field    | Value        |
|----------|--------------|
| Username | `admin`      |
| Password | `NokiaSrl1!` |
| SSH port | `22`         |

> The ContainerLab host must have IP forwarding enabled: `sysctl -w net.ipv4.ip_forward=1`

### gNMI / gRPC (port 57400)

```bash
gnmic -a <node-mgmt-ip>:57400 -u admin -p NokiaSrl1! --skip-verify get \
  --path /network-instance[name=default]/protocols/isis
```

## Prerequisites

- Linux host with Docker installed
- [ContainerLab](https://containerlab.dev) installed:
  ```bash
  bash -c "$(curl -sL https://get.containerlab.dev)"
  ```
- SR-Linux image (ContainerLab pulls it automatically on first deploy)

## Usage

```bash
# Deploy the full lab (run from repo root)
bash scripts/deploy.sh

# Automated PASS/FAIL checks
bash scripts/verify.sh

# Connect to a router
docker exec -it clab-srl-l2vpn-mpls-ldp-r1 sr_cli

# Test L2 extension between hosts
docker exec clab-srl-l2vpn-mpls-ldp-host1 ping -c3 10.100.0.2

# Tear down
bash scripts/destroy.sh
```

## Useful show commands (inside `sr_cli`)

```
# IS-IS adjacencies and link-state database
show network-instance default protocols isis neighbor
show network-instance default protocols isis database

# Full IP routing table — all 5 loopbacks should appear
show network-instance default route-table all

# LDP peer sessions (one per directly connected neighbour)
show network-instance default protocols ldp neighbor

# LDP label bindings for a specific FEC
show network-instance default protocols ldp bindings fec prefix 4.4.4.4/32

# MPLS tunnel table — confirms LDP LSPs are installed (ECMP shows 2 entries for 4.4.4.4)
show network-instance default tunnel-table all

# BGP EVPN session state
show network-instance default protocols bgp neighbor
show network-instance default protocols bgp neighbor 4.4.4.4 advertised-routes evpn
show network-instance default protocols bgp neighbor 4.4.4.4 received-routes evpn

# L2VPN MAC-VRF — EVPN routes and learned MACs
show network-instance l2vpn-100 protocols bgp-evpn routes
show network-instance l2vpn-100 bridge-table mac-table all
```

## Convergence order

The three protocol layers must converge in sequence — each depends on the one below:

```
1. IS-IS  →  all loopbacks reachable via IP
2. LDP    →  TCP sessions open between loopbacks; LSPs installed in tunnel-table
3. BGP    →  EVPN session between 1.1.1.1 and 4.4.4.4; IMET + MAC/IP routes exchanged
4. L2VPN  →  flood list built from IMET routes; host pings succeed
```

## Troubleshooting

| Symptom | First check |
|---------|-------------|
| LDP session stuck / not forming | `show network-instance default route-table all` — IS-IS must have converged before LDP can open TCP to the remote loopback |
| BGP EVPN stuck in Active | `show network-instance default tunnel-table all` on R1 — `4.4.4.4` must appear as an LDP tunnel before BGP can connect |
| Only one LDP path to PE2 | IS-IS metrics: R1-R2-R3-R4 must equal R1-R5-R4 (both = 30). Check `show network-instance default protocols isis database` |
| Ping fails but BGP is Established | `show network-instance l2vpn-100 protocols bgp-evpn routes` on both PEs — IMET (Type-3) routes must be present to build the flood list |
| LDP not recognised | SR-Linux image is older than 21.11 — pull `ghcr.io/nokia/srlinux:latest` |

## File structure

```
.
├── README.md
├── topology.yml                  # ContainerLab topology (nodes + links)
├── configs/
│   ├── r1/config.cli             # PE1: IS-IS + LDP + BGP EVPN + MAC-VRF l2vpn-100
│   ├── r2/config.cli             # P1 : IS-IS + LDP transit only
│   ├── r3/config.cli             # P2 : IS-IS + LDP transit only
│   ├── r4/config.cli             # PE2: IS-IS + LDP + BGP EVPN + MAC-VRF l2vpn-100
│   └── r5/config.cli             # P3 : IS-IS + LDP transit only (alternate path)
└── scripts/
    ├── deploy.sh                 # Deploy + convergence wait + status summary
    ├── destroy.sh                # Tear down and clean up
    └── verify.sh                 # Automated PASS/FAIL checks for all layers
```
