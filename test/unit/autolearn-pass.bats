#!/usr/bin/env bats
load '../lib/harness.bash'
SCRIPT="$HARNESS_DIR/../openwrt/amnezia-autolearn.sh"
setup() {
  export AMNEZIA_LIB="$HARNESS_DIR/../openwrt/lib"
  export AL_DIR="$BATS_TEST_TMPDIR/amnezia"; mkdir -p "$AL_DIR/force.d" "$AL_DIR/autolearn"
  export AL_STATE="$BATS_TEST_TMPDIR/failover.json"
  export AL_QUERYLOG="$BATS_TEST_TMPDIR/q.log"; : > "$AL_QUERYLOG"
  export AMNEZIA_FORCE_LOAD="amnezia-force-load"   # stub on PATH
  # Healthy, fresh state by default.
  printf '{"all_down":false}\n' > "$AL_STATE"
  export UCI_GET_amnezia_config_routing_mode="direct-default"
  export UCI_GET_amnezia_config_autolearn_enabled="1"
}

@test "gate: tunnel-default mode -> no-op (no probe, no force-load)" {
  export UCI_GET_amnezia_config_routing_mode="tunnel-default"
  export NSLOOKUP_ADDR="93.184.216.34"
  export ZP_VERDICT_DEFAULT="direct_geoblocked"
  printf 'query[A] gated.com from 192.168.1.2\nquery[A] gated.com from 192.168.1.3\n' > "$AL_QUERYLOG"
  run sh "$SCRIPT"; [ "$status" -eq 0 ]
  # Robust negative: must NOT have called zapret-probe
  run grep -q 'zapret-probe' "$STUB_LOG"; [ "$status" -ne 0 ]
}
@test "gate: disabled -> no-op" {
  export UCI_GET_amnezia_config_autolearn_enabled="0"
  export NSLOOKUP_ADDR="93.184.216.34"
  export ZP_VERDICT_DEFAULT="direct_geoblocked"
  printf 'query[A] gated.com from 192.168.1.2\nquery[A] gated.com from 192.168.1.3\n' > "$AL_QUERYLOG"
  run sh "$SCRIPT"; [ "$status" -eq 0 ]
  run grep -q 'zapret-probe' "$STUB_LOG"; [ "$status" -ne 0 ]
}
@test "gate: all_down true -> no add" {
  printf '{"all_down":true}\n' > "$AL_STATE"
  export NSLOOKUP_ADDR="93.184.216.34"
  export ZP_VERDICT_DEFAULT="direct_geoblocked"
  printf 'query[A] gated.com from 192.168.1.2\nquery[A] gated.com from 192.168.1.3\n' > "$AL_QUERYLOG"
  run sh "$SCRIPT"; [ "$status" -eq 0 ]
  run grep -q 'zapret-probe' "$STUB_LOG"; [ "$status" -ne 0 ]
}
@test "gate: stale state file (old mtime) -> no add" {
  touch -t 197001010000 "$AL_STATE"
  export NSLOOKUP_ADDR="93.184.216.34"
  export ZP_VERDICT_DEFAULT="direct_geoblocked"
  printf 'query[A] gated.com from 192.168.1.2\nquery[A] gated.com from 192.168.1.3\n' > "$AL_QUERYLOG"
  run sh "$SCRIPT"; [ "$status" -eq 0 ]
  run grep -q 'zapret-probe' "$STUB_LOG"; [ "$status" -ne 0 ]
}

@test "confirm: geoblocked added after 2 distinct-client probes; force-load called" {
  export ZP_VERDICT_block_com="direct_geoblocked"
  export NSLOOKUP_ADDR="93.184.216.34"
  # two distinct clients resolve block.com twice
  printf 'query[A] block.com from 192.168.1.2\nquery[A] block.com from 192.168.1.3\n' > "$AL_QUERYLOG"
  run sh "$SCRIPT"; [ "$status" -eq 0 ]        # 1st probe -> count 1, not added
  # Robust negative: block.com should NOT be in auto.list yet
  run sh -c "grep -q '^block.com$' '$AL_DIR/force.d/auto.list' 2>/dev/null"; [ "$status" -ne 0 ]
  printf 'query[A] block.com from 192.168.1.2\nquery[A] block.com from 192.168.1.3\n' >> "$AL_QUERYLOG"
  run sh "$SCRIPT"; [ "$status" -eq 0 ]        # 2nd probe -> count 2 -> added
  grep -q '^block.com$' "$AL_DIR/force.d/auto.list"
  grep -q 'amnezia-force-load' "$STUB_LOG"
}
@test "eligibility: single client -> never probed" {
  export ZP_VERDICT_DEFAULT="direct_geoblocked"
  export NSLOOKUP_ADDR="93.184.216.34"
  printf 'query[A] solo.com from 192.168.1.2\n' > "$AL_QUERYLOG"
  run sh "$SCRIPT"
  # Robust negative: zapret-probe should NOT have been called for solo.com
  run grep -q 'zapret-probe solo.com' "$STUB_LOG"; [ "$status" -ne 0 ]
}
@test "safety filter: RFC1918-resolving domain is never probed" {
  export NSLOOKUP_ADDR="10.0.0.9"
  printf 'query[A] internal.example from 192.168.1.2\nquery[A] internal.example from 192.168.1.3\n' > "$AL_QUERYLOG"
  run sh "$SCRIPT"
  # Robust negative: zapret-probe should NOT be called when IP is RFC1918
  run grep -q 'zapret-probe internal.example' "$STUB_LOG"; [ "$status" -ne 0 ]
}
@test "dpi needs 3 confirmations" {
  export ZP_VERDICT_dpi_com="direct_dpi_blocked"; export NSLOOKUP_ADDR="93.184.216.34"
  # APPEND fresh bytes each pass so the offset advances and dpi.com is
  # re-harvested (a same-size rewrite would leave offset==size -> no harvest).
  for i in 1 2; do
    printf 'query[A] dpi.com from 192.168.1.2\nquery[A] dpi.com from 192.168.1.3\n' >> "$AL_QUERYLOG"
    run sh "$SCRIPT"
  done
  # Robust negative: dpi.com should NOT be in auto.list after only 2 passes
  run sh -c "grep -qx 'dpi.com' '$AL_DIR/force.d/auto.list' 2>/dev/null"; [ "$status" -ne 0 ]
  printf 'query[A] dpi.com from 192.168.1.2\nquery[A] dpi.com from 192.168.1.3\n' >> "$AL_QUERYLOG"
  run sh "$SCRIPT"
  grep -qx 'dpi.com' "$AL_DIR/force.d/auto.list"                  # 3rd -> added
}
@test "RU domains and denied domains are skipped" {
  export ZP_VERDICT_DEFAULT="direct_geoblocked"; export NSLOOKUP_ADDR="93.184.216.34"
  printf 'denied.com\n' > "$AL_DIR/autolearn/deny.list"
  printf 'query[A] site.ru from 192.168.1.2\nquery[A] site.ru from 192.168.1.3\n' > "$AL_QUERYLOG"
  printf 'query[A] denied.com from 192.168.1.2\nquery[A] denied.com from 192.168.1.3\n' >> "$AL_QUERYLOG"
  run sh "$SCRIPT"
  # Robust negatives
  run grep -q 'zapret-probe site.ru' "$STUB_LOG"; [ "$status" -ne 0 ]
  run grep -q 'zapret-probe denied.com' "$STUB_LOG"; [ "$status" -ne 0 ]
}

@test "revalidate: entry now direct_ok is dropped" {
  export NSLOOKUP_ADDR="93.184.216.34"; export ZP_VERDICT_old_com="direct_ok"
  printf 'old.com\n' > "$AL_DIR/force.d/auto.list"
  # candidate row with last_probe 15 days ago (older than revalidate_days=14)
  old=$(( $(date +%s) - 15*86400 ))
  printf 'old.com\tdirect_geoblocked\t2\t\t%s\t%s\tgeoblock\n' "$old" "$old" > "$AL_DIR/autolearn/candidates.tsv"
  run sh "$SCRIPT"; [ "$status" -eq 0 ]
  # Robust negative: old.com should be removed
  run grep -qx 'old.com' "$AL_DIR/force.d/auto.list"; [ "$status" -ne 0 ]
}
@test "size cap: at cap, a new confirmed entry evicts the LRU (never a promoted one in force-tunnel.list)" {
  export UCI_GET_amnezia_config_autolearn_max_entries="1"
  export ZP_VERDICT_new_com="direct_geoblocked"; export NSLOOKUP_ADDR="93.184.216.34"
  printf 'lru.com\n' > "$AL_DIR/force.d/auto.list"
  old=$(( $(date +%s) - 100 ))
  printf 'lru.com\tdirect_geoblocked\t2\t\t%s\t%s\tgeoblock\n' "$old" "$old" > "$AL_DIR/autolearn/candidates.tsv"
  # APPEND fresh bytes before each pass so new.com is harvested both times.
  printf 'query[A] new.com from 192.168.1.2\nquery[A] new.com from 192.168.1.3\n' >> "$AL_QUERYLOG"
  run sh "$SCRIPT"   # count 1
  printf 'query[A] new.com from 192.168.1.2\nquery[A] new.com from 192.168.1.3\n' >> "$AL_QUERYLOG"
  run sh "$SCRIPT"   # count 2 -> confirmed -> evicts the LRU (lru.com)
  grep -qx 'new.com' "$AL_DIR/force.d/auto.list"
  # Robust negative: lru.com should be evicted
  run grep -qx 'lru.com' "$AL_DIR/force.d/auto.list"; [ "$status" -ne 0 ]
}
@test "retention: stale candidate not in auto.list is pruned; an in-list one is kept" {
  export UCI_GET_amnezia_config_autolearn_candidate_retention_days="30"
  old=$(( $(date +%s) - 40*86400 ))            # older than 30 days
  printf 'gone.com\tdirect_ok\t1\t\t%s\t%s\t\n' "$old" "$old"  > "$AL_DIR/autolearn/candidates.tsv"
  printf 'kept.com\tdirect_geoblocked\t2\t\t%s\t%s\tgeoblock\n' "$old" "$old" >> "$AL_DIR/autolearn/candidates.tsv"
  printf 'kept.com\n' > "$AL_DIR/force.d/auto.list"           # kept.com is live in auto.list
  : > "$AL_QUERYLOG"                            # nothing to harvest this pass
  run sh "$SCRIPT"; [ "$status" -eq 0 ]
  # Robust negative: gone.com should be pruned
  run grep -q '^gone.com' "$AL_DIR/autolearn/candidates.tsv"; [ "$status" -ne 0 ]
  grep -q '^kept.com' "$AL_DIR/autolearn/candidates.tsv"                   # retained (in auto.list)
}

@test "log rotation: oversize log is mv'd, dnsmasq sent USR2, offset reset" {
  export AUTOLEARN_LOG_MAX_BYTES=64        # tiny so the test log is "oversize"
  export AL_KILL=al-kill                   # logging shim (kill is a builtin)
  export DNSMASQ_PID_FILE="$BATS_TEST_TMPDIR/dnsmasq.pid"; echo 4242 > "$DNSMASQ_PID_FILE"
  # fill the log past the cap with non-query noise so nothing is added
  head -c 200 /dev/zero | tr '\0' 'x' > "$AL_QUERYLOG"
  run sh "$SCRIPT"; [ "$status" -eq 0 ]
  grep -q 'kill -USR2 4242' "$STUB_LOG"            # reopen signalled (via AL_KILL)
  [ "$(cat "$AL_DIR/autolearn/.dnsmasq-log.offset")" = "0" ]   # offset reset
  # Robust negative: rotated file should be unlinked
  run sh -c "[ ! -f '${AL_QUERYLOG}.1' ]"; [ "$status" -eq 0 ]
}
@test "log rotation: skipped (no truncate) when dnsmasq pid cannot be resolved" {
  export AUTOLEARN_LOG_MAX_BYTES=64; export AL_KILL=al-kill
  export DNSMASQ_PID_FILE="$BATS_TEST_TMPDIR/none.pid"   # absent
  head -c 200 /dev/zero | tr '\0' 'x' > "$AL_QUERYLOG"
  run sh "$SCRIPT"; [ "$status" -eq 0 ]
  # Robust negative: kill -USR2 should NOT be called when no pid
  run grep -q 'kill -USR2' "$STUB_LOG"; [ "$status" -ne 0 ]
}

@test "lock: skip-on-busy exits 0 without recording; normal run after lock release does record" {
  export ZP_VERDICT_block_com="direct_geoblocked"; export NSLOOKUP_ADDR="93.184.216.34"
  # Two distinct clients: block.com would be eligible for probing.
  printf 'query[A] block.com from 192.168.1.2\nquery[A] block.com from 192.168.1.3\n' > "$AL_QUERYLOG"
  # Pre-seed candidates.tsv so one more pass would reach the threshold (count=1 already).
  _ts=$(date +%s)
  printf 'block.com\tdirect_geoblocked\t1\t192.168.1.2\t%s\t%s\tgeoblock\n' "$_ts" "$_ts" \
    > "$AL_DIR/autolearn/candidates.tsv"
  # Simulate a concurrently-running pass by holding the lock dir.
  export AL_LOCKDIR="$AL_DIR/autolearn/.pass.lock"
  mkdir "$AL_LOCKDIR"
  # --- Busy run: should exit 0 but must NOT probe or record ---
  run sh "$SCRIPT"; [ "$status" -eq 0 ]
  # Robust negative: zapret-probe must not have been called while lock was held
  run grep -q 'zapret-probe' "$STUB_LOG"; [ "$status" -ne 0 ]
  # Robust negative: block.com must not have been added to auto.list
  run sh -c "grep -qx 'block.com' '$AL_DIR/force.d/auto.list' 2>/dev/null"; [ "$status" -ne 0 ]
  # --- Release the lock and retry: same log bytes but offset is 0 (we reset below) ---
  rmdir "$AL_LOCKDIR"
  # Reset offset so the pass re-harvests the same log content.
  rm -f "$AL_DIR/autolearn/.dnsmasq-log.offset"
  : > "$STUB_LOG"   # clear call log so fresh assertions are clean
  run sh "$SCRIPT"; [ "$status" -eq 0 ]
  # This is the 2nd probe -> count reaches 2 -> block.com is added
  grep -qx 'block.com' "$AL_DIR/force.d/auto.list"
  grep -q 'amnezia-force-load' "$STUB_LOG"
}

# Regression guard for the BusyBox awk missing-file abort that wiped
# candidates.tsv each pass (count never exceeded 1, nothing was ever learned).
# BusyBox awk aborts when a named input file does not exist; BSD/macOS awk
# tolerates it — so this test MAY pass on macOS even without the fix. It
# exists to (a) document the regression and (b) prevent removal of the
# ensure-exists guard lines in amnezia-autolearn.sh.
#
# Critically: this test does NOT pre-create auto.list or candidates.tsv so
# that the ensure-exists guard is the only thing preventing awk from aborting
# and wiping candidates.tsv on pass 1.
@test "busybox-awk-regression: count accumulates across passes without pre-created auto.list" {
  export ZP_VERDICT_geo2_com="direct_geoblocked"; export NSLOOKUP_ADDR="93.184.216.34"
  # Neither auto.list nor candidates.tsv exists before pass 1 — the ensure-exists
  # guard must create them so awk never aborts on a missing file argument.
  rm -f "$AL_DIR/force.d/auto.list" "$AL_DIR/autolearn/candidates.tsv"
  # Pass 1: append fresh query lines for two distinct clients.
  printf 'query[A] geo2.com from 192.168.1.2\nquery[A] geo2.com from 192.168.1.3\n' >> "$AL_QUERYLOG"
  run sh "$SCRIPT"; [ "$status" -eq 0 ]
  # After pass 1: geo2.com must NOT be in auto.list yet (count=1, threshold=2).
  run sh -c "grep -qx 'geo2.com' '$AL_DIR/force.d/auto.list' 2>/dev/null"; [ "$status" -ne 0 ]
  # candidates.tsv must be non-empty (count persisted, not wiped by awk abort).
  [ -s "$AL_DIR/autolearn/candidates.tsv" ]
  # Pass 2: append more fresh bytes so the offset advances and geo2.com is re-harvested.
  printf 'query[A] geo2.com from 192.168.1.2\nquery[A] geo2.com from 192.168.1.3\n' >> "$AL_QUERYLOG"
  run sh "$SCRIPT"; [ "$status" -eq 0 ]
  # After pass 2: count reaches 2 -> geo2.com must be in auto.list.
  grep -qx 'geo2.com' "$AL_DIR/force.d/auto.list"
  grep -q 'amnezia-force-load' "$STUB_LOG"
}
