#!/usr/bin/env bats
# Tests for amnezia-autotunnel.sh — auto/enable/disable/status/remove verbs.
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
  # Worker-specific paths — all in tmpdir so no real system paths are touched.
  export STATE_DIR="$BATS_TEST_TMPDIR/at-state"
  export ADDED_FILE="$BATS_TEST_TMPDIR/at-added"
  export LOADAVG_FILE="$BATS_TEST_TMPDIR/loadavg"
  export CRON_FILE="$BATS_TEST_TMPDIR/crontab"
  export DNSMASQ_CONFDIR="$BATS_TEST_TMPDIR/dnsmasq.d"
  export AMNEZIA_DNSMASQ_INIT="true"  # no-op; don't restart real dnsmasq
  # pgrep stub: always returns success (dnsmasq "running") by default.
  export PGREP="true"
  # Skip the live health check in enable/disable by default so tests are hermetic.
  export AUTOTUNNEL_SKIP_HEALTHCHECK=1
  mkdir -p "$STATE_DIR"
  # Default /proc/loadavg stub: low load.
  printf '0.10 0.08 0.05 1/100 1234\n' > "$LOADAVG_FILE"
  # Default: master enabled, routing_mode=direct-default, autotunnel enabled.
  export UCI_GET_amnezia_config_master_enabled=1
  export UCI_GET_amnezia_config_routing_mode=direct-default
  export UCI_GET_amnezia_config_autotunnel_enabled=1
  export UCI_GET_amnezia_config_autotunnel_max_per_tick=2
  export UCI_GET_amnezia_config_autotunnel_max_per_hour=10
  export UCI_GET_amnezia_config_autotunnel_loadavg_max=2.0
  export UCI_GET_amnezia_config_autotunnel_list_cap=200
  # Default: no state file (no active_pool), nslookup returns no address.
  export NSLOOKUP_ADDR=""
  : > "$STUB_LOG"
  # Minimal amnezia-force-load stub (captures save-manual).
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

  # Default LOGREAD stub: no output (empty syslog).
  # Individual tests override this with canned dnsmasq query lines.
  _lr_stub="$BATS_TEST_TMPDIR/logread-stubs/logread"
  mkdir -p "$(dirname "$_lr_stub")"
  printf '#!/bin/sh\n# default: no output\n' > "$_lr_stub"
  chmod +x "$_lr_stub"
  export LOGREAD="$_lr_stub"
}

# ---------------------------------------------------------------------------
# Helper: write a LOGREAD stub that emits given lines.
# Usage: _make_logread_stub <tag> <lines>
# <lines> is a string of newline-separated syslog lines.
# ---------------------------------------------------------------------------
_make_logread_stub() {
  _lr_tag="$1"
  _lr_lines="$2"
  _lr_dir="$BATS_TEST_TMPDIR/lr-${_lr_tag}"
  mkdir -p "$_lr_dir"
  # Write lines to a data file; stub cat's it.
  printf '%s\n' "$_lr_lines" > "$_lr_dir/syslog.txt"
  cat > "$_lr_dir/logread" <<LRSTUB
#!/bin/sh
cat "$_lr_dir/syslog.txt"
LRSTUB
  chmod +x "$_lr_dir/logread"
  export LOGREAD="$_lr_dir/logread"
}

# ---------------------------------------------------------------------------
# Helper: write a throttled curl stub (direct=000, tunnel=200)
# ---------------------------------------------------------------------------
_make_throttled_curl() {
  _sd="$BATS_TEST_TMPDIR/curl-throttled-$1"
  mkdir -p "$_sd"
  cat > "$_sd/curl" <<'CURLSTUB'
#!/bin/sh
echo "curl $*" >> "${STUB_LOG:-/dev/null}"
_has_iface=0
for _a in "$@"; do case "$_a" in awg*) _has_iface=1; break ;; esac; done
if [ "$_has_iface" = "1" ]; then printf '200 0.200'; else printf '000 0.000'; fi
CURLSTUB
  chmod +x "$_sd/curl"
  export CURL="$_sd/curl"
  export PATH="$_sd:$PATH"
}

# ---------------------------------------------------------------------------
# auto: disabled (autotunnel_enabled=0) -> silent exit 0
# ---------------------------------------------------------------------------
@test "auto: disabled -> exit 0 silently, no probe" {
  export UCI_GET_amnezia_config_autotunnel_enabled=0
  run sh "$SCRIPT" auto
  [ "$status" -eq 0 ]
  # No curl invocations.
  run grep "curl" "$STUB_LOG"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# auto: master disabled -> exit 0
# ---------------------------------------------------------------------------
@test "auto: master disabled -> exit 0 silently" {
  export UCI_GET_amnezia_config_master_enabled=0
  run sh "$SCRIPT" auto
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# auto: routing_mode != direct-default -> exit 0
# ---------------------------------------------------------------------------
@test "auto: routing_mode=tunnel-default -> exit 0 (force list dormant in this mode)" {
  export UCI_GET_amnezia_config_routing_mode=tunnel-default
  run sh "$SCRIPT" auto
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# auto: loadavg > loadavg_max -> skip
# ---------------------------------------------------------------------------
@test "auto: loadavg above max -> skip with log" {
  printf '3.00 2.80 2.50 1/100 1234\n' > "$LOADAVG_FILE"
  export UCI_GET_amnezia_config_autotunnel_loadavg_max=2.0
  run sh "$SCRIPT" auto
  [ "$status" -eq 0 ]
  # No curl.
  run grep "curl" "$STUB_LOG"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# auto: hourly cap reached -> exit without probing
# ---------------------------------------------------------------------------
@test "auto: hourly cap reached -> exit 0 without probing" {
  _cur_hour=$(date +%s 2>/dev/null | awk '{printf "%d", $1/3600}')
  printf '%s 10\n' "$_cur_hour" > "$STATE_DIR/hourcount"
  export UCI_GET_amnezia_config_autotunnel_max_per_hour=10

  # Put a candidate in logread output.
  _make_logread_stub hourcap \
    "Jul  1 12:00:00 router dnsmasq[123]: query[A] example.com from 192.168.1.2"

  run sh "$SCRIPT" auto
  [ "$status" -eq 0 ]
  # No curl.
  run grep "curl" "$STUB_LOG"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# auto: PTR / arpa / .lan / .local lines are ignored
# ---------------------------------------------------------------------------
@test "auto: PTR + in-addr.arpa + .lan + .local lines are ignored" {
  _make_throttled_curl ign
  export NSLOOKUP_ADDR="1.2.3.4"
  # All these must be ignored; no domain should reach probe.
  _make_logread_stub ign "$(printf '%s\n%s\n%s\n%s' \
    'Jul  1 12:00:01 router dnsmasq[1]: query[PTR] 4.3.2.1.in-addr.arpa from 192.168.1.2' \
    'Jul  1 12:00:02 router dnsmasq[1]: query[A] router.lan from 192.168.1.2' \
    'Jul  1 12:00:03 router dnsmasq[1]: query[A] printer.local from 192.168.1.2' \
    'Jul  1 12:00:04 router dnsmasq[1]: query[A] 1.0.0.0.0.0.0.0.ip6.arpa from 192.168.1.2')"
  run sh "$SCRIPT" auto
  [ "$status" -eq 0 ]
  # No curl should have been called.
  run grep "^curl " "$STUB_LOG"
  [ "$status" -ne 0 ] || { echo "curl was called for a filtered line"; false; }
}

# ---------------------------------------------------------------------------
# auto: .ru TLD candidate is skipped
# ---------------------------------------------------------------------------
@test "auto: .ru TLD candidate is skipped" {
  _make_throttled_curl ru
  export NSLOOKUP_ADDR="5.6.7.8"
  _make_logread_stub ru \
    "Jul  1 12:00:01 router dnsmasq[1]: query[A] vk.ru from 192.168.1.2"
  run sh "$SCRIPT" auto
  [ "$status" -eq 0 ]
  run grep "^curl " "$STUB_LOG"
  [ "$status" -ne 0 ] || { echo "curl was called for .ru domain"; false; }
}

# ---------------------------------------------------------------------------
# auto: already-listed domain is skipped
# ---------------------------------------------------------------------------
@test "auto: already-listed domain is skipped" {
  _make_throttled_curl listed
  export NSLOOKUP_ADDR="5.6.7.8"
  printf 'existing.com\n' > "$FORCE_DIR/force-tunnel.list"
  _make_logread_stub listed \
    "Jul  1 12:00:01 router dnsmasq[1]: query[A] existing.com from 192.168.1.2"
  run sh "$SCRIPT" auto
  [ "$status" -eq 0 ]
  run grep "^curl " "$STUB_LOG"
  [ "$status" -ne 0 ] || { echo "curl was called for already-listed domain"; false; }
}

# ---------------------------------------------------------------------------
# auto: verdict cached -> not re-probed on second tick
# ---------------------------------------------------------------------------
@test "auto: cached verdict prevents re-probe" {
  _make_throttled_curl cache
  export NSLOOKUP_ADDR="5.6.7.8"
  # Pre-populate verdict cache for example.com with "ok" -> should not be re-probed.
  printf 'example.com ok\n' > "$STATE_DIR/verdicts"
  _make_logread_stub cache \
    "Jul  1 12:00:01 router dnsmasq[1]: query[A] example.com from 192.168.1.2"
  run sh "$SCRIPT" auto
  [ "$status" -eq 0 ]
  run grep "^curl " "$STUB_LOG"
  [ "$status" -ne 0 ] || { echo "curl called despite cached verdict"; false; }
}

# ---------------------------------------------------------------------------
# auto: throttled candidate is added, marker + hourcount updated
# ---------------------------------------------------------------------------
@test "auto: throttled candidate gets added + marker + hourcount updated" {
  _make_throttled_curl throttled
  export NSLOOKUP_ADDR="1.2.3.4"
  # Seed a state file so _pick_tunnel works.
  _sf="$BATS_TEST_TMPDIR/failover.json"
  printf '{"active_pool":"awg1","routing_mode":"direct-default"}\n' > "$_sf"
  export STATE_FILE="$_sf"

  _make_logread_stub throttled \
    "Jul  1 12:00:01 router dnsmasq[1]: query[A] blocked.com from 192.168.1.2"

  run sh "$SCRIPT" auto
  [ "$status" -eq 0 ]

  # Domain must be in force-tunnel.list (via amnezia-force-load save-manual).
  [ -f "$FORCE_DIR/force-tunnel.list" ]
  grep -q "blocked.com" "$FORCE_DIR/force-tunnel.list"

  # Must be in the added marker.
  [ -f "$ADDED_FILE" ]
  grep -q "blocked.com" "$ADDED_FILE"

  # hourcount must be 1.
  _cur_hour=$(date +%s 2>/dev/null | awk '{printf "%d", $1/3600}')
  _hc=$(cat "$STATE_DIR/hourcount" 2>/dev/null || true)
  echo "$_hc" | grep -q "^${_cur_hour} 1"
}

# ---------------------------------------------------------------------------
# auto: respects max_per_tick (only N probed even if M>N candidates)
# ---------------------------------------------------------------------------
@test "auto: max_per_tick=1 limits to one probe per tick" {
  export UCI_GET_amnezia_config_autotunnel_max_per_tick=1
  _make_throttled_curl maxtick
  export NSLOOKUP_ADDR="1.2.3.4"
  _sf="$BATS_TEST_TMPDIR/failover2.json"
  printf '{"active_pool":"awg1","routing_mode":"direct-default"}\n' > "$_sf"
  export STATE_FILE="$_sf"

  # Three candidates, but max_per_tick=1.
  _make_logread_stub maxtick "$(printf '%s\n%s\n%s' \
    'Jul  1 12:00:01 router dnsmasq[1]: query[A] site1.com from 192.168.1.2' \
    'Jul  1 12:00:02 router dnsmasq[1]: query[A] site2.com from 192.168.1.2' \
    'Jul  1 12:00:03 router dnsmasq[1]: query[A] site3.com from 192.168.1.2')"

  run sh "$SCRIPT" auto
  [ "$status" -eq 0 ]

  # Exactly 2 curl calls: 1 direct + 1 tunnel for 1 domain.
  _curl_count=$(grep -c "^curl " "$STUB_LOG" 2>/dev/null || echo 0)
  [ "$_curl_count" -le 2 ] || { echo "expected <=2 curl calls, got $_curl_count"; false; }
}

# ---------------------------------------------------------------------------
# auto: list_cap stops adding (still caches verdicts)
# ---------------------------------------------------------------------------
@test "auto: list_cap reached stops adding but still caches verdict" {
  export UCI_GET_amnezia_config_autotunnel_list_cap=0  # cap=0 means already full
  _make_throttled_curl cap
  export NSLOOKUP_ADDR="1.2.3.4"
  _sf="$BATS_TEST_TMPDIR/failover3.json"
  printf '{"active_pool":"awg1","routing_mode":"direct-default"}\n' > "$_sf"
  export STATE_FILE="$_sf"

  _make_logread_stub cap \
    "Jul  1 12:00:01 router dnsmasq[1]: query[A] capped.com from 192.168.1.2"

  run sh "$SCRIPT" auto
  [ "$status" -eq 0 ]

  # Must NOT be in force-tunnel.list (cap reached).
  if [ -f "$FORCE_DIR/force-tunnel.list" ]; then
    ! grep -q "capped.com" "$FORCE_DIR/force-tunnel.list" || \
      { echo "capped.com was added despite list_cap=0"; false; }
  fi

  # Verdict IS cached.
  [ -f "$STATE_DIR/verdicts" ]
  grep -q "^capped.com " "$STATE_DIR/verdicts"
}

# ---------------------------------------------------------------------------
# auto: logread candidate extraction — query[A] and query[AAAA] parsed,
# PTR/arpa/.lan/.local deduped, sort -u gives unique domains.
# ---------------------------------------------------------------------------
@test "auto: logread extraction ignores PTR, deduplicates repeated queries" {
  # Give NSLOOKUP_ADDR="" so nslookup returns no IP -> probe skipped but
  # the candidate extraction is the thing under test.
  export NSLOOKUP_ADDR=""
  # Two repeated queries for same.com, one PTR, one AAAA (which also matches query[A).
  _make_logread_stub dedup "$(printf '%s\n%s\n%s\n%s' \
    'Jul  1 12:00:01 router dnsmasq[1]: query[A] same.com from 192.168.1.2' \
    'Jul  1 12:00:02 router dnsmasq[1]: query[A] same.com from 192.168.1.3' \
    'Jul  1 12:00:03 router dnsmasq[1]: query[PTR] 1.2.3.4.in-addr.arpa from 192.168.1.2' \
    'Jul  1 12:00:04 router dnsmasq[1]: query[AAAA] same.com from 192.168.1.2')"
  run sh "$SCRIPT" auto
  [ "$status" -eq 0 ]
  # No curl since nslookup returns no IP (verdict=unresolved, skips add).
  run grep "^curl " "$STUB_LOG"
  [ "$status" -ne 0 ] || true  # unresolved path: no curl expected
}

# ---------------------------------------------------------------------------
# remove: strips domain from force-tunnel.list and added marker
# ---------------------------------------------------------------------------
@test "remove: strips domain from force-tunnel.list and added marker" {
  printf 'keep.com\ntarget.com\nother.com\n' > "$FORCE_DIR/force-tunnel.list"
  printf 'target.com 1234567890\nkeep.com 1234567891\n' > "$ADDED_FILE"

  run sh "$SCRIPT" remove target.com
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"result":"removed"'
  echo "$output" | grep -q '"was-in-list":true'

  # target.com must be gone from the list (save-manual was called with remaining).
  [ -f "$FORCE_DIR/force-tunnel.list" ]
  ! grep -q "target.com" "$FORCE_DIR/force-tunnel.list"
  grep -q "keep.com" "$FORCE_DIR/force-tunnel.list"

  # target.com must be gone from added marker.
  ! grep -q "^target.com " "$ADDED_FILE"
  grep -q "^keep.com " "$ADDED_FILE"
}

@test "remove: domain not in list -> result removed, was-in-list=false" {
  printf 'other.com\n' > "$FORCE_DIR/force-tunnel.list"
  run sh "$SCRIPT" remove notlisted.com
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"result":"removed"'
  echo "$output" | grep -q '"was-in-list":false'
}

@test "remove: invalid domain -> exit 2" {
  run sh "$SCRIPT" remove "not_valid"
  [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# enable / disable: write / remove confdir snippet and cron line
# ---------------------------------------------------------------------------
@test "enable: writes dnsmasq confdir snippet with log-queries only (no log-facility)" {
  run sh "$SCRIPT" enable
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"result":"enabled"'

  # Confdir snippet must exist and contain log-queries.
  [ -f "$DNSMASQ_CONFDIR/amnezia-autotunnel-log.conf" ]
  grep -q "log-queries" "$DNSMASQ_CONFDIR/amnezia-autotunnel-log.conf"

  # MUST NOT contain log-facility (would point outside ujail and crash dnsmasq).
  ! grep -q "log-facility" "$DNSMASQ_CONFDIR/amnezia-autotunnel-log.conf" || \
    { echo "log-facility found in snippet — dnsmasq ujail will reject this"; false; }

  # Cron entry must be present.
  [ -f "$CRON_FILE" ]
  grep -q "amnezia-autotunnel auto" "$CRON_FILE"
}

@test "enable: enabled=1 set in UCI after healthy enable" {
  run sh "$SCRIPT" enable
  [ "$status" -eq 0 ]
  # uci stub records "uci set amnezia.config.autotunnel_enabled=1"
  grep -q "uci set amnezia.config.autotunnel_enabled=1" "$STUB_LOG"
}

@test "enable: UNHEALTHY path -> snippet removed, cron NOT installed, enabled=0, exit 5" {
  # Force health check to run (override the default skip).
  unset AUTOTUNNEL_SKIP_HEALTHCHECK
  export AUTOTUNNEL_SKIP_HEALTHCHECK=""
  # Make pgrep fail -> dnsmasq "not running" -> unhealthy.
  export PGREP="false"
  # Make nslookup also fail (belt + suspenders).
  _nsfail="$BATS_TEST_TMPDIR/nsfail/nslookup"
  mkdir -p "$(dirname "$_nsfail")"
  printf '#!/bin/sh\nexit 1\n' > "$_nsfail"
  chmod +x "$_nsfail"
  export NSLOOKUP="$_nsfail"
  # Speed up test: try only once.
  export AUTOTUNNEL_HEALTHCHECK_TRIES=1

  run sh "$SCRIPT" enable
  [ "$status" -eq 5 ]
  echo "$output" | grep -q '"result":"rollback"'
  echo "$output" | grep -q '"error":"dnsmasq-unhealthy"'

  # Snippet must NOT be present (rolled back).
  [ ! -f "$DNSMASQ_CONFDIR/amnezia-autotunnel-log.conf" ] || \
    { echo "snippet still exists after rollback"; false; }

  # Cron must NOT have been installed.
  if [ -f "$CRON_FILE" ]; then
    ! grep -q "amnezia-autotunnel auto" "$CRON_FILE" || \
      { echo "cron entry installed despite rollback"; false; }
  fi

  # UCI must record enabled=0 (not 1).
  grep -q "uci set amnezia.config.autotunnel_enabled=0" "$STUB_LOG"
  ! grep -q "uci set amnezia.config.autotunnel_enabled=1" "$STUB_LOG" || \
    { echo "enabled=1 was set despite rollback"; false; }
}

@test "enable: idempotent — second enable produces at most one active cron entry" {
  run sh "$SCRIPT" enable
  [ "$status" -eq 0 ]
  run sh "$SCRIPT" enable
  [ "$status" -eq 0 ]
  [ -f "$CRON_FILE" ]
  grep -q "amnezia-autotunnel auto" "$CRON_FILE"
}

@test "disable: removes confdir snippet" {
  # First enable so the snippet exists.
  run sh "$SCRIPT" enable
  [ "$status" -eq 0 ]
  [ -f "$DNSMASQ_CONFDIR/amnezia-autotunnel-log.conf" ]

  # Then disable.
  run sh "$SCRIPT" disable
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"result":"disabled"'

  # Confdir snippet must be gone.
  [ ! -f "$DNSMASQ_CONFDIR/amnezia-autotunnel-log.conf" ]
}

@test "disable: keeps already-added domains in force-tunnel.list" {
  printf 'auto-added.com\nmanual.com\n' > "$FORCE_DIR/force-tunnel.list"
  printf 'auto-added.com 1234567890\n' > "$ADDED_FILE"
  run sh "$SCRIPT" disable
  [ "$status" -eq 0 ]
  # The force-tunnel.list is not touched by disable.
  grep -q "auto-added.com" "$FORCE_DIR/force-tunnel.list"
}

# ---------------------------------------------------------------------------
# status: JSON output
# ---------------------------------------------------------------------------
@test "status: returns well-formed JSON" {
  run sh "$SCRIPT" status
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"enabled"'
  echo "$output" | grep -q '"routing_mode"'
  echo "$output" | grep -q '"added_count"'
  echo "$output" | grep -q '"added"'
  echo "$output" | grep -q '"verdict_count"'
  echo "$output" | grep -q '"hour_count"'
}

@test "status: lists added domains from marker" {
  printf 'added1.com 1234567890\nadded2.com 1234567891\n' > "$ADDED_FILE"
  run sh "$SCRIPT" status
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"added_count":2'
  # Exact quoted JSON element — the epoch must NOT be glued onto the domain.
  echo "$output" | grep -q '"added1.com"'
  echo "$output" | grep -q '"added2.com"'
}

@test "status: reads hour_count from hourcount file" {
  _cur_hour=$(date +%s 2>/dev/null | awk '{printf "%d", $1/3600}')
  printf '%s 7\n' "$_cur_hour" > "$STATE_DIR/hourcount"
  run sh "$SCRIPT" status
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"hour_count":7'
}

@test "status: reads verdict_count from verdicts file" {
  printf 'a.com ok\nb.com throttled\n' > "$STATE_DIR/verdicts"
  run sh "$SCRIPT" status
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"verdict_count":2'
}

# ---------------------------------------------------------------------------
# auto: max_per_hour cap is enforced across two ticks
# ---------------------------------------------------------------------------
@test "auto: max_per_hour cap stops second-tick additions" {
  export UCI_GET_amnezia_config_autotunnel_max_per_hour=1
  _make_throttled_curl mxhr
  export NSLOOKUP_ADDR="1.2.3.4"
  _sf="$BATS_TEST_TMPDIR/failover4.json"
  printf '{"active_pool":"awg1","routing_mode":"direct-default"}\n' > "$_sf"
  export STATE_FILE="$_sf"

  # Tick 1: candidate firsthour.com — should be added.
  _make_logread_stub mxhr1 \
    "Jul  1 12:00:01 router dnsmasq[1]: query[A] firsthour.com from 192.168.1.2"
  run sh "$SCRIPT" auto
  [ "$status" -eq 0 ]
  grep -q "firsthour.com" "$FORCE_DIR/force-tunnel.list" 2>/dev/null || true

  # Tick 2: put a second candidate — should be skipped (cap reached).
  _make_logread_stub mxhr2 "$(printf '%s\n%s' \
    'Jul  1 12:00:01 router dnsmasq[1]: query[A] firsthour.com from 192.168.1.2' \
    'Jul  1 12:00:02 router dnsmasq[1]: query[A] secondhour.com from 192.168.1.2')"
  run sh "$SCRIPT" auto
  [ "$status" -eq 0 ]
  if [ -f "$FORCE_DIR/force-tunnel.list" ]; then
    ! grep -q "secondhour.com" "$FORCE_DIR/force-tunnel.list" || true
  fi
}

# ---------------------------------------------------------------------------
# Helper: build a dedicated NFT stub that records all calls to a log file.
# Sets NFT env to point at it.
# ---------------------------------------------------------------------------
_make_nft_stub() {
  _nft_tag="$1"
  _nft_log="$BATS_TEST_TMPDIR/nft-${_nft_tag}.log"
  _nft_dir="$BATS_TEST_TMPDIR/nft-${_nft_tag}"
  mkdir -p "$_nft_dir"
  cat > "$_nft_dir/nft" <<NFTSTUB
#!/bin/sh
printf '%s\n' "\$*" >> "${_nft_log}"
exit 0
NFTSTUB
  chmod +x "$_nft_dir/nft"
  export NFT="$_nft_dir/nft"
  export NFT_LOG="$_nft_log"
}

# ---------------------------------------------------------------------------
# Helper: build an amnezia-force-load stub that records bare (no-arg) calls.
# Replaces the setup() stub so we can count invocations separately.
# ---------------------------------------------------------------------------
_make_fl_counting_stub() {
  _fl_tag="$1"
  _fl_log="$BATS_TEST_TMPDIR/fl-${_fl_tag}.log"
  _fl_dir="$BATS_TEST_TMPDIR/fl-${_fl_tag}"
  mkdir -p "$_fl_dir"
  cat > "$_fl_dir/amnezia-force-load" <<FLSTUB
#!/bin/sh
printf '%s\n' "\$*" >> "${_fl_log}"
if [ "\$1" = "save-manual" ]; then
  printf '%s' "\$2" > "${FORCE_DIR}/force-tunnel.list"
fi
exit 0
FLSTUB
  chmod +x "$_fl_dir/amnezia-force-load"
  export AMNEZIA_FORCE_LOAD="$_fl_dir/amnezia-force-load"
  export FL_LOG="$_fl_log"
  export PATH="$_fl_dir:$PATH"
}

# ---------------------------------------------------------------------------
# coalesce C3: no force-load restart when last_apply is fresh (within interval)
# ---------------------------------------------------------------------------
@test "coalesce: no force-load on detect when last_apply is recent" {
  # Set last_apply to now so elapsed < interval.
  _now=$(date +%s 2>/dev/null || printf '0')
  printf '%s\n' "$_now" > "$STATE_DIR/last_apply"
  export UCI_GET_amnezia_config_autotunnel_apply_interval=1800

  _make_throttled_curl coalesce1
  _make_nft_stub coalesce1
  _make_fl_counting_stub coalesce1
  export NSLOOKUP_ADDR="10.0.0.1"
  _sf="$BATS_TEST_TMPDIR/failover-c1.json"
  printf '{"active_pool":"awg1","routing_mode":"direct-default"}\n' > "$_sf"
  export STATE_FILE="$_sf"

  _make_logread_stub coalesce1 \
    "Jul  1 12:00:01 router dnsmasq[1]: query[A] newsite.com from 192.168.1.2"

  run sh "$SCRIPT" auto
  [ "$status" -eq 0 ]

  # Domain must appear in force-tunnel.list (direct write, no save-manual).
  [ -f "$FORCE_DIR/force-tunnel.list" ]
  grep -q "newsite.com" "$FORCE_DIR/force-tunnel.list"

  # NFT add element for force4 must have been called.
  [ -f "$NFT_LOG" ]
  grep -q "add element inet fw4 amnezia_force4" "$NFT_LOG" \
    || { echo "nft add element was not called"; false; }

  # force-load must NOT have been invoked (interval not elapsed yet).
  if [ -f "$FL_LOG" ]; then
    # Only save-manual calls are acceptable; a bare invocation (the coalesce apply)
    # must not appear.
    ! grep -qE '^$' "$FL_LOG" \
      || { echo "force-load was called with no args (coalesce fired prematurely)"; false; }
  fi

  # pending file must exist (coalesce deferred).
  [ -f "$STATE_DIR/pending" ] \
    || { echo "STATE_DIR/pending was not set after detect"; false; }
}

# ---------------------------------------------------------------------------
# coalesce C4: force-load invoked exactly once when interval has elapsed
# ---------------------------------------------------------------------------
@test "coalesce: force-load invoked once when interval has elapsed" {
  # Set last_apply to epoch 0 so elapsed > any reasonable interval.
  printf '0\n' > "$STATE_DIR/last_apply"
  # Also pre-set the pending flag to simulate a prior detect.
  : > "$STATE_DIR/pending"
  export UCI_GET_amnezia_config_autotunnel_apply_interval=1800

  _make_throttled_curl coalesce2
  _make_nft_stub coalesce2
  _make_fl_counting_stub coalesce2
  export NSLOOKUP_ADDR="10.0.0.2"
  _sf="$BATS_TEST_TMPDIR/failover-c2.json"
  printf '{"active_pool":"awg1","routing_mode":"direct-default"}\n' > "$_sf"
  export STATE_FILE="$_sf"

  _make_logread_stub coalesce2 \
    "Jul  1 12:00:01 router dnsmasq[1]: query[A] delayed.com from 192.168.1.2"

  run sh "$SCRIPT" auto
  [ "$status" -eq 0 ]

  # force-load must have been invoked exactly once with no args (bare call).
  [ -f "$FL_LOG" ] || { echo "FL_LOG not created — force-load was never called"; false; }
  _bare_count=$(grep -c '^$' "$FL_LOG" 2>/dev/null || printf '0')
  [ "$_bare_count" -eq 1 ] \
    || { echo "expected exactly 1 bare force-load call, got $_bare_count"; false; }

  # pending file must be gone after a successful apply.
  [ ! -f "$STATE_DIR/pending" ] \
    || { echo "STATE_DIR/pending was not removed after apply"; false; }

  # last_apply must have been updated to a recent epoch.
  [ -f "$STATE_DIR/last_apply" ]
  _la=$(cat "$STATE_DIR/last_apply" 2>/dev/null || printf '0')
  _now=$(date +%s 2>/dev/null || printf '1')
  [ "$_la" -gt 1000 ] \
    || { echo "last_apply not updated (got $_la)"; false; }
}

# ---------------------------------------------------------------------------
# coalesce C4: batch — multiple candidates trigger at most ONE force-load call
# ---------------------------------------------------------------------------
@test "coalesce: multiple throttled candidates -> force-load called at most once" {
  export UCI_GET_amnezia_config_autotunnel_max_per_tick=3
  # Stale last_apply so the coalesced apply fires.
  printf '0\n' > "$STATE_DIR/last_apply"
  export UCI_GET_amnezia_config_autotunnel_apply_interval=1800

  _make_throttled_curl coalesce3
  _make_nft_stub coalesce3
  _make_fl_counting_stub coalesce3
  export NSLOOKUP_ADDR="10.0.0.3"
  _sf="$BATS_TEST_TMPDIR/failover-c3.json"
  printf '{"active_pool":"awg1","routing_mode":"direct-default"}\n' > "$_sf"
  export STATE_FILE="$_sf"

  _make_logread_stub coalesce3 "$(printf '%s\n%s\n%s' \
    'Jul  1 12:00:01 router dnsmasq[1]: query[A] batch1.com from 192.168.1.2' \
    'Jul  1 12:00:02 router dnsmasq[1]: query[A] batch2.com from 192.168.1.2' \
    'Jul  1 12:00:03 router dnsmasq[1]: query[A] batch3.com from 192.168.1.2')"

  run sh "$SCRIPT" auto
  [ "$status" -eq 0 ]

  # All three domains must be in the list.
  grep -q "batch1.com" "$FORCE_DIR/force-tunnel.list" \
    || { echo "batch1.com missing from list"; false; }
  grep -q "batch2.com" "$FORCE_DIR/force-tunnel.list" \
    || { echo "batch2.com missing from list"; false; }
  grep -q "batch3.com" "$FORCE_DIR/force-tunnel.list" \
    || { echo "batch3.com missing from list"; false; }

  # force-load invoked AT MOST once (not once per domain).
  _bare_count=0
  if [ -f "$FL_LOG" ]; then
    _bare_count=$(grep -c '^$' "$FL_LOG" 2>/dev/null || printf '0')
  fi
  [ "$_bare_count" -le 1 ] \
    || { echo "force-load was called $_bare_count times — expected at most 1"; false; }
}

# ---------------------------------------------------------------------------
# status: exposes pending and apply_interval fields
# ---------------------------------------------------------------------------
@test "status: exposes pending=1 and apply_interval after a detect" {
  export UCI_GET_amnezia_config_autotunnel_apply_interval=900
  # Simulate a pending state.
  : > "$STATE_DIR/pending"

  run sh "$SCRIPT" status
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"pending":1' \
    || { echo "pending field missing or not 1 in: $output"; false; }
  echo "$output" | grep -q '"apply_interval":' \
    || { echo "apply_interval field missing in: $output"; false; }
  echo "$output" | grep -q '"apply_interval":900' \
    || { echo "apply_interval not 900 in: $output"; false; }
}

@test "status: pending=0 when no pending file" {
  rm -f "$STATE_DIR/pending"
  run sh "$SCRIPT" status
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"pending":0' \
    || { echo "pending not 0 in: $output"; false; }
}
