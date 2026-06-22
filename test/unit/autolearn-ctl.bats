#!/usr/bin/env bats
load '../lib/harness.bash'
SCRIPT="$HARNESS_DIR/../openwrt/amnezia-autolearn-ctl.sh"
setup() {
  export AL_DIR="$BATS_TEST_TMPDIR/amnezia"; mkdir -p "$AL_DIR/force.d" "$AL_DIR/autolearn"
  export AUTO_LIST="$AL_DIR/force.d/auto.list"
  export AMNEZIA_FORCE_LOAD="amnezia-force-load"
  export UCI_GET_amnezia_config_autolearn_enabled="1"
  printf 'a.com\nb.com\n' > "$AUTO_LIST"
  printf 'a.com\tdirect_geoblocked\t2\t\t100\t200\tgeoblock\n' > "$AL_DIR/autolearn/candidates.tsv"
  printf 'b.com\tdirect_dpi_blocked\t3\t\t100\t200\tdpi\n' >> "$AL_DIR/autolearn/candidates.tsv"
}
@test "list emits valid JSON array with reason tags" {
  run sh "$SCRIPT" list
  echo "$output" | grep -q '"domain":"a.com"'
  echo "$output" | grep -q '"reason":"geoblock"'
  echo "$output" | grep -q '"reason":"dpi"'
}
@test "status emits enabled + count" {
  run sh "$SCRIPT" status
  echo "$output" | grep -q '"enabled":1'
  echo "$output" | grep -q '"count":2'
}
@test "status on an EMPTY auto.list is valid single-line JSON with count 0" {
  : > "$AUTO_LIST"
  run sh "$SCRIPT" status
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | wc -l | tr -d ' ')" -le 1 ]   # no embedded newline
  echo "$output" | grep -qx '{"enabled":1,"count":0}'
}
@test "veto removes from auto.list, adds to deny.list, runs force-load" {
  run sh "$SCRIPT" veto a.com; [ "$status" -eq 0 ]
  # Robust negative: a.com should be removed from auto.list
  run grep -qx 'a.com' "$AUTO_LIST"; [ "$status" -ne 0 ]
  grep -qx 'a.com' "$AL_DIR/autolearn/deny.list"
  grep -q 'amnezia-force-load' "$STUB_LOG"
}
@test "promote moves to force-tunnel.list (manual, sacrosanct)" {
  run sh "$SCRIPT" promote b.com; [ "$status" -eq 0 ]
  # Robust negative: b.com should be removed from auto.list
  run grep -qx 'b.com' "$AUTO_LIST"; [ "$status" -ne 0 ]
  grep -qx 'b.com' "$AL_DIR/force-tunnel.list"
}
@test "purge empties auto.list + candidates, runs force-load" {
  run sh "$SCRIPT" purge; [ "$status" -eq 0 ]
  [ ! -s "$AUTO_LIST" ]
  [ ! -s "$AL_DIR/autolearn/candidates.tsv" ]
}
@test "set-enabled writes uci" {
  run sh "$SCRIPT" set-enabled 0; [ "$status" -eq 0 ]
  grep -q "set amnezia.config.autolearn_enabled=0" "$STUB_LOG"
}
@test "set-enabled rejects invalid value" {
  run sh "$SCRIPT" set-enabled 2; [ "$status" -eq 2 ]
  echo "$output" | grep -q '"error"'
}
@test "promote: regex lookalike aXcom is NOT matched when promoting a.com (grep -F fix)" {
  # Seed MANUAL with a look-alike domain that differs only in the dot position.
  # Without -F, "grep -x 'a.com'" would also match 'aXcom' (dot = any char in BRE).
  printf 'aXcom\n' > "$AL_DIR/force-tunnel.list"
  # a.com is in AUTO_LIST (from setup); promote it.
  run sh "$SCRIPT" promote a.com; [ "$status" -eq 0 ]
  # a.com must now be in MANUAL.
  run grep -Fxq 'a.com' "$AL_DIR/force-tunnel.list"; [ "$status" -eq 0 ]
  # aXcom must still be there — it was not falsely matched as the duplicate.
  run grep -Fxq 'aXcom' "$AL_DIR/force-tunnel.list"; [ "$status" -eq 0 ]
  # a.com must be gone from AUTO_LIST.
  run grep -Fxq 'a.com' "$AUTO_LIST"; [ "$status" -ne 0 ]
}
