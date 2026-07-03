#!/usr/bin/env bats
# Behavioral tests for openwrt/amnezia-blackbox.sh
# Covers: active_pool extraction from single-line JSON, rx/tx logging, fallback.
load '../lib/harness.bash'
SCRIPT="$HARNESS_DIR/../openwrt/amnezia-blackbox.sh"

setup() {
  # Local awg stub: logs its args, prints a transfer line with rx=111 tx=222.
  # Format: "<pubkey> <rx_bytes> <tx_bytes>" so awk '{print "rx="$2" tx="$3}' yields "rx=111 tx=222".
  _stub_dir="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$_stub_dir"
  cat > "$_stub_dir/awg" <<'AWGSTUB'
#!/bin/sh
echo "awg $*" >> "${STUB_LOG:-/dev/null}"
echo "PUBKEY 111 222"
exit 0
AWGSTUB
  chmod +x "$_stub_dir/awg"
  export PATH="$_stub_dir:$PATH"

  # Redirect log to tmpdir (avoids touching /etc).
  export AMNEZIA_BLACKBOX_LOG="$BATS_TEST_TMPDIR/blackbox.log"

  # Default state JSON path (tests override per-case).
  export AMNEZIA_STATE_JSON="$BATS_TEST_TMPDIR/amnezia-failover.json"

  # Stub /proc files so the script runs on macOS / CI without real /proc.
  printf '999.00 888.00\n' > "$BATS_TEST_TMPDIR/uptime"
  printf '0.42 0.38 0.30 1/100 1234\n' > "$BATS_TEST_TMPDIR/loadavg"

  # uci stub: return 0 for dnsleak_failopen (default from harness uci stub handles the rest).
  export UCI_GET_amnezia_config_dnsleak_failopen=0

  : > "$STUB_LOG"
}

# ---------------------------------------------------------------------------
# Test 1 (regression): awg is called with the REAL active_pool from fixture JSON,
# not the buggy awk-extracted value ("failover").
# ---------------------------------------------------------------------------
@test "extracts active_pool from single-line JSON and calls awg show <pool> transfer" {
  # Single-line JSON as the daemon writes it: active_pool=awg2.
  printf '{"mode":"failover","routing_mode":"direct-default","active_pool":"awg2","force_pool":"","sources":{}}\n' \
    > "$AMNEZIA_STATE_JSON"

  run sh "$SCRIPT"
  [ "$status" -eq 0 ]

  # awg must be invoked with the correct pool name, not "failover" (the old bug).
  grep -q 'awg show awg2 transfer' "$STUB_LOG" \
    || { echo "FAIL: awg was not called with 'show awg2 transfer'; stub_log:"; cat "$STUB_LOG"; false; }
}

# ---------------------------------------------------------------------------
# Test 2: the log line contains the rx/tx values from the awg stub output.
# ---------------------------------------------------------------------------
@test "log line contains rx=111 tx=222 from awg transfer output" {
  printf '{"mode":"failover","routing_mode":"tunnel-default","active_pool":"awg2","force_pool":""}\n' \
    > "$AMNEZIA_STATE_JSON"

  run sh "$SCRIPT"
  [ "$status" -eq 0 ]

  grep -q 'rx=111 tx=222' "$AMNEZIA_BLACKBOX_LOG" \
    || { echo "FAIL: log does not contain rx/tx sample; log:"; cat "$AMNEZIA_BLACKBOX_LOG"; false; }
}

# ---------------------------------------------------------------------------
# Test 3: absent state JSON -> falls back to awg3.
# ---------------------------------------------------------------------------
@test "absent state JSON falls back to awg3 for transfer query" {
  # Ensure the state JSON does not exist.
  rm -f "$AMNEZIA_STATE_JSON"

  run sh "$SCRIPT"
  [ "$status" -eq 0 ]

  grep -q 'awg show awg3 transfer' "$STUB_LOG" \
    || { echo "FAIL: fallback to awg3 not observed; stub_log:"; cat "$STUB_LOG"; false; }
}
