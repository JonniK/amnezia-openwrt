#!/bin/sh
# Tier-2 local integration test runner (optional).
#
# Runs the same bats suite as CI but locally via Docker/Colima.
# NOT run by the CI pipeline itself -- this is a developer convenience.
# Tier-2 tests guard themselves with _require_linux_nft/skip, so on macOS
# the unit suite still runs; only the real-kernel tests are skipped.
#
# Usage:
#   sh dev/test-integration.sh          # auto-detect Docker/Colima
#   sh dev/test-integration.sh --force  # skip docker, run bats directly (on Linux)

set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

if [ "${1:-}" = "--force" ]; then
  echo "Running bats directly (assumes Linux with nft/ip/conntrack on PATH)..."
  exec bats "$ROOT/test/integration" "$ROOT/test/unit"
fi

if command -v docker >/dev/null 2>&1; then
  echo "Running Tier-2 tests inside Ubuntu Docker container..."
  exec docker run --rm --privileged \
    -v "$ROOT:/work" -w /work \
    ubuntu:24.04 \
    sh -c 'apt-get update -qq && \
           apt-get install -y --no-install-recommends bats nftables iproute2 conntrack && \
           bats test/integration test/unit'
fi

echo "Docker not found. Install colima or docker to run Tier-2 tests locally."
echo "Tier-2 tests run automatically in GitHub Actions (CI) on ubuntu-latest."
echo "To run only unit tests (hardware-free) locally: bats test/unit"
exit 0
