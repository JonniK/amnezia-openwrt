#!/usr/bin/env bats
load '../lib/harness.bash'
setup() {
  export AMNEZIA_LIB="$HARNESS_DIR/../openwrt/lib"
  export ST_DIR="$BATS_TEST_TMPDIR/amnezia-fo"
  mkdir -p "$ST_DIR"
  . "$HARNESS_DIR/../openwrt/amnezia-failover" --source-only
}

@test "writes state json with required keys and per-tunnel objects" {
  MODE=failover MEMBERS="awg1:1:1 awg2:2:1" HEALTHY="awg2" STATE_FILE="$BATS_TEST_TMPDIR/s.json"
  write_state awg2 awg2
  for k in mode active_pool active_sticky all_down tunnels; do grep -q "\"$k\"" "$BATS_TEST_TMPDIR/s.json"; done
  grep -q "\"name\":\"awg1\"" "$BATS_TEST_TMPDIR/s.json"
  grep -q "\"up\":false" "$BATS_TEST_TMPDIR/s.json"   # awg1 not in HEALTHY
}

@test "write_state emits routing_mode key from UCI (C1)" {
  MODE=failover MEMBERS="awg1:1:1" HEALTHY="awg1" STATE_FILE="$BATS_TEST_TMPDIR/rm.json"
  write_state awg1 awg1
  grep -q '"routing_mode"' "$BATS_TEST_TMPDIR/rm.json"
  # Stub returns "tunnel-default" for amnezia.config.routing_mode
  grep -q '"routing_mode":"tunnel-default"' "$BATS_TEST_TMPDIR/rm.json"
}

@test "write_state emits sources object with all five source names (H1)" {
  MODE=failover MEMBERS="awg1:1:1" HEALTHY="awg1" STATE_FILE="$BATS_TEST_TMPDIR/src.json"
  write_state awg1 awg1
  grep -q '"sources"' "$BATS_TEST_TMPDIR/src.json"
  for sn in itdoginfo_inside itdoginfo_services refilter_domains refilter_ip antifilter; do
    grep -q "\"${sn}\"" "$BATS_TEST_TMPDIR/src.json"
  done
  # Stub: itdoginfo_inside=1 → true; refilter_domains=0 → false
  grep -q '"itdoginfo_inside":true' "$BATS_TEST_TMPDIR/src.json"
  grep -q '"refilter_domains":false' "$BATS_TEST_TMPDIR/src.json"
}

@test "write_state emits valid JSON parseable by node (new keys included)" {
  MODE=failover MEMBERS="awg1:1:1 awg2:2:1" HEALTHY="awg1" STATE_FILE="$BATS_TEST_TMPDIR/valid.json"
  write_state awg1 awg1
  node -e "var d=require('fs').readFileSync('$BATS_TEST_TMPDIR/valid.json','utf8'); var o=JSON.parse(d); \
    if (!o.routing_mode) throw new Error('missing routing_mode'); \
    if (!o.sources) throw new Error('missing sources'); \
    if (typeof o.sources.itdoginfo_inside !== 'boolean') throw new Error('sources.itdoginfo_inside not boolean');"
}
@test "state write is atomic: no .tmp file left behind after write_state" {
  # Issue LOW: write to tmp then mv so LuCI reader never sees partial JSON.
  MODE=failover MEMBERS="awg1:1:1" HEALTHY="awg1" STATE_FILE="$BATS_TEST_TMPDIR/atomic.json"
  write_state awg1 awg1
  [ -f "$BATS_TEST_TMPDIR/atomic.json" ]          # final file present
  ! ls "$BATS_TEST_TMPDIR"/atomic.json.tmp.* 2>/dev/null  # no leftover tmp
}
