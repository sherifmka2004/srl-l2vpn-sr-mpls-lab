# SR-Linux L2VPN over MPLS Lab

A 4-node ContainerLab topology using Nokia SR-Linux with an IS-IS SR underlay, BGP EVPN control plane, and SR-MPLS data plane delivering a point-to-multipoint L2VPN (MAC-VRF) between two Alpine hosts.

## Why L2VPN over MPLS?

VXLAN tunnels L2 over IP/UDP — practical in data centres but it bypasses the MPLS forwarding plane entirely. **L2VPN over MPLS** (commonly called VPLS or EVPN-MPLS) pushes Ethernet frames directly into MPLS-labelled packets, so every hop between the two PEs does pure label-swap operations — no IP lookup needed in the transit path.

This matters when you want:
- Sub-50 ms FRR via Segment Routing (traffic-engineered label-switched paths)
- QoS mapped from the MPLS EXP bits rather than DSCP
- A realistic model of how carrier Ethernet/MPLS networks actually work

## Architecture

```
              ┌─────────────────────────────────────────────────┐
              │        SR-MPLS transport  (IS-IS SR)            │
              │  SRGB base 100000  ·  all links metric 10       │
              │                                                  │
host1 ── [R1/PE1] ──── [R2/P] ──── [R3/P] ──── [R4/PE2] ── host2
         1.1.1.1      2.2.2.2    3.3.3.3      4.4.4.4
         SID:1        SID:2      SID:3        SID:4
              │                                                  │
              │   BGP EVPN iBGP session (PE1 ↔ PE2 only)       │
              │   MAC-VRF l2vpn-100 · EVI 100 · encap mpls      │
              └─────────────────────────────────────────────────┘
```

### What each node does

| Node | Role | IS-IS SR | BGP EVPN | MAC-VRF |
|------|------|----------|----------|---------|
| R1 | PE1 | yes — prefix-SID 1 | yes — neighbor R4 | yes — AC = eth-1/2 |
| R2 | P (transit) | yes — prefix-SID 2 | no | no |
| R3 | P (transit) | yes — prefix-SID 3 | no | no |
| R4 | PE2 | yes — prefix-SID 4 | yes — neighbor R1 | yes — AC = eth-1/2 |

### IP addressing

| Node | Interface | Address | Purpose |
|------|-----------|---------|---------|
| R1 | system0.0 | 1.1.1.1/32 | Loopback / BGP source |
| R1 | ethernet-1/1.0 | 10.0.12.1/30 | Underlay to R2 |
| R1 | ethernet-1/2 | — (bridged) | AC to host1 |
| R2 | system0.0 | 2.2.2.2/32 | Loopback |
| R2 | ethernet-1/1.0 | 10.0.12.2/30 | Underlay to R1 |
| R2 | ethernet-1/2.0 | 10.0.23.1/30 | Underlay to R3 |
| R3 | system0.0 | 3.3.3.3/32 | Loopback |
| R3 | ethernet-1/1.0 | 10.0.23.2/30 | Underlay to R2 |
| R3 | ethernet-1/2.0 | 10.0.34.1/30 | Underlay to R4 |
| R4 | system0.0 | 4.4.4.4/32 | Loopback / BGP source |
| R4 | ethernet-1/1.0 | 10.0.34.2/30 | Underlay to R3 |
| R4 | ethernet-1/2 | — (bridged) | AC to host2 |
| host1 | eth1 | 10.100.0.1/24 | L2VPN endpoint |
| host2 | eth1 | 10.100.0.2/24 | L2VPN endpoint |

### Label stack on the wire (host1 → host2)

```
[ outer: 100004 (prefix-SID of R4) ][ inner: EVPN service label ][ Ethernet frame ]
```

R2 and R3 swap the outer label only; the inner EVPN label is untouched until R4 pops it and delivers the raw Ethernet frame to host2.

## Stack

| Layer | Technology |
|-------|-----------|
| Underlay IGP | IS-IS Level-2 (SR-Linux isis instance `main`) |
| Transport | Segment Routing MPLS — SRGB 100000–100999 |
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
- SR-Linux image pulled (ContainerLab pulls it automatically, or manually):
  ```bash
  docker pull ghcr.io/nokia/srlinux:latest
  ```

## Usage

```bash
# Deploy the full lab (runs from repo root — ContainerLab reads startup-config relative to topology.yml)
bash scripts/deploy.sh

# Verify everything is working
bash scripts/verify.sh

# Connect to a router
docker exec -it clab-srl-l2vpn-mpls-r1 sr_cli

# Test L2 extension between hosts
docker exec clab-srl-l2vpn-mpls-host1 ping -c3 10.100.0.2

# Tear down
bash scripts/destroy.sh
```

## Useful show commands (inside `sr_cli`)

```
# Underlay
show network-instance default protocols isis neighbor
show network-instance default protocols isis database
show network-instance default route-table all

# SR-MPLS tunnels
show tunnel-table all
show tunnel-table ipv4 prefix 4.4.4.4/32

# MPLS forwarding (label FIB)
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

- **IS-IS doesn't form**: check `show interface ethernet-1/1 detail` — the interface must be `up/up`. SR-Linux needs the physical link state to be up, which ContainerLab ensures via the veth pair.
- **BGP EVPN stuck in Active**: IS-IS must have converged and `4.4.4.4` must be reachable from R1 before BGP can connect (loopback-sourced session). Check `show tunnel-table all` on R1 first.
- **Ping fails but BGP is up**: check that EVPN IMET (Type-3) routes have been exchanged — these build the flood list for unknown unicast/BUM traffic. Run `show network-instance l2vpn-100 protocols bgp-evpn routes` on both PEs.
- **startup-config not applied**: ContainerLab reads the `.cli` file path relative to `topology.yml`. Always run `deploy.sh` from the repo root (the script handles this via `cd "$REPO_DIR"`).

## File structure

```
.
├── README.md
├── topology.yml                  # ContainerLab topology
├── configs/
│   ├── r1/config.cli             # PE1: IS-IS SR + BGP EVPN + MAC-VRF
│   ├── r2/config.cli             # P1 : IS-IS SR transit only
│   ├── r3/config.cli             # P2 : IS-IS SR transit only
│   └── r4/config.cli             # PE2: IS-IS SR + BGP EVPN + MAC-VRF
└── scripts/
    ├── deploy.sh                 # Deploy + convergence wait + status
    ├── destroy.sh                # Tear down lab
    └── verify.sh                 # Automated PASS/FAIL checks
```
