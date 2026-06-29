#!/usr/bin/env bats
# Tests for the new force_source kinds: static and as.
# Verifies that kind=static and kind=as are NOT skipped by the url guard,
# and that their materialization logic works correctly.
load '../lib/harness.bash'
SCRIPT="$HARNESS_DIR/../openwrt/amnezia-force-update.sh"
FIXTURE_DIR="$HARNESS_DIR/../test/fixtures"

setup() {
  export FORCE_DIR="$BATS_TEST_TMPDIR/amnezia"
  mkdir -p "$FORCE_DIR/force.d"
  export AMNEZIA_FORCE_LOAD="true"
  export AMZ_FAKE_TUNNEL_DEV="awg1"
  : > "$STUB_LOG"
}

# ---------------------------------------------------------------------------
# kind=static: must NOT be skipped by the url guard
# ---------------------------------------------------------------------------
@test "kind=static: materializes list from inline cidr entries (not skipped by url guard)" {
  # Expose one force_source section with kind=static and no url.
  export UCI_FAKE_APPS="myapp_static:1:static"
  # Set the cidr list for the static source.
  export UCI_GET_amnezia_myapp_static_cidr="10.0.0.0/8 192.168.0.0/16"
  run sh "$SCRIPT"
  [ "$status" -eq 0 ]
  # The cache file must have been written.
  [ -f "$FORCE_DIR/force.d/myapp_static.list" ] \
    || { echo "cache not written; stub log: $(cat $STUB_LOG)"; false; }
  # Contents must contain the CIDRs.
  grep -q '10.0.0.0/8' "$FORCE_DIR/force.d/myapp_static.list" \
    || { echo "10.0.0.0/8 not in list"; cat "$FORCE_DIR/force.d/myapp_static.list"; false; }
  grep -q '192.168.0.0/16' "$FORCE_DIR/force.d/myapp_static.list"
}

@test "kind=static: stamp records status=ok and count>0" {
  export UCI_FAKE_APPS="myapp_static2:1:static"
  export UCI_GET_amnezia_myapp_static2_cidr="172.16.0.0/12"
  run sh "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q '"myapp_static2"' "$FORCE_DIR/force-update.json"
  grep -q '"status":"ok"' "$FORCE_DIR/force-update.json"
}

@test "kind=static: source with no cidr entries marks failed (not crash)" {
  export UCI_FAKE_APPS="myapp_empty:1:static"
  # No UCI_GET_amnezia_myapp_empty_cidr set — empty list.
  run sh "$SCRIPT"
  [ "$status" -eq 0 ]
  # status should be 'failed' for the empty source.
  grep -q '"status":"failed"' "$FORCE_DIR/force-update.json" \
    || { echo "expected failed status; json: $(cat $FORCE_DIR/force-update.json)"; false; }
}

# ---------------------------------------------------------------------------
# kind=as: fetches from RIPEstat and extracts only IPv4 prefixes
# ---------------------------------------------------------------------------
@test "kind=as: fetches RIPEstat and extracts IPv4-only prefixes" {
  export UCI_FAKE_APPS="metaapp:1:as"
  export UCI_GET_amnezia_metaapp_asn="32934"
  # Feed the RIPEstat fixture via AMZ_FETCH (curl stub respects AMZ_FETCH).
  export AMZ_FETCH="$FIXTURE_DIR/ripestat-as32934.json"
  run sh "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -f "$FORCE_DIR/force.d/metaapp.list" ] \
    || { echo "cache not written for metaapp; log: $(cat $STUB_LOG)"; false; }
  # IPv4 prefixes must be present.
  grep -q '31.13.24.0/21' "$FORCE_DIR/force.d/metaapp.list" \
    || { echo "IPv4 prefix missing; list: $(cat $FORCE_DIR/force.d/metaapp.list)"; false; }
  grep -q '66.220.144.0/20' "$FORCE_DIR/force.d/metaapp.list"
}

@test "kind=as: drops IPv6 prefixes from mixed RIPEstat response" {
  export UCI_FAKE_APPS="metaapp2:1:as"
  export UCI_GET_amnezia_metaapp2_asn="32934"
  export AMZ_FETCH="$FIXTURE_DIR/ripestat-as32934.json"
  run sh "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -f "$FORCE_DIR/force.d/metaapp2.list" ]
  # IPv6 prefixes must NOT be in the output.
  run grep -q '2a03:' "$FORCE_DIR/force.d/metaapp2.list"
  [ "$status" -ne 0 ] || { echo "IPv6 prefix leaked into list"; false; }
  run grep -q '2620:' "$FORCE_DIR/force.d/metaapp2.list"
  [ "$status" -ne 0 ] || { echo "IPv6 prefix leaked into list"; false; }
}

@test "kind=as: validates extracted prefixes as IPv4/CIDR (content validation passes)" {
  export UCI_FAKE_APPS="metaapp3:1:as"
  export UCI_GET_amnezia_metaapp3_asn="32934"
  export AMZ_FETCH="$FIXTURE_DIR/ripestat-as32934.json"
  run sh "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q '"status":"ok"' "$FORCE_DIR/force-update.json" \
    || { echo "expected ok; json: $(cat $FORCE_DIR/force-update.json)"; false; }
}

@test "kind=as: stamp records count for extracted prefixes" {
  export UCI_FAKE_APPS="metaapp4:1:as"
  export UCI_GET_amnezia_metaapp4_asn="32934"
  export AMZ_FETCH="$FIXTURE_DIR/ripestat-as32934.json"
  run sh "$SCRIPT"
  [ "$status" -eq 0 ]
  # Fixture has 4 IPv4 prefixes; count must be > 0.
  grep -q '"count":[1-9]' "$FORCE_DIR/force-update.json" \
    || { echo "count=0 in stamp; json: $(cat $FORCE_DIR/force-update.json)"; false; }
}

# ---------------------------------------------------------------------------
# Existing cidr/domains kinds: unchanged behavior
# ---------------------------------------------------------------------------
@test "kind=cidr (url): still fetched via url (not broken by restructure)" {
  export UCI_FAKE_APPS="urlsrc:1:cidr"
  export UCI_GET_amnezia_urlsrc_url="https://example.com/cidrs.txt"
  run sh "$SCRIPT"
  [ "$status" -eq 0 ]
  # curl/wget fetch must have been attempted.
  grep -q 'curl\|wget\|uclient-fetch' "$STUB_LOG" \
    || { echo "no fetch attempted; log: $(cat $STUB_LOG)"; false; }
}

@test "disabled source (kind=static) is still skipped" {
  export UCI_FAKE_APPS="disabled_static:0:static"
  export UCI_GET_amnezia_disabled_static_cidr="10.0.0.0/8"
  run sh "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -f "$FORCE_DIR/force.d/disabled_static.list" ]
}
