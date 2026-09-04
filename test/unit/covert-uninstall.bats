#!/usr/bin/env bats
# Phase 9 (covert-creator-router plan): openwrt/install-amnezia-pbr.sh
# --uninstall reverse-order teardown (design "Uninstall/rollback").
load '../lib/harness.bash'

@test "uninstall_reverses: disable runs before init removal, deluser/delgroup run LAST" {
  AMNEZIA_COVERT_INIT=amnezia-covert-init \
    run sh "$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh" --uninstall
  [ "$status" -eq 0 ]

  # amnezia-covert-ctl disable must have run (routed through the stub init:
  # cmd_disable calls "$AMNEZIA_COVERT_INIT" stop/disable).
  grep -q "amnezia-covert-init stop" "$STUB_LOG"
  grep -q "amnezia-covert-init disable" "$STUB_LOG"
  grep -q "uninstall:init-removed" "$STUB_LOG"
  grep -q "uninstall:deluser" "$STUB_LOG"
  grep -q "uninstall:delgroup" "$STUB_LOG"

  # Ordering: the ctl's own "disable" (via the init stub) precedes the
  # installer's own init-file removal, which precedes deluser, which
  # precedes delgroup.
  _l_disable=$(grep -n "amnezia-covert-init disable" "$STUB_LOG" | head -n1 | cut -d: -f1)
  _l_init_removed=$(grep -n "uninstall:init-removed" "$STUB_LOG" | head -n1 | cut -d: -f1)
  _l_deluser=$(grep -n "uninstall:deluser" "$STUB_LOG" | head -n1 | cut -d: -f1)
  _l_delgroup=$(grep -n "uninstall:delgroup" "$STUB_LOG" | head -n1 | cut -d: -f1)

  [ "$_l_disable" -lt "$_l_init_removed" ]
  [ "$_l_init_removed" -lt "$_l_deluser" ]
  [ "$_l_deluser" -lt "$_l_delgroup" ]
}

@test "uninstall removes the amnezia-covert line from the passwd/group files" {
  # OpenWrt busybox has no deluser/delgroup applets -- the installer edits
  # /etc/passwd + /etc/group directly (temp+mv line removal), the same
  # idiom _amz_covert_ensure_user uses to create them.
  _passwd="$BATS_TEST_TMPDIR/passwd-with-covert"
  _group="$BATS_TEST_TMPDIR/group-with-covert"
  printf 'root:x:0:0:root:/root:/bin/ash\namnezia-covert:x:391:391:amnezia-covert:/var/run/amnezia-covert:/bin/false\n' > "$_passwd"
  printf 'root:x:0:\namnezia-covert:x:391:\n' > "$_group"
  AMNEZIA_PASSWD="$_passwd" AMNEZIA_GROUP="$_group" AMNEZIA_COVERT_INIT=amnezia-covert-init \
    run sh "$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh" --uninstall
  [ "$status" -eq 0 ]
  # NOTE: `!`-negated commands are exempt from bash errexit, so a `!`
  # assertion must never be a non-final statement in a bats test body (its
  # failure would silently not fail the test) -- use `run` + an explicit
  # status check instead.
  run grep -q '^amnezia-covert:' "$_passwd"
  [ "$status" -ne 0 ]
  run grep -q '^amnezia-covert:' "$_group"
  [ "$status" -ne 0 ]
  # The other line must survive untouched.
  grep -q '^root:x:0:0:root:/root:/bin/ash$' "$_passwd"
  grep -q '^root:x:0:$' "$_group"
}

@test "uninstall is idempotent when nothing was ever installed" {
  AMNEZIA_COVERT_INIT=amnezia-covert-init \
    run sh "$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh" --uninstall
  [ "$status" -eq 0 ]
  # A second run must also succeed cleanly (absent -> skip, never error).
  AMNEZIA_COVERT_INIT=amnezia-covert-init \
    run sh "$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh" --uninstall
  [ "$status" -eq 0 ]
}

@test "uninstall --dry-run emits the ordered step markers without side effects" {
  run sh "$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh" --uninstall --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "uninstall:disable"
  echo "$output" | grep -q "uninstall:deluser"
  echo "$output" | grep -q "uninstall:delgroup"
}

@test "uninstall ACL removal repairs a dangling trailing comma (covert grants LAST)" {
  _acl_fixture="$BATS_TEST_TMPDIR/luci-app-amnezia.json"
  cat > "$_acl_fixture" <<'JSON'
{
  "amnezia": {
    "description": "Grant UCI access for luci-app-amnezia",
    "read": {
      "uci": [ "amnezia" ]
    },
    "write": {
      "uci": [ "amnezia" ],
      "file": {
        "/usr/bin/amnezia-tunnel-ctl": [ "exec" ],
        "/usr/bin/amnezia-autotunnel": [ "exec" ],
        "/usr/bin/amnezia-covert-ctl": [ "exec" ],
        "/etc/amnezia/covert/vk-cookies.json": [ "read", "write" ]
      }
    }
  }
}
JSON

  AMZ_COVERT_ACL="$_acl_fixture" \
    AMNEZIA_COVERT_INIT=amnezia-covert-init \
    run sh "$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh" --uninstall
  [ "$status" -eq 0 ]

  # Must still parse as valid JSON (a dangling trailing comma before "}"
  # would make json-c -- and python's json module -- reject the file).
  run python3 -m json.tool "$_acl_fixture"
  [ "$status" -eq 0 ]

  # Neither covert grant remains.
  run grep -c "amnezia-covert-ctl" "$_acl_fixture"
  [ "$status" -eq 1 ]
  run grep -c "vk-cookies.json" "$_acl_fixture"
  [ "$status" -eq 1 ]

  # The preceding (non-covert) grant survives with no trailing comma.
  run grep -c "amnezia-autotunnel" "$_acl_fixture"
  [ "$status" -eq 0 ]
}

@test "uninstall ACL removal is a no-op repair when covert grants are NOT last" {
  _acl_fixture="$BATS_TEST_TMPDIR/luci-app-amnezia-notlast.json"
  cat > "$_acl_fixture" <<'JSON'
{
  "amnezia": {
    "write": {
      "file": {
        "/usr/bin/amnezia-tunnel-ctl": [ "exec" ],
        "/usr/bin/amnezia-covert-ctl": [ "exec" ],
        "/etc/amnezia/covert/vk-cookies.json": [ "read", "write" ],
        "/usr/bin/amnezia-autotunnel": [ "exec" ]
      }
    }
  }
}
JSON

  AMZ_COVERT_ACL="$_acl_fixture" \
    AMNEZIA_COVERT_INIT=amnezia-covert-init \
    run sh "$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh" --uninstall
  [ "$status" -eq 0 ]

  # Still valid JSON -- the repair must not damage an already-valid file.
  run python3 -m json.tool "$_acl_fixture"
  [ "$status" -eq 0 ]

  run grep -c "amnezia-covert-ctl" "$_acl_fixture"
  [ "$status" -eq 1 ]
  run grep -c "amnezia-autotunnel" "$_acl_fixture"
  [ "$status" -eq 0 ]
}
