#!/usr/bin/env bash
# destroy.sh — tear down the lab
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"
containerlab destroy -t topology.yml --cleanup
echo "Lab destroyed."
