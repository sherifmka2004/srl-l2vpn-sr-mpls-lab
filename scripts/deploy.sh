#!/usr/bin/env bash
# deploy.sh — bring up the SR-Linux L2VPN over MPLS (LDP) lab
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LAB="clab-srl-l2vpn-mpls"

echo "[1/3] Deploying ContainerLab topology..."
cd "$REPO_DIR"
containerlab deploy -t topology.yml --reconfigure

echo "[2/3] Waiting 75s for IS-IS + LDP + BGP EVPN convergence..."
sleep 75

echo ""
echo "=== IS-IS neighbours ==="
for r in r1 r2 r3 r4 r5; do
  echo "  --- $r ---"
  docker exec ${LAB}-${r} sr_cli "show network-instance default protocols isis neighbor" 2>/dev/null \
    | grep -E "Up|Down" || echo "    (no output yet)"
done

echo ""
echo "=== LDP sessions ==="
for r in r1 r2 r3 r4 r5; do
  echo "  --- $r ---"
  docker exec ${LAB}-${r} sr_cli "show network-instance default protocols ldp neighbor" 2>/dev/null \
    | grep -E "Operational|established" || echo "    (no sessions yet)"
done

echo ""
echo "=== BGP EVPN sessions (PE1 / PE2) ==="
for r in r1 r4; do
  echo "  --- $r ---"
  docker exec ${LAB}-${r} sr_cli "show network-instance default protocols bgp neighbor" 2>/dev/null \
    | grep -E "established|active|idle" || echo "    (no output yet)"
done

echo ""
echo "=== EVPN routes on R1 ==="
docker exec ${LAB}-r1 sr_cli \
  "show network-instance l2vpn-100 protocols bgp-evpn routes" 2>/dev/null | head -30 || echo "  (empty)"

echo ""
echo "Lab is up. Connect to a router with:"
echo "  docker exec -it ${LAB}-r1 sr_cli"
echo ""
echo "Test L2 extension between hosts:"
echo "  docker exec ${LAB}-host1 ping -c3 10.100.0.2"
