# SR-Linux L2VPN over MPLS (LDP) Lab

A 5-node ContainerLab topology using Nokia SR-Linux with an IS-IS IGP, LDP label distribution, BGP EVPN control plane, and an LDP-tunnelled SR-MPLS data plane delivering an EVPN MAC-VRF L2VPN between two Alpine hosts.

## Topology

Two equal-cost P paths exist between PE1 and PE2 (cost 30 each). IS-IS elects both simultaneously, and LDP builds LSPs over both — giving **ECMP** load-sharing on the L2VPN traffic.

```
                R2(P1) ── R3(P2)
               / metric     metric \
    10        10           10       10
R1(PE1) ─────────────────────────────── R4(PE2)
    15        \                   /  15
               R5(P3)────────────
                 metric 15   metric 15

Path 1: R1─R2─R3─R4  total cost = 10+10+10 = 30
Path 2: R1─R5─R4     total cost = 15+15    = 30  ← ECMP
```

```
host1 ── [R1/PE1] ══ LDP ECMP ══ [R4/PE2] ── host2
          1.1.1.1                  4.4.4.4
          │  BGP EVPN iBGP session (direct, loopback-to-loopback)  │
          └──────────── MAC-VRF l2vpn-100 EVI 100 encap mpls ──────┘
```

### Node roles

| Node | Role | IS-IS | LDP | BGP EVPN | MAC-VRF |
|------|------|-------|-----|----------|---------|
| R1 | PE1 | yes | yes — on e1-1, e1-3 | yes — peer R4 | yes — AC = e1-2 |
| R2 | P (transit) | yes | yes — on e1-1, e1-2 | no | no |
| R3 | P (transit) | yes | yes — on e1-1, e1-2 | no | no |
| R4 | PE2 | yes | yes — on e1-1, e1-3 | yes — peer R1 | yes — AC = e1-2 |
| R5 | P (alt path) | yes | yes — on e1-1, e1-2 | no | no |

### IP addressing

| Node | Interface | Address | IS-IS metric |
|------|-----------|---------|-------------|
| R1 | system0.0 | 1.1.1.1/32 | (loopback, passive) |
| R1 | ethernet-1/1.0 | 10.0.12.1/30 → R2 | 10 |
| R1 | ethernet-1/3.0 | 10.0.15.1/30 → R5 | 15 |
| R1 | ethernet-1/2 | bridged AC → host1 | — |
| R2 | system0.0 | 2.2.2.2/32 | (passive) |
| R2 | ethernet-1/1.0 | 10.0.12.2/30 → R1 | 10 |
| R2 | ethernet-1/2.0 | 10.0.23.1/30 → R3 | 10 |
| R3 | system0.0 | 3.3.3.3/32 | (passive) |
| R3 | ethernet-1/1.0 | 10.0.23.2/30 → R2 | 10 |
| R3 | ethernet-1/2.0 | 10.0.34.1/30 → R4 | 10 |
| R4 | system0.0 | 4.4.4.4/32 | (passive) |
| R4 | ethernet-1/1.0 | 10.0.34.2/30 → R3 | 10 |
| R4 | ethernet-1/3.0 | 10.0.45.2/30 → R5 | 15 |
| R4 | ethernet-1/2 | bridged AC → host2 | — |
| R5 | system0.0 | 5.5.5.5/32 | (passive) |
| R5 | ethernet-1/1.0 | 10.0.15.2/30 → R1 | 15 |
| R5 | ethernet-1/2.0 | 10.0.45.1/30 → R4 | 15 |
| host1 | eth1 | 10.100.0.1/24 | — |
| host2 | eth1 | 10.100.0.2/24 | — |

### How LDP builds the LSP

LDP runs **link-mode discovery** (UDP hellos on each data-plane interface). Once IS-IS has converged and the loopbacks are reachable, LDP opens a TCP session between transport addresses (the loopback IPs) and exchanges label bindings for every FEC (prefix) in the routing table.

The label stack on a frame from host1 → host2 via path R1-R2-R3-R4:

```
[ LDP transport label for 4.4.4.4 ] [ EVPN inner service label ] [ Ethernet frame ]
```

- R1 pushes both labels
- R2 swaps the outer label only (it does not see the inner label)
- R3 performs penultimate hop popping (PHP) — pops the outer label, forwards on inner
- R4 pops the inner EVPN label, delivers the raw Ethernet frame to host2's AC port

### LDP vs SR-MPLS — what changed

| Aspect | SR-MPLS (original) | LDP (this lab) |
|--------|--------------------|----------------|
| Label allocation | Global — prefix-SID index + SRGB = same label on every router | Local — each router assigns its own label per FEC |
| Control plane | IS-IS SR TLVs | Separate LDP TCP sessions |
| ECMP | IS-IS + SR ECMP | IS-IS ECMP → LDP follows same paths |
| PHP | implicit-null SID | LDP implicit-null by default |
| FRR | TI-LFA (sub-50ms) | Requires LFA/rLFA (slower convergence) |
| Config overhead | prefix-SID per loopback | LDP enabled per interface, transport address per router |

## Stack

| Layer | Technology |
|-------|-----------|
| Underlay IGP | IS-IS Level-2 |
| Label distribution | LDP (link discovery, loopback transport) |
| Control plane | BGP EVPN iBGP AS 65000 (PE1 ↔ PE2) |
| Data plane | EVPN MAC-VRF `l2vpn-100` · EVI 100 · encap-type mpls |
| Router image | `ghcr.io/nokia/srlinux:latest` |
| Host image | `alpine:latest` |
| Orchestration | ContainerLab 0.73+ |

## Prerequisites

- Linux host with Docker installed
- [ContainerLab](https://containerlab.dev) installed:
  ```bash
  bash -c "$(curl -sL https://get.containerlab.dev)"
  ```

## Usage

```bash
# Deploy
bash scripts/deploy.sh

# Verify
bash scripts/verify.sh

# Connect to a router
docker exec -it clab-srl-l2vpn-mpls-r1 sr_cli

# Test L2 extension
docker exec clab-srl-l2vpn-mpls-host1 ping -c3 10.100.0.2

# Tear down
bash scripts/destroy.sh
```

## Useful show commands (inside `sr_cli`)

```
# IS-IS adjacencies and database
show network-instance default protocols isis neighbor
show network-instance default protocols isis database

# IP routing table (all loopbacks should be present)
show network-instance default route-table all

# LDP sessions and label bindings
show network-instance default protocols ldp neighbor
show network-instance default protocols ldp bindings fec prefix 4.4.4.4/32

# MPLS forwarding (LDP label FIB)
show network-instance default tunnel-table all

# BGP EVPN
show network-instance default protocols bgp neighbor
show network-instance default protocols bgp neighbor 4.4.4.4 advertised-routes evpn
show network-instance default protocols bgp neighbor 4.4.4.4 received-routes evpn

# L2VPN MAC-VRF
show network-instance l2vpn-100 protocols bgp-evpn routes
show network-instance l2vpn-100 bridge-table mac-table all
```

## Troubleshooting notes

- **LDP session stuck**: LDP TCP sessions use the loopback as transport. IS-IS *must* have fully converged (all loopbacks reachable) before LDP can connect. Check `show network-instance default route-table all` first.
- **BGP EVPN stuck in Active**: BGP is also loopback-sourced. Confirm LDP is operational and `4.4.4.4` appears in R1's tunnel table before investigating BGP.
- **Only one LDP path visible on PE**: Check IS-IS metrics — both paths must have the same total cost for ECMP. R1-R2-R3-R4 = 30, R1-R5-R4 = 30.
- **Ping fails but BGP is up**: EVPN IMET (Type-3) routes build the flood list. Run `show network-instance l2vpn-100 protocols bgp-evpn routes` on both PEs; if empty, BGP may have established but not yet exchanged EVPN routes.
- **SR-Linux LDP note**: LDP on SR-Linux was introduced in 21.11. If using an older image, LDP may not be available — use `ghcr.io/nokia/srlinux:latest` to avoid this.

## File structure

```
.
├── README.md
├── topology.yml                  # ContainerLab topology
├── configs/
│   ├── r1/config.cli             # PE1: IS-IS + LDP + BGP EVPN + MAC-VRF
│   ├── r2/config.cli             # P1 : IS-IS + LDP transit
│   ├── r3/config.cli             # P2 : IS-IS + LDP transit
│   ├── r4/config.cli             # PE2: IS-IS + LDP + BGP EVPN + MAC-VRF
│   └── r5/config.cli             # P3 : IS-IS + LDP transit (alternate path)
└── scripts/
    ├── deploy.sh
    ├── destroy.sh
    └── verify.sh
```
