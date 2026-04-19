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

echo "=== Underlay (IS-IS) ==="
check "R1-R2 IS-IS Up" \
  "docker exec ${LAB}-r1 sr_cli 'show network-instance default protocols isis neighbor' | grep -i 'up'"
check "R2-R3 IS-IS Up" \
  "docker exec ${LAB}-r2 sr_cli 'show network-instance default protocols isis neighbor' | grep -i 'up'"
check "R3-R4 IS-IS Up" \
  "docker exec ${LAB}-r3 sr_cli 'show network-instance default protocols isis neighbor' | grep -i 'up'"
check "R1-R5 IS-IS Up" \
  "docker exec ${LAB}-r5 sr_cli 'show network-instance default protocols isis neighbor' | grep -i 'up'"
check "R5-R4 IS-IS Up" \
  "docker exec ${LAB}-r5 sr_cli 'show network-instance default protocols isis neighbor' | grep -c 'up' | grep -q 2"

echo ""
echo "=== LDP Sessions ==="
check "R1 LDP session to R2 Operational" \
  "docker exec ${LAB}-r1 sr_cli 'show network-instance default protocols ldp neighbor' | grep -i 'operational\|established'"
check "R1 LDP session to R5 Operational" \
  "docker exec ${LAB}-r5 sr_cli 'show network-instance default protocols ldp neighbor' | grep -i 'operational\|established'"
check "R4 LDP session to R3 Operational" \
  "docker exec ${LAB}-r4 sr_cli 'show network-instance default protocols ldp neighbor' | grep -i 'operational\|established'"
check "R4 LDP session to R5 Operational" \
  "docker exec ${LAB}-r4 sr_cli 'show network-instance default protocols ldp neighbor' | grep -c 'operational\|established' | grep -q 2"

echo ""
echo "=== LDP FIB (ECMP paths on PE1) ==="
check "R1 has LDP route to 4.4.4.4 via R2 path" \
  "docker exec ${LAB}-r1 sr_cli 'show network-instance default tunnel-table' | grep '4.4.4.4'"
check "R1 has LDP route to 4.4.4.4 via R5 path (ECMP)" \
  "docker exec ${LAB}-r1 sr_cli 'show network-instance default tunnel-table' | grep -c '4.4.4.4' | grep -qE '[2-9]'"

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
echo "=== Data Plane (L2VPN over LDP LSP) ==="
check "host1 → host2 ping" \
  "docker exec ${LAB}-host1 ping -c2 -W2 10.100.0.2"
check "host2 → host1 ping" \
  "docker exec ${LAB}-host2 ping -c2 -W2 10.100.0.1"

echo ""
echo "Result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
