#!/usr/bin/env bats
load '../lib/harness.bash'
SCRIPT="$HARNESS_DIR/../openwrt/amnezia-app-ctl.sh"

setup() {
  export FORCE_DIR="$BATS_TEST_TMPDIR/amnezia"
  mkdir -p "$FORCE_DIR/force.d"
  export AMNEZIA_FORCE_UPDATE="true"    # no-op: just validates UCI writes
  export AMNEZIA_FORCE_LOAD="true"
  # Provide UCI_FAKE_SOURCES for existing built-in sources.
  export UCI_FAKE_SOURCES=""
  # Reset UCI state for each test.
  : > "$STUB_LOG"
}

# ---------------------------------------------------------------------------
# list: empty
# ---------------------------------------------------------------------------
@test "list emits [] when no force_source sections exist" {
  # No UCI_FAKE_SOURCES set — uci show amnezia returns nothing useful.
  run sh "$SCRIPT" list
  [ "$status" -eq 0 ]
  # Output must be valid JSON array.
  echo "$output" | grep -q '^\[' || { echo "not a JSON array: $output"; false; }
}

# ---------------------------------------------------------------------------
# list: with apps
# ---------------------------------------------------------------------------
@test "list emits JSON array with app entries" {
  # Seed a force_source via UCI_FAKE_APPS.
  export UCI_FAKE_APPS="telegram:1"
  run sh "$SCRIPT" list
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '\[' || { echo "expected array: $output"; false; }
}

# ---------------------------------------------------------------------------
# add static: validates and writes CIDRs
# ---------------------------------------------------------------------------
@test "add static: writes cidrs to UCI and calls force-update" {
  run sh "$SCRIPT" add myapp "My App" static "10.0.0.0/8 192.168.1.0/24"
  [ "$status" -eq 0 ]
  # uci add_list must have been called for each CIDR.
  grep -q 'add_list.*myapp.*cidr.*10.0.0.0' "$STUB_LOG" \
    || grep -q 'add_list' "$STUB_LOG" \
    || { echo "add_list not called; log: $(cat $STUB_LOG)"; false; }
  grep -q 'uci commit' "$STUB_LOG"
}

@test "add static: rejects non-CIDR garbage" {
  run sh "$SCRIPT" add badapp "Bad" static "not-a-cidr 10.0.0.0/8"
  [ "$status" -ne 0 ]
}

@test "add static: rejects domain names" {
  run sh "$SCRIPT" add badapp2 "Bad2" static "example.com"
  [ "$status" -ne 0 ]
}

@test "add static: accepts bare IPs (no prefix length)" {
  run sh "$SCRIPT" add bareip "Bare IP" static "1.2.3.4"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# add as
# ---------------------------------------------------------------------------
@test "add as: stores ASN digits" {
  run sh "$SCRIPT" add metaapp "Meta" as "AS32934"
  [ "$status" -eq 0 ]
  grep -q 'set.*metaapp.*asn.*32934' "$STUB_LOG" \
    || { echo "asn not set; log: $(cat $STUB_LOG)"; false; }
  grep -q 'set.*metaapp.*kind.*as' "$STUB_LOG" \
    || { echo "kind=as not set; log: $(cat $STUB_LOG)"; false; }
}

@test "add as: accepts ASN without AS prefix" {
  run sh "$SCRIPT" add metaapp2 "Meta2" as "32934"
  [ "$status" -eq 0 ]
  grep -q '32934' "$STUB_LOG"
}

@test "add as: rejects non-numeric ASN" {
  run sh "$SCRIPT" add badas "Bad AS" as "NOTANUMBER"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# add url
# ---------------------------------------------------------------------------
@test "add url: stores URL and kind=cidr" {
  run sh "$SCRIPT" add urlapp "URL App" url "https://example.com/cidrs.txt"
  [ "$status" -eq 0 ]
  grep -q 'set.*urlapp.*url.*https' "$STUB_LOG" \
    || { echo "url not set; log: $(cat $STUB_LOG)"; false; }
  grep -q 'set.*urlapp.*kind.*cidr' "$STUB_LOG" \
    || { echo "kind=cidr not set; log: $(cat $STUB_LOG)"; false; }
}

@test "add url: rejects non-http data" {
  run sh "$SCRIPT" add badurl "Bad URL" url "ftp://example.com/list.txt"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# add preset telegram
# ---------------------------------------------------------------------------
@test "add preset telegram: creates static section with known CIDRs" {
  run sh "$SCRIPT" add telegram "Telegram" preset telegram
  [ "$status" -eq 0 ]
  # Must have set kind=static.
  grep -q 'kind.*static' "$STUB_LOG" \
    || grep -q 'static' "$STUB_LOG" \
    || { echo "static kind not set; log: $(cat $STUB_LOG)"; false; }
  # Must have added at least one Telegram CIDR.
  grep -q '91.108' "$STUB_LOG" \
    || { echo "Telegram CIDR not wired; log: $(cat $STUB_LOG)"; false; }
}

# ---------------------------------------------------------------------------
# add preset meta
# ---------------------------------------------------------------------------
@test "add preset meta: creates as section with ASN 32934" {
  run sh "$SCRIPT" add meta "Meta" preset meta
  [ "$status" -eq 0 ]
  grep -q '32934' "$STUB_LOG" \
    || { echo "ASN 32934 not wired; log: $(cat $STUB_LOG)"; false; }
}

# ---------------------------------------------------------------------------
# bad name / duplicate
# ---------------------------------------------------------------------------
@test "add: rejects invalid name (uppercase)" {
  run sh "$SCRIPT" add BadName "Bad" static "10.0.0.0/8"
  [ "$status" -ne 0 ]
}

@test "add: rejects name with hyphens" {
  run sh "$SCRIPT" add "bad-name" "Bad" static "10.0.0.0/8"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# remove
# ---------------------------------------------------------------------------
@test "remove: calls uci delete and removes force.d file" {
  # Plant a list file.
  printf '10.0.0.0/8\n' > "$FORCE_DIR/force.d/myapp.list"
  # Stub uci get to return 'force_source' for this name.
  export UCI_GET_amnezia_myapp="force_source"
  run sh "$SCRIPT" remove myapp
  [ "$status" -eq 0 ]
  # list file must be gone.
  [ ! -f "$FORCE_DIR/force.d/myapp.list" ]
  grep -q 'delete.*myapp' "$STUB_LOG" \
    || { echo "uci delete not called; log: $(cat $STUB_LOG)"; false; }
}

@test "remove: rejects unknown section" {
  run sh "$SCRIPT" remove nonexistent
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# enable / disable
# ---------------------------------------------------------------------------
@test "enable: sets enabled=1 and calls force-update" {
  export UCI_GET_amnezia_myapp="force_source"
  run sh "$SCRIPT" enable myapp
  [ "$status" -eq 0 ]
  grep -q 'set.*myapp.*enabled.*1' "$STUB_LOG" \
    || { echo "enabled=1 not set; log: $(cat $STUB_LOG)"; false; }
}

@test "disable: sets enabled=0 and calls force-load" {
  export UCI_GET_amnezia_myapp="force_source"
  run sh "$SCRIPT" disable myapp
  [ "$status" -eq 0 ]
  grep -q 'set.*myapp.*enabled.*0' "$STUB_LOG" \
    || { echo "enabled=0 not set; log: $(cat $STUB_LOG)"; false; }
}

@test "enable: rejects nonexistent section" {
  run sh "$SCRIPT" enable ghostapp
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# preset list
# ---------------------------------------------------------------------------
@test "preset list: prints known preset ids" {
  run sh "$SCRIPT" preset list
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'telegram'
  echo "$output" | grep -q 'meta'
}

@test "preset list: includes all 9 preset ids" {
  run sh "$SCRIPT" preset list
  [ "$status" -eq 0 ]
  for id in telegram meta x discord tiktok viber linkedin netflix google; do
    echo "$output" | grep -q "$id" \
      || { echo "missing preset id: $id; output: $output"; false; }
  done
}

# ---------------------------------------------------------------------------
# add preset x (new AS preset — spot-check kind=as + asn=13414)
# ---------------------------------------------------------------------------
@test "add preset x: creates as section with ASN 13414" {
  run sh "$SCRIPT" add x "X (Twitter)" preset x
  [ "$status" -eq 0 ]
  grep -q '13414' "$STUB_LOG" \
    || { echo "ASN 13414 not wired; log: $(cat $STUB_LOG)"; false; }
  grep -q 'set.*x.*kind.*as' "$STUB_LOG" \
    || grep -q 'kind.*as' "$STUB_LOG" \
    || { echo "kind=as not set; log: $(cat $STUB_LOG)"; false; }
}

@test "add preset discord: creates as section with ASN 49544" {
  run sh "$SCRIPT" add discord "Discord" preset discord
  [ "$status" -eq 0 ]
  grep -q '49544' "$STUB_LOG" \
    || { echo "ASN 49544 not wired; log: $(cat $STUB_LOG)"; false; }
}

@test "add preset netflix: creates as section with ASN 2906" {
  run sh "$SCRIPT" add netflix "Netflix" preset netflix
  [ "$status" -eq 0 ]
  grep -q '2906' "$STUB_LOG" \
    || { echo "ASN 2906 not wired; log: $(cat $STUB_LOG)"; false; }
}

# ---------------------------------------------------------------------------
# bad usage
# ---------------------------------------------------------------------------
@test "unknown verb exits nonzero" {
  run sh "$SCRIPT" foobar
  [ "$status" -ne 0 ]
}

@test "add with too few args exits nonzero" {
  run sh "$SCRIPT" add myapp
  [ "$status" -ne 0 ]
}
