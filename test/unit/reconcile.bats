#!/usr/bin/env bats
load '../lib/harness.bash'
setup() {
  export AMNEZIA_LIB="$HARNESS_DIR/../openwrt/lib"
  export ST_DIR="$BATS_TEST_TMPDIR/amnezia-fo"
  mkdir -p "$ST_DIR"
  . "$HARNESS_DIR/../openwrt/amnezia-failover" --source-only
}

@test "failover mode: best healthy by metric becomes pool+sticky default" {
  MODE=failover MEMBERS="awg1:1:1 awg2:2:1" HEALTHY="awg2" STICKY_TARGET=awg1
  _PREV_POOL="" _PREV_STKY=""
  run reconcile
  grep -q "ip route replace default dev awg2 table 101" "$STUB_LOG"      # pool -> only healthy
  grep -q "ip route replace default dev awg2 table 100" "$STUB_LOG"      # sticky re-pinned (awg1 down)
}
@test "all down -> blackhole both tables + selective flush only on change" {
  MODE=failover MEMBERS="awg1:1:1" HEALTHY=""
  _PREV_POOL="awg1" _PREV_STKY="awg1"  # was up, now going down -> change
  run reconcile
  grep -q "ip route replace blackhole default table 101" "$STUB_LOG"
  grep -q "ip route replace blackhole default table 100" "$STUB_LOG"
  grep -q "conntrack -D" "$STUB_LOG"
}
@test "no flush when pool does NOT change (no-change path)" {
  MODE=failover MEMBERS="awg1:1:1" HEALTHY="awg1"
  _PREV_POOL="awg1" _PREV_STKY="awg1"  # same as new result -> no change
  run reconcile
  ! grep -q "conntrack -D" "$STUB_LOG"
}
@test "balance mode does NOT emit a member-scoped conntrack flush (flow migration via resilient nexthop)" {
  # Per-member surgical conntrack flushing is a future enhancement; balance mode
  # relies on the resilient nexthop group idle_timer/bucket reassignment instead.
  MODE=balance MEMBERS="awg1:1:1 awg2:2:1" HEALTHY="awg1"
  _PREV_POOL="" _PREV_STKY="" _PREV_HEALTHY="awg1 awg2"  # awg2 departed
  run reconcile
  ! grep -q "conntrack -D" "$STUB_LOG"
}
@test "sticky stays on healthy sticky_target when it is up" {
  MODE=failover MEMBERS="awg1:1:1 awg2:2:1" HEALTHY="awg1 awg2" STICKY_TARGET=awg1
  _PREV_POOL="" _PREV_STKY=""
  run reconcile
  grep -q "ip route replace default dev awg1 table 100" "$STUB_LOG"
}
