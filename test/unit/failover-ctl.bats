#!/usr/bin/env bats
# Phase 2: failover-ctl new verbs — make-default, force-pin, force-unpin, restart, master on|off.
load '../lib/harness.bash'
CTL="$HARNESS_DIR/../openwrt/amnezia-failover-ctl.sh"

setup() {
  export AMNEZIA_LIB="$HARNESS_DIR/../openwrt/lib"
  # Provide a writable ST_DIR for trigger-touch tests.
  export ST_DIR="$BATS_TEST_TMPDIR/amnezia-fo"
  mkdir -p "$ST_DIR"
  # Three tunnels exist and are enabled (awg4/awg5 absent → uci returns exit 1).
  export UCI_GET_amnezia_awg1=tunnel
  export UCI_GET_amnezia_awg1_enabled=1
  export UCI_GET_amnezia_awg2=tunnel
  export UCI_GET_amnezia_awg2_enabled=1
  export UCI_GET_amnezia_awg3=tunnel
  export UCI_GET_amnezia_awg3_enabled=1
  # Override init-script and ctl paths so tests never hit /etc/init.d or absent binaries.
  # amnezia-failover-init, amnezia-dns-ctl, amnezia-autolearn-ctl are all stubs in PATH.
  export AMNEZIA_FAILOVER_INIT=amnezia-failover-init
  export AMNEZIA_DNS_CTL=amnezia-dns-ctl
  export AMNEZIA_AL_CTL=amnezia-autolearn-ctl
  # Skip real WAN/DNS probe in tests.
  export AMNEZIA_VERIFY_CMD=true
}

# ---------------------------------------------------------------------------
# make-default
# ---------------------------------------------------------------------------

@test "make-default sets chosen metric=1, renumbers other enabled tunnels ascending" {
  run sh "$CTL" make-default awg3
  [ "$status" -eq 0 ]
  grep -q 'set amnezia.awg3.metric=1' "$STUB_LOG"
  grep -q 'set amnezia.awg1.metric=2' "$STUB_LOG"
  grep -q 'set amnezia.awg2.metric=3' "$STUB_LOG"
  grep -q 'commit amnezia' "$STUB_LOG"
}

@test "make-default rejects unknown tunnel" {
  run sh "$CTL" make-default awg9
  [ "$status" -ne 0 ]
}

@test "make-default rejects disabled tunnel" {
  UCI_GET_amnezia_awg3_enabled=0 run sh "$CTL" make-default awg3
  [ "$status" -ne 0 ]
}

@test "make-default skips disabled tunnels in renumber sequence" {
  # awg2 disabled → should NOT appear in renumbering
  UCI_GET_amnezia_awg2_enabled=0 run sh "$CTL" make-default awg1
  [ "$status" -eq 0 ]
  grep -q 'set amnezia.awg1.metric=1' "$STUB_LOG"
  grep -q 'set amnezia.awg3.metric=2' "$STUB_LOG"
  # awg2 must not be renumbered
  ! grep -q 'set amnezia.awg2.metric=' "$STUB_LOG"
}

# ---------------------------------------------------------------------------
# force-pin / force-unpin
# ---------------------------------------------------------------------------

@test "force-pin sets globals.force_pool and touches trigger (no daemon restart)" {
  run sh "$CTL" force-pin awg2
  [ "$status" -eq 0 ]
  grep -q 'set amnezia.globals.force_pool=awg2' "$STUB_LOG"
  grep -q 'commit amnezia' "$STUB_LOG"
  [ -f "$ST_DIR/immediate" ]
  # Must NOT trigger a monitor restart
  ! grep -q 'amnezia-failover restart' "$STUB_LOG"
}

@test "force-pin rejects unknown tunnel" {
  run sh "$CTL" force-pin awg9
  [ "$status" -ne 0 ]
}

@test "force-unpin deletes force_pool and touches trigger" {
  run sh "$CTL" force-unpin
  [ "$status" -eq 0 ]
  grep -q 'delete amnezia.globals.force_pool' "$STUB_LOG"
  grep -q 'commit amnezia' "$STUB_LOG"
  [ -f "$ST_DIR/immediate" ]
}

# ---------------------------------------------------------------------------
# restart
# ---------------------------------------------------------------------------

@test "restart bounces only the named iface" {
  run sh "$CTL" restart awg2
  [ "$status" -eq 0 ]
  grep -q 'ifdown awg2' "$STUB_LOG"
  grep -q 'ifup awg2' "$STUB_LOG"
  ! grep -q 'ifdown awg1' "$STUB_LOG"
  ! grep -q 'ifup awg1' "$STUB_LOG"
}

@test "restart rejects unknown tunnel" {
  run sh "$CTL" restart awg9
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# master off
# ---------------------------------------------------------------------------

@test "master off: sets master_enabled=0, snapshots dot/autolearn, stops daemon, flushes tables" {
  UCI_GET_amnezia_config_dot_enabled=1 \
  UCI_GET_amnezia_config_autolearn_enabled=0 \
  run sh "$CTL" master off
  [ "$status" -eq 0 ]
  grep -q 'set amnezia.config.master_enabled=0' "$STUB_LOG"
  grep -q 'set amnezia.config.dot_master_saved=1' "$STUB_LOG"
  grep -q 'set amnezia.config.autolearn_master_saved=0' "$STUB_LOG"
  grep -q 'amnezia-failover stop' "$STUB_LOG"
  grep -q 'commit amnezia' "$STUB_LOG"
}

@test "master off: disables DoT when dot_enabled was 1" {
  UCI_GET_amnezia_config_dot_enabled=1 \
  run sh "$CTL" master off
  [ "$status" -eq 0 ]
  grep -q 'amnezia-dns-ctl disable' "$STUB_LOG"
}

@test "master off: does NOT disable DoT when dot_enabled is 0" {
  UCI_GET_amnezia_config_dot_enabled=0 \
  run sh "$CTL" master off
  [ "$status" -eq 0 ]
  ! grep -q 'amnezia-dns-ctl disable' "$STUB_LOG"
}

@test "master off: disables autolearn when autolearn_enabled was 1" {
  UCI_GET_amnezia_config_dot_enabled=0 \
  UCI_GET_amnezia_config_autolearn_enabled=1 \
  run sh "$CTL" master off
  [ "$status" -eq 0 ]
  grep -q 'amnezia-autolearn-ctl set-enabled 0' "$STUB_LOG"
}

@test "master off: flushes routing tables 100 and 101 (fail-open)" {
  run sh "$CTL" master off
  [ "$status" -eq 0 ]
  grep -q 'route flush table 100' "$STUB_LOG"
  grep -q 'route flush table 101' "$STUB_LOG"
  # Must never install a blackhole
  ! grep -q 'blackhole' "$STUB_LOG"
}

# ---------------------------------------------------------------------------
# master on
# ---------------------------------------------------------------------------

@test "master on: sets master_enabled=1, starts daemon, restores and re-enables saved DoT" {
  UCI_GET_amnezia_config_dot_master_saved=1 \
  UCI_GET_amnezia_config_autolearn_master_saved=0 \
  run sh "$CTL" master on
  [ "$status" -eq 0 ]
  grep -q 'set amnezia.config.master_enabled=1' "$STUB_LOG"
  grep -q 'amnezia-failover start' "$STUB_LOG"
  grep -q 'amnezia-dns-ctl enable' "$STUB_LOG"
  grep -q 'commit amnezia' "$STUB_LOG"
}

@test "master on: does NOT re-enable DoT when snapshot was 0" {
  UCI_GET_amnezia_config_dot_master_saved=0 \
  UCI_GET_amnezia_config_autolearn_master_saved=0 \
  run sh "$CTL" master on
  [ "$status" -eq 0 ]
  ! grep -q 'amnezia-dns-ctl enable' "$STUB_LOG"
}

@test "master on: re-enables autolearn when snapshot was 1" {
  UCI_GET_amnezia_config_dot_master_saved=0 \
  UCI_GET_amnezia_config_autolearn_master_saved=1 \
  run sh "$CTL" master on
  [ "$status" -eq 0 ]
  grep -q 'amnezia-autolearn-ctl set-enabled 1' "$STUB_LOG"
}

@test "master on: deletes snapshot keys after restore" {
  UCI_GET_amnezia_config_dot_master_saved=1 \
  UCI_GET_amnezia_config_autolearn_master_saved=0 \
  run sh "$CTL" master on
  [ "$status" -eq 0 ]
  grep -q 'delete amnezia.config.dot_master_saved' "$STUB_LOG"
  grep -q 'delete amnezia.config.autolearn_master_saved' "$STUB_LOG"
}

@test "master off idempotent: double-off preserves original dot_master_saved=1" {
  # First call: master_enabled=1, dot_enabled=1 → saves dot_master_saved=1
  UCI_GET_amnezia_config_master_enabled=1 \
  UCI_GET_amnezia_config_dot_enabled=1 \
  UCI_GET_amnezia_config_autolearn_enabled=0 \
  run sh "$CTL" master off
  [ "$status" -eq 0 ]
  grep -q 'set amnezia.config.dot_master_saved=1' "$STUB_LOG"

  # Second call: master_enabled=0 (already off) — must NOT overwrite dot_master_saved
  : > "$STUB_LOG"
  UCI_GET_amnezia_config_master_enabled=0 \
  UCI_GET_amnezia_config_dot_enabled=0 \
  UCI_GET_amnezia_config_autolearn_enabled=0 \
  run sh "$CTL" master off
  [ "$status" -eq 0 ]
  # Must NOT write dot_master_saved=0 (would corrupt the saved=1 from first call)
  ! grep -q 'set amnezia.config.dot_master_saved=' "$STUB_LOG"
}

@test "master off then on: dot_master_saved=1 survives; master on re-enables DoT" {
  # Simulate state after first master off (saved=1, master_enabled now 0)
  UCI_GET_amnezia_config_dot_master_saved=1 \
  UCI_GET_amnezia_config_autolearn_master_saved=0 \
  run sh "$CTL" master on
  [ "$status" -eq 0 ]
  grep -q 'amnezia-dns-ctl enable' "$STUB_LOG"
}

@test "master rejects bad subcommand" {
  run sh "$CTL" master sideways
  [ "$status" -ne 0 ]
}

@test "master with no subcommand rejects" {
  run sh "$CTL" master
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# FIX-3: master off flushes pref-30900 even when amnezia-dns-ctl disable fails
# ---------------------------------------------------------------------------

@test "FIX-3: master off flushes pref-30900 (ip rule del pref 30900) even when dns-ctl fails" {
  # Arrange: dns-ctl stub will exit nonzero for 'disable'.
  export AMNEZIA_DNS_CTL_FAIL_DISABLE=1
  UCI_GET_amnezia_config_dot_enabled=1 \
  UCI_GET_amnezia_config_autolearn_enabled=0 \
  run sh "$CTL" master off
  [ "$status" -eq 0 ]
  # dns_iprule_flush calls: ip rule del pref 30900 (RULE_PREF_DOT=30900)
  grep -q 'rule del pref 30900' "$STUB_LOG"
}

@test "FIX-3: master off flushes pref-30900 when dot was disabled (no dns-ctl call)" {
  UCI_GET_amnezia_config_dot_enabled=0 \
  run sh "$CTL" master off
  [ "$status" -eq 0 ]
  # Flush must happen regardless of dot_enabled state
  grep -q 'rule del pref 30900' "$STUB_LOG"
}

# ---------------------------------------------------------------------------
# FIX-4: master off removes STATE_FILE
# ---------------------------------------------------------------------------

@test "FIX-4: master off removes STATE_FILE so LuCI shows no stale tunnel state" {
  # Seed a fake state file
  export STATE_FILE="$BATS_TEST_TMPDIR/failover.json"
  echo '{"tunnels":[]}' > "$STATE_FILE"
  run sh "$CTL" master off
  [ "$status" -eq 0 ]
  [ ! -f "$STATE_FILE" ]
}
