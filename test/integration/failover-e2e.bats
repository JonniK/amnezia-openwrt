#!/usr/bin/env bats
load '../lib/harness.bash'

# Tier-2 real-kernel e2e: exercises the actual daemon code paths, not a
# hand-rolled route swap.  The daemon is sourced with --source-only inside a
# private netns so routing calls hit real kernel tables while UCI/awg/etc. are
# provided by minimal stubs that live next to the daemon fixtures.
#
# Exit-IP cache test (second @test) does not need a netns; it sources the
# daemon directly in the test process.

_NS=amzfo-e2e

setup() {
  _require_linux_nft || skip "needs Linux nft/ip"
  # Pre-clean any stale netns left by a crashed prior run.
  sudo ip netns del "$_NS" 2>/dev/null || true
}

teardown() {
  sudo ip netns del "$_NS" 2>/dev/null || true
}

@test "daemon reconcile moves pool route to backup when primary goes down" {
  repo="$(cd "$HARNESS_DIR/.." && pwd)"
  stub_d="$BATS_TEST_TMPDIR/e2e-stubs"
  st_d="$BATS_TEST_TMPDIR/amnezia-fo"
  mkdir -p "$stub_d" "$st_d"

  # Minimal stubs for commands called by the daemon inside the netns.
  # Real 'ip' must NOT be stubbed so routing calls hit the real kernel tables.

  # uci stub: force_pool empty, routing_mode tunnel-default, misc keys.
  cat > "$stub_d/uci" <<'UCISTUB'
#!/bin/sh
_v="$1"; [ "$_v" = "-q" ] && shift
case "$1 $2" in
  "get amnezia.globals.force_pool")  echo ""; exit 0 ;;
  "get amnezia.config.routing_mode") echo "tunnel-default"; exit 0 ;;
  "get amnezia.config.master_enabled") echo "1"; exit 0 ;;
esac
exit 1
UCISTUB
  chmod +x "$stub_d/uci"

  # conntrack stub: reconcile calls conntrack -D on pool change; no-op is fine.
  printf '#!/bin/sh\nexit 0\n' > "$stub_d/conntrack"
  chmod +x "$stub_d/conntrack"

  # logger stub: amz_log uses logger; suppress output.
  printf '#!/bin/sh\nexit 0\n' > "$stub_d/logger"
  chmod +x "$stub_d/logger"

  # awg stub: handshake_fresh needs awg show output; return stale so health fails.
  # (We bypass health by setting HEALTHY directly before calling reconcile.)
  printf '#!/bin/sh\nexit 0\n' > "$stub_d/awg"
  chmod +x "$stub_d/awg"

  sudo ip netns add "$_NS"

  # Write the inner test script that runs inside the netns.
  inner="$BATS_TEST_TMPDIR/e2e-inner.sh"
  cat > "$inner" <<SCRIPT
#!/bin/sh
set -e

# Set up dummy tunnel interfaces.
ip link add awg1 type dummy 2>/dev/null || true
ip link add awg2 type dummy 2>/dev/null || true
ip link set awg1 up
ip link set awg2 up

# Stubs first on PATH, then real system binaries.  Real ip must come from the
# system (not a stub) so route-table mutations hit the actual kernel.
export PATH="${stub_d}:/sbin:/usr/sbin:/usr/bin:/bin"

export AMNEZIA_LIB="${repo}/openwrt/lib"
export ST_DIR="${st_d}"
export STUB_LOG="${st_d}/stub.log"
: > "\$STUB_LOG"

# Source the real daemon (defines all functions; does not start run_loop).
. "${repo}/openwrt/amnezia-failover" --source-only

# Scenario: awg1 (metric 1, lowest = highest priority) is DOWN; awg2 is healthy.
# The daemon's reconcile() must install default dev awg2 on table 101.
MEMBERS="awg1:1:1 awg2:2:1"
HEALTHY="awg2"
STICKY_TARGET="awg1"
FORCE_POOL=""
MODE=failover
NEXTHOP_OK=0
POOL_MARK=0x0b0000
MARK_MASK=0x0ff0000
_PREV_POOL=""
_PREV_STKY=""

reconcile

# Verify: table 101 default route now points to awg2, not awg1.
ip route show table 101 | grep -q "default dev awg2"
SCRIPT
  chmod +x "$inner"

  sudo ip netns exec "$_NS" sh "$inner"
}

@test "daemon clears exit-IP cache on tunnel up transition (_on_tunnel_up)" {
  # Sources the daemon directly (no netns needed) and calls the extracted
  # _on_tunnel_up() function so the test FAILS if the daemon's rm line is removed.
  export AMNEZIA_LIB="$HARNESS_DIR/../openwrt/lib"
  export ST_DIR="$BATS_TEST_TMPDIR/amnezia-fo-cache"
  mkdir -p "$ST_DIR"

  . "$HARNESS_DIR/../openwrt/amnezia-failover" --source-only

  # Seed stale exit-IP cache for awg1.
  printf '1.2.3.4' > "$ST_DIR/exitip.awg1.ip"
  printf '0'       > "$ST_DIR/exitip.awg1.ts"

  # Call the daemon function that performs the cache removal on up-transition.
  _on_tunnel_up awg1

  [ ! -f "$ST_DIR/exitip.awg1.ip" ]
  [ ! -f "$ST_DIR/exitip.awg1.ts" ]
}
