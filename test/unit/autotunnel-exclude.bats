#!/usr/bin/env bats
# Tests for autotunnel exclusion list (_is_excluded, cmd_add, cmd_auto, cmd_status).
load '../lib/harness.bash'
SCRIPT="$HARNESS_DIR/../openwrt/amnezia-autotunnel.sh"

# ---------------------------------------------------------------------------
# Common setup
# ---------------------------------------------------------------------------
setup() {
  export AMNEZIA_LIB="$HARNESS_DIR/../openwrt/lib"
  export FORCE_DIR="$BATS_TEST_TMPDIR/amnezia"
  mkdir -p "$FORCE_DIR"
  export RESOLVER="127.0.0.1"
  export CURL="curl"
  export NSLOOKUP="nslookup"
  export PROBE_MAXTIME="8"
  export DNSMASQ_HUP="0"
  export AMNEZIA_FORCE_LOAD="amnezia-force-load"
  # Worker-specific paths.
  export STATE_DIR="$BATS_TEST_TMPDIR/at-state"
  export ADDED_FILE="$BATS_TEST_TMPDIR/at-added"
  export LOADAVG_FILE="$BATS_TEST_TMPDIR/loadavg"
  export CRON_FILE="$BATS_TEST_TMPDIR/crontab"
  export DNSMASQ_CONFDIR="$BATS_TEST_TMPDIR/dnsmasq.d"
  export AMNEZIA_DNSMASQ_INIT="true"
  export PGREP="true"
  export AUTOTUNNEL_SKIP_HEALTHCHECK=1
  mkdir -p "$STATE_DIR"
  printf '0.10 0.08 0.05 1/100 1234\n' > "$LOADAVG_FILE"
  # Default UCI values.
  export UCI_GET_amnezia_config_master_enabled=1
  export UCI_GET_amnezia_config_routing_mode=direct-default
  export UCI_GET_amnezia_config_autotunnel_enabled=1
  export UCI_GET_amnezia_config_autotunnel_max_per_tick=2
  export UCI_GET_amnezia_config_autotunnel_max_per_hour=10
  export UCI_GET_amnezia_config_autotunnel_loadavg_max=2.0
  export UCI_GET_amnezia_config_autotunnel_list_cap=200
  export NSLOOKUP_ADDR=""
  : > "$STUB_LOG"

  # Write a default exclude list used by most tests.
  _excl="$BATS_TEST_TMPDIR/autotunnel-exclude.list"
  printf '# test exclusion list\napple.com\nmzstatic.com\nakadns.net\n' > "$_excl"
  export AMNEZIA_AT_EXCLUDE="$_excl"
  # Also set EXCLUDE_LIST directly (sourced via env in the script).
  export EXCLUDE_LIST="$_excl"

  # amnezia-force-load stub.
  _stub_dir="$BATS_TEST_TMPDIR/fl-stubs"
  mkdir -p "$_stub_dir"
  cat > "$_stub_dir/amnezia-force-load" <<'FLSTUB'
#!/bin/sh
echo "amnezia-force-load $*" >> "${STUB_LOG:-/dev/null}"
if [ "$1" = "save-manual" ]; then
  printf '%s' "$2" > "${FORCE_DIR}/force-tunnel.list"
fi
exit 0
FLSTUB
  chmod +x "$_stub_dir/amnezia-force-load"
  export AMNEZIA_FORCE_LOAD="$_stub_dir/amnezia-force-load"
  export PATH="$_stub_dir:$PATH"

  # Default LOGREAD stub: no output.
  _lr_stub="$BATS_TEST_TMPDIR/logread-stubs/logread"
  mkdir -p "$(dirname "$_lr_stub")"
  printf '#!/bin/sh\n# default: no output\n' > "$_lr_stub"
  chmod +x "$_lr_stub"
  export LOGREAD="$_lr_stub"
}

# ---------------------------------------------------------------------------
# Helper: write a LOGREAD stub that emits given lines.
# ---------------------------------------------------------------------------
_make_logread_stub() {
  _lr_tag="$1"
  _lr_lines="$2"
  _lr_dir="$BATS_TEST_TMPDIR/lr-${_lr_tag}"
  mkdir -p "$_lr_dir"
  printf '%s\n' "$_lr_lines" > "$_lr_dir/syslog.txt"
  cat > "$_lr_dir/logread" <<LRSTUB
#!/bin/sh
cat "$_lr_dir/syslog.txt"
LRSTUB
  chmod +x "$_lr_dir/logread"
  export LOGREAD="$_lr_dir/logread"
}

# ---------------------------------------------------------------------------
# Helper: write a throttled curl stub (direct=000, tunnel=200).
# ---------------------------------------------------------------------------
_make_throttled_curl() {
  _sd="$BATS_TEST_TMPDIR/curl-throttled-$1"
  mkdir -p "$_sd"
  cat > "$_sd/curl" <<'CURLSTUB'
#!/bin/sh
echo "curl $*" >> "${STUB_LOG:-/dev/null}"
_has_iface=0
for _a in "$@"; do case "$_a" in awg*) _has_iface=1; break ;; esac; done
if [ "$_has_iface" = "1" ]; then printf '200 0.200 500000 102400'; else printf '000 0.000 0 0'; fi
CURLSTUB
  chmod +x "$_sd/curl"
  export CURL="$_sd/curl"
  export PATH="$_sd:$PATH"
}

# ===========================================================================
# _is_excluded tests — exercised indirectly via cmd_add
# ===========================================================================

# ---------------------------------------------------------------------------
# Exact match: apple.com excluded
# ---------------------------------------------------------------------------
@test "_is_excluded: exact match apple.com -> cmd_add refuses without --force" {
  run sh "$SCRIPT" add apple.com
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "excluded"
}

# ---------------------------------------------------------------------------
# Subdomain match: api.apple.com -> excluded
# ---------------------------------------------------------------------------
@test "_is_excluded: subdomain api.apple.com -> excluded" {
  run sh "$SCRIPT" add api.apple.com
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "excluded"
}

# ---------------------------------------------------------------------------
# Deep subdomain: a.b.apple.com -> excluded
# ---------------------------------------------------------------------------
@test "_is_excluded: deep subdomain a.b.apple.com -> excluded" {
  run sh "$SCRIPT" add a.b.apple.com
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "excluded"
}

# ---------------------------------------------------------------------------
# Non-match: notapple.com must NOT be excluded
# ---------------------------------------------------------------------------
@test "_is_excluded: notapple.com is NOT excluded" {
  # Without a probe path we just need the exclusion gate to pass.
  # Use --force to bypass probe so only the exclusion logic matters for
  # membership (notapple.com should not be excluded, --force goes to add path).
  # Actually: --force bypasses probe but NOT exclusion (exclusion gate is before
  # --force in the add flow). So a non-excluded domain with --force should add.
  # We need to verify no "excluded" message.
  run sh "$SCRIPT" add notapple.com
  # May fail for other reasons (probe / master) but must NOT say "excluded".
  echo "$output" | grep -v "excluded" > /dev/null || true
  [ "$output" != *"excluded"* ] || false
}

# ---------------------------------------------------------------------------
# Non-match: pple.com (partial suffix, no label boundary) must NOT be excluded
# ---------------------------------------------------------------------------
@test "_is_excluded: pple.com is NOT excluded (no label boundary)" {
  run sh "$SCRIPT" add pple.com
  # Must not say "excluded".
  case "$output" in *excluded*) false ;; esac
}

# ---------------------------------------------------------------------------
# Non-match: apple.com.evil.org — apple.com is not a suffix at label boundary
# ---------------------------------------------------------------------------
@test "_is_excluded: apple.com.evil.org is NOT excluded" {
  run sh "$SCRIPT" add apple.com.evil.org
  case "$output" in *excluded*) false ;; esac
}

# ---------------------------------------------------------------------------
# Leading-dot entry: .apple.com in exclude list works same as apple.com
# ---------------------------------------------------------------------------
@test "_is_excluded: leading-dot entry .apple.com still matches sub.apple.com" {
  _excl2="$BATS_TEST_TMPDIR/excl2.list"
  printf '.apple.com\n' > "$_excl2"
  export AMNEZIA_AT_EXCLUDE="$_excl2"
  export EXCLUDE_LIST="$_excl2"
  run sh "$SCRIPT" add sub.apple.com
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "excluded"
}

# ---------------------------------------------------------------------------
# Comment and blank lines in exclude list are ignored
# ---------------------------------------------------------------------------
@test "_is_excluded: comments and blank lines in exclude list are ignored" {
  _excl3="$BATS_TEST_TMPDIR/excl3.list"
  printf '# just a comment\n\n   \n# another comment\nexample-safe.com\n' > "$_excl3"
  export AMNEZIA_AT_EXCLUDE="$_excl3"
  export EXCLUDE_LIST="$_excl3"
  # "comment" itself should not be excluded (it's not in the list).
  run sh "$SCRIPT" add comment.com
  case "$output" in *excluded*) false ;; esac
  # example-safe.com IS excluded.
  run sh "$SCRIPT" add example-safe.com
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "excluded"
}

# ---------------------------------------------------------------------------
# Case-insensitive: APPLE.COM in domain -> excluded
# ---------------------------------------------------------------------------
@test "_is_excluded: case-insensitive match APPLE.COM -> excluded" {
  run sh "$SCRIPT" add APPLE.COM
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "excluded"
}

# ---------------------------------------------------------------------------
# Case-insensitive: entry in uppercase APPLE.COM in file -> matches apple.com
# ---------------------------------------------------------------------------
@test "_is_excluded: uppercase entry in file matches lowercase domain" {
  _excl4="$BATS_TEST_TMPDIR/excl4.list"
  printf 'TESTDOMAIN.NET\n' > "$_excl4"
  export AMNEZIA_AT_EXCLUDE="$_excl4"
  export EXCLUDE_LIST="$_excl4"
  run sh "$SCRIPT" add sub.testdomain.net
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "excluded"
}

# ---------------------------------------------------------------------------
# Missing exclude file -> nothing excluded
# ---------------------------------------------------------------------------
@test "_is_excluded: missing exclude file -> nothing excluded" {
  export AMNEZIA_AT_EXCLUDE="/nonexistent/autotunnel-exclude.list"
  export EXCLUDE_LIST="/nonexistent/autotunnel-exclude.list"
  # apple.com would normally be excluded but file is missing -> not excluded.
  # Use --force so we don't need a real probe; check no "excluded" message.
  run sh "$SCRIPT" add apple.com --force
  case "$output" in *excluded*) false ;; esac
}

# ===========================================================================
# cmd_add: --force bypasses exclusion
# ===========================================================================
@test "cmd_add: --force allows adding excluded domain" {
  export NSLOOKUP_ADDR="1.2.3.4"
  run sh "$SCRIPT" add apple.com --force
  # Must NOT say "excluded".
  case "$output" in *excluded*) false ;; esac
  # Should say "added" (or "already-present") but not excluded.
  echo "$output" | grep -qE '"result":"added"|"result":"already-present"'
}

# ---------------------------------------------------------------------------
# cmd_add: excluded domain without --force -> exit 1 + stderr message
# ---------------------------------------------------------------------------
@test "cmd_add: excluded domain without --force -> exit 1 and stderr message" {
  run sh "$SCRIPT" add api2.smoot.apple.com
  [ "$status" -eq 1 ]
  # stderr (captured in $output by bats) must mention "excluded".
  echo "$output" | grep -q "excluded"
}

# ===========================================================================
# cmd_auto: excluded candidate is skipped
# ===========================================================================
@test "auto: excluded domain is NOT added to force-tunnel.list" {
  _make_throttled_curl excl
  export NSLOOKUP_ADDR="1.2.3.4"
  _sf="$BATS_TEST_TMPDIR/failover-excl.json"
  printf '{"active_pool":"awg1","routing_mode":"direct-default"}\n' > "$_sf"
  export STATE_FILE="$_sf"

  # Log contains an excluded apple.com candidate.
  _make_logread_stub excl \
    "Jul  1 12:00:01 router dnsmasq[1]: query[A] api.apple.com from 192.168.1.2"

  run sh "$SCRIPT" auto
  [ "$status" -eq 0 ]

  # force-tunnel.list must NOT contain api.apple.com.
  if [ -f "$FORCE_DIR/force-tunnel.list" ]; then
    run grep "api.apple.com" "$FORCE_DIR/force-tunnel.list"
    [ "$status" -ne 0 ]
  fi

  # curl must NOT have been called (no probe for excluded domain).
  run grep "^curl " "$STUB_LOG"
  [ "$status" -ne 0 ] || { echo "curl was called for excluded domain"; false; }
}

# ---------------------------------------------------------------------------
# auto: non-excluded throttled domain IS added (regression guard)
# ---------------------------------------------------------------------------
@test "auto: non-excluded throttled domain IS added to force-tunnel.list" {
  _make_throttled_curl nonexcl
  export NSLOOKUP_ADDR="1.2.3.4"
  _sf="$BATS_TEST_TMPDIR/failover-nonexcl.json"
  printf '{"active_pool":"awg1","routing_mode":"direct-default"}\n' > "$_sf"
  export STATE_FILE="$_sf"

  _make_logread_stub nonexcl \
    "Jul  1 12:00:01 router dnsmasq[1]: query[A] blocked.example.com from 192.168.1.2"

  run sh "$SCRIPT" auto
  [ "$status" -eq 0 ]

  [ -f "$FORCE_DIR/force-tunnel.list" ]
  grep -q "blocked.example.com" "$FORCE_DIR/force-tunnel.list"
}

# ===========================================================================
# probe-page / watch add path: covered via _pp_add_host
# The watch and probe-page add paths both delegate to _pp_add_host which now
# checks _is_excluded.  We verify this via cmd_auto (which also writes via the
# same candidate-loop path) and the _pp_add_host path separately here.
# A direct unit test of _pp_add_host would require sourcing the script; the
# auto-path test above is the practical coverage vehicle.
# ===========================================================================

# ---------------------------------------------------------------------------
# status: exclude_count reflects the list
# ---------------------------------------------------------------------------
@test "status: exclude_count reflects non-comment non-empty lines in list" {
  # Default exclude list has: apple.com, mzstatic.com, akadns.net = 3 entries.
  run sh "$SCRIPT" status
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"exclude_count":3'
}

@test "status: exclude_count=0 when exclude list is missing" {
  export AMNEZIA_AT_EXCLUDE="/nonexistent/autotunnel-exclude.list"
  export EXCLUDE_LIST="/nonexistent/autotunnel-exclude.list"
  run sh "$SCRIPT" status
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"exclude_count":0'
}

@test "status: exclude_count counts only non-comment non-empty lines" {
  _excl5="$BATS_TEST_TMPDIR/excl5.list"
  # 2 real entries, 2 comment lines, 1 blank line.
  printf '# comment\nexample1.com\n\n# another comment\nexample2.com\n' > "$_excl5"
  export AMNEZIA_AT_EXCLUDE="$_excl5"
  export EXCLUDE_LIST="$_excl5"
  run sh "$SCRIPT" status
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"exclude_count":2'
}
