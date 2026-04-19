#!/usr/bin/env bash
# verify.sh — run a full sanity check on the running lab
set -euo pipefail

LAB="clab-srl-l2vpn-mpls"
PASS=0; FAIL=0

check() {
  local desc=$1; shift
  if eval "$@" &>/dev/null; then
    echo "  PASS  $desc"
    ((PASS++))
  else
    echo "  FAIL  $desc"
    ((FAIL++))
  fi
}

echo "=== Underlay (IS-IS SR) ==="
check "R1-R2 IS-IS adjacency Up" \
  "docker exec ${LAB}-r1 sr_cli 'show network-instance default protocols isis neighbor' | grep -i 'up'"
check "R2-R3 IS-IS adjacency Up" \
  "docker exec ${LAB}-r2 sr_cli 'show network-instance default protocols isis neighbor' | grep -i 'up'"
check "R3-R4 IS-IS adjacency Up" \
  "docker exec ${LAB}-r3 sr_cli 'show network-instance default protocols isis neighbor' | grep -i 'up'"

echo ""
echo "=== SR-MPLS Transport ==="
check "R1 has SR tunnel to 4.4.4.4 (PE2)" \
  "docker exec ${LAB}-r1 sr_cli 'show tunnel-table all' | grep '4.4.4.4'"
check "R4 has SR tunnel to 1.1.1.1 (PE1)" \
  "docker exec ${LAB}-r4 sr_cli 'show tunnel-table all' | grep '1.1.1.1'"

echo ""
echo "=== Control Plane (BGP EVPN) ==="
check "R1 BGP EVPN to R4 Established" \
  "docker exec ${LAB}-r1 sr_cli 'show network-instance default protocols bgp neighbor 4.4.4.4' | grep -i 'established'"
check "R4 BGP EVPN to R1 Established" \
  "docker exec ${LAB}-r4 sr_cli 'show network-instance default protocols bgp neighbor 1.1.1.1' | grep -i 'established'"
check "R1 has EVPN IMET routes (Type 3)" \
  "docker exec ${LAB}-r1 sr_cli 'show network-instance l2vpn-100 protocols bgp-evpn routes' | grep -i 'imet\|type-3\|3'"
check "R4 has EVPN IMET routes (Type 3)" \
  "docker exec ${LAB}-r4 sr_cli 'show network-instance l2vpn-100 protocols bgp-evpn routes' | grep -i 'imet\|type-3\|3'"

echo ""
echo "=== Data Plane (L2VPN over MPLS) ==="
check "host1 → host2 ping" \
  "docker exec ${LAB}-host1 ping -c2 -W2 10.100.0.2"
check "host2 → host1 ping" \
  "docker exec ${LAB}-host2 ping -c2 -W2 10.100.0.1"

echo ""
echo "Result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
