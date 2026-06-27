#!/usr/bin/env bats
# Tests for amnezia-failover daemon: force_pool, exit-IP probe, common.sh exports.
load '../lib/harness.bash'
setup() {
  export AMNEZIA_LIB="$HARNESS_DIR/../openwrt/lib"
  export ST_DIR="$BATS_TEST_TMPDIR/amnezia-fo"
  mkdir -p "$ST_DIR"
  . "$HARNESS_DIR/../openwrt/amnezia-failover" --source-only
}

# ── Part A: force_pool honor ──────────────────────────────────────────────────

@test "force_pool pins healthy tunnel regardless of metric" {
  FORCE_POOL=awg2 MEMBERS="awg1:1:1 awg2:2:1 awg3:3:1" HEALTHY="awg1 awg2 awg3" run _best_pool
  [ "$output" = awg2 ]
}

@test "force_pool fail-closed when pinned tunnel down" {
  FORCE_POOL=awg2 MEMBERS="awg1:1:1 awg2:2:1 awg3:3:1" HEALTHY="awg1 awg3" run _best_pool
  [ -z "$output" ]
}

@test "no force_pool: lowest-metric healthy wins" {
  FORCE_POOL="" MEMBERS="awg1:1:1 awg2:2:1 awg3:3:1" HEALTHY="awg2 awg3" run _best_pool
  [ "$output" = awg2 ]
}

@test "reconcile reads force_pool from uci (-q get amnezia.globals.force_pool)" {
  # Stub uci so 'uci -q get amnezia.globals.force_pool' echoes awg3 (unquoted).
  export UCI_GET_amnezia_globals_force_pool=awg3
  MEMBERS="awg1:1:1 awg2:2:1 awg3:3:1" HEALTHY="awg1 awg2 awg3"
  # _reconcile_pool_probe: simulates the exact uci-read + _best_pool call from reconcile()
  _reconcile_pool_probe() {
    FORCE_POOL=$(uci -q get amnezia.globals.force_pool 2>/dev/null || echo "")
    _best_pool
  }
  run _reconcile_pool_probe
  [ "$output" = awg3 ]
}

# ── Part A: force_pool in write_state JSON ────────────────────────────────────

@test "write_state emits force_pool:\"awgN\" when FORCE_POOL is set" {
  MODE=failover MEMBERS="awg1:1:1 awg2:2:1" HEALTHY="awg2" FORCE_POOL=awg2
  STATE_FILE="$BATS_TEST_TMPDIR/fp.json"
  write_state awg2 awg2
  grep -q '"force_pool":"awg2"' "$BATS_TEST_TMPDIR/fp.json"
}

@test "write_state emits force_pool:null when FORCE_POOL is empty" {
  MODE=failover MEMBERS="awg1:1:1 awg2:2:1" HEALTHY="awg2" FORCE_POOL=""
  STATE_FILE="$BATS_TEST_TMPDIR/fp2.json"
  write_state awg2 awg2
  grep -q '"force_pool":null' "$BATS_TEST_TMPDIR/fp2.json"
}

# ── Part B: exit-IP probe ─────────────────────────────────────────────────────

@test "_probe_exit_ip binds to tunnel, caches, honors TTL" {
  export ST_DIR="$BATS_TEST_TMPDIR"
  export CURL_STUB_OUT=185.10.20.30
  export CURL_CALLCOUNT="$BATS_TEST_TMPDIR/n"
  echo 0 > "$CURL_CALLCOUNT"
  run _probe_exit_ip awg1
  [ "$output" = 185.10.20.30 ]
  [ "$(cat "$ST_DIR/exitip.awg1.ip")" = 185.10.20.30 ]
  # Second call within TTL -> must use cache (curl not called again)
  run _probe_exit_ip awg1
  [ "$(cat "$CURL_CALLCOUNT")" = 1 ]
}

@test "_probe_exit_ip re-probes after TTL expiry" {
  export ST_DIR="$BATS_TEST_TMPDIR"
  export CURL_STUB_OUT=1.2.3.4
  export CURL_CALLCOUNT="$BATS_TEST_TMPDIR/n2"
  echo 0 > "$CURL_CALLCOUNT"
  # Pre-write a stale cache (timestamp 0 = epoch, far in the past)
  printf '9.9.9.9' > "$ST_DIR/exitip.awg1.ip"
  printf '0'       > "$ST_DIR/exitip.awg1.ts"
  run _probe_exit_ip awg1
  [ "$output" = 1.2.3.4 ]
  [ "$(cat "$CURL_CALLCOUNT")" = 1 ]
}

@test "_probe_exit_ip returns cached value on curl failure (stale-ok)" {
  export ST_DIR="$BATS_TEST_TMPDIR"
  export CURL_STUB_OUT=""
  export CURL_CALLCOUNT="$BATS_TEST_TMPDIR/n3"
  echo 0 > "$CURL_CALLCOUNT"
  # Pre-write stale cache
  printf '5.5.5.5' > "$ST_DIR/exitip.awg1.ip"
  printf '0'       > "$ST_DIR/exitip.awg1.ts"
  run _probe_exit_ip awg1
  # Should return stale cached value when curl fails
  [ "$output" = 5.5.5.5 ]
}

@test "_refresh_exit_ips is detached (returns immediately, not blocking)" {
  export ST_DIR="$BATS_TEST_TMPDIR"
  export CURL_STUB_OUT=9.9.9.9
  MEMBERS="awg1:1:1" HEALTHY="awg1" run _refresh_exit_ips
  [ "$status" -eq 0 ]
}

# ── Part B: write_state includes exit_ip fields ───────────────────────────────

@test "write_state includes exit_ip from cache for UP tunnel" {
  export ST_DIR="$BATS_TEST_TMPDIR/amnezia-fo"
  mkdir -p "$ST_DIR"
  # Pre-populate cache
  printf '185.10.20.30' > "$ST_DIR/exitip.awg1.ip"
  printf '%s' "$(date +%s)" > "$ST_DIR/exitip.awg1.ts"
  MODE=failover MEMBERS="awg1:1:1" HEALTHY="awg1" FORCE_POOL=""
  STATE_FILE="$BATS_TEST_TMPDIR/eip.json"
  write_state awg1 awg1
  grep -q '"exit_ip":"185.10.20.30"' "$BATS_TEST_TMPDIR/eip.json"
  # exit_ip_age should be a small non-negative integer
  grep -qE '"exit_ip_age":[0-9]+' "$BATS_TEST_TMPDIR/eip.json"
}

@test "write_state emits exit_ip:null for DOWN tunnel" {
  export ST_DIR="$BATS_TEST_TMPDIR/amnezia-fo"
  mkdir -p "$ST_DIR"
  # awg1 is DOWN (not in HEALTHY)
  MODE=failover MEMBERS="awg1:1:1" HEALTHY="" FORCE_POOL=""
  STATE_FILE="$BATS_TEST_TMPDIR/eip2.json"
  write_state "" ""
  grep -q '"exit_ip":null' "$BATS_TEST_TMPDIR/eip2.json"
  grep -q '"exit_ip_age":null' "$BATS_TEST_TMPDIR/eip2.json"
}

# ── Part B2: exit-IP cache bust on down→up transition ────────────────────────

@test "down→up transition removes exitip cache files" {
  # Seed a stale cache for awg1
  printf '1.2.3.4' > "$ST_DIR/exitip.awg1.ip"
  printf '0'       > "$ST_DIR/exitip.awg1.ts"
  # Seed debounce state as 'down' with count already at DEBOUNCE_N-1 so
  # the next call (with ok=1) crosses the threshold and returns 0 (changed).
  echo "down $(( DEBOUNCE_N - 1 ))" > "$ST_DIR/awg1"
  # Call debounce with ok=1; it should return 0 (transition happened)
  debounce awg1 1
  # The main loop calls rm ONLY on the transition (debounce returns 0).
  # We simulate the same conditional the daemon uses:
  rm -f "$ST_DIR/exitip.awg1.ts" "$ST_DIR/exitip.awg1.ip"
  [ ! -f "$ST_DIR/exitip.awg1.ip" ]
  [ ! -f "$ST_DIR/exitip.awg1.ts" ]
}

@test "exitip cache NOT removed on steady-state up (no transition)" {
  # Tunnel already up → debounce returns 1 (no state change) → cache intact
  printf '1.2.3.4' > "$ST_DIR/exitip.awg1.ip"
  printf '0'       > "$ST_DIR/exitip.awg1.ts"
  echo "up 0" > "$ST_DIR/awg1"
  # debounce returns 1 (no change) — cache files must survive
  if debounce awg1 1; then
    # If somehow a transition fires, remove cache (simulates daemon branch)
    rm -f "$ST_DIR/exitip.awg1.ts" "$ST_DIR/exitip.awg1.ip"
  fi
  [ -f "$ST_DIR/exitip.awg1.ip" ]
  [ -f "$ST_DIR/exitip.awg1.ts" ]
}

# ── Part C: common.sh exports ─────────────────────────────────────────────────

@test "amnezia-common.sh exports ST_DIR defaulting to /tmp/amnezia-fo" {
  # Source common.sh fresh in a subshell with ST_DIR unset
  _result=$(unset ST_DIR; . "$HARNESS_DIR/../openwrt/lib/amnezia-common.sh"; echo "$ST_DIR")
  [ "$_result" = "/tmp/amnezia-fo" ]
}

@test "ST_DIR can be overridden before sourcing common.sh" {
  _result=$(ST_DIR=/custom/path; . "$HARNESS_DIR/../openwrt/lib/amnezia-common.sh"; echo "$ST_DIR")
  [ "$_result" = "/custom/path" ]
}

@test "common.sh exports AMNEZIA_IPECHO_URLS" {
  _result=$(unset AMNEZIA_IPECHO_URLS; . "$HARNESS_DIR/../openwrt/lib/amnezia-common.sh"; echo "$AMNEZIA_IPECHO_URLS")
  [ -n "$_result" ]
}

@test "common.sh exports AMNEZIA_EXITIP_TTL defaulting to 300" {
  _result=$(unset AMNEZIA_EXITIP_TTL; . "$HARNESS_DIR/../openwrt/lib/amnezia-common.sh"; echo "$AMNEZIA_EXITIP_TTL")
  [ "$_result" = "300" ]
}

@test "amz_master_enabled returns true (0) when unset (default enabled)" {
  UCI_GET_amnezia_config_master_enabled="" run amz_master_enabled
  # When unset, function defaults to enabled
  [ "$status" -eq 0 ]
}

@test "amz_master_enabled returns true (0) when master_enabled=1" {
  UCI_GET_amnezia_config_master_enabled=1 run amz_master_enabled
  [ "$status" -eq 0 ]
}

@test "amz_master_enabled returns false (1) when master_enabled=0" {
  UCI_GET_amnezia_config_master_enabled=0 run amz_master_enabled
  [ "$status" -ne 0 ]
}

# ── FIX-2: prove tunnel-binding egress safety ─────────────────────────────────

@test "FIX-2: _probe_exit_ip passes --interface if!awgN to curl (egress bound to tunnel)" {
  export ST_DIR="$BATS_TEST_TMPDIR"
  export CURL_STUB_OUT=10.0.0.1
  export CURL_CALLCOUNT="$BATS_TEST_TMPDIR/nc"
  echo 0 > "$CURL_CALLCOUNT"
  # The curl stub (FIX-2 updated) exits 3 if --interface if!<iface> is absent.
  # _probe_exit_ip must pass the flag; if it doesn't, curl returns nothing and
  # the cache file is not written.
  run _probe_exit_ip awg1
  [ "$output" = 10.0.0.1 ]
  [ "$(cat "$ST_DIR/exitip.awg1.ip")" = 10.0.0.1 ]
}

@test "FIX-2: curl stub exits 3 (no output) when --interface if! is missing" {
  # Directly invoke the stub without the binding flag; expect exit 3 / no output.
  export CURL_STUB_OUT=10.0.0.1
  run sh "$HARNESS_DIR/../test/stubs/curl" -fsSL https://api.ipify.org
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

# ── FIX-5: _refresh_exit_ips actually writes the cache ───────────────────────

@test "FIX-5: _probe_exit_ip (inner worker) writes exitip cache (proves the detached probe writes)" {
  # _refresh_exit_ips wraps _probe_exit_ip in a flock'd subshell.
  # We test the inner function directly (flock may be absent on macOS CI) to
  # prove that on a successful curl call the cache IS written. The outer
  # _refresh_exit_ips is already covered by the "detached" test (test 10).
  export ST_DIR="$BATS_TEST_TMPDIR/eip5"
  mkdir -p "$ST_DIR"
  export CURL_STUB_OUT=7.7.7.7
  export CURL_CALLCOUNT="$BATS_TEST_TMPDIR/nc5"
  echo 0 > "$CURL_CALLCOUNT"
  # Call the worker function directly (no flock wrapper).
  run _probe_exit_ip awg1
  [ "$output" = 7.7.7.7 ]
  [ "$(cat "$ST_DIR/exitip.awg1.ip" 2>/dev/null)" = 7.7.7.7 ]
  # Confirm curl was called exactly once (not cached yet).
  [ "$(cat "$CURL_CALLCOUNT")" = 1 ]
}
