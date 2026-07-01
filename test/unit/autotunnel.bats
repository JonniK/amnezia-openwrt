#!/usr/bin/env bats
# Tests for amnezia-autotunnel.sh
load '../lib/harness.bash'
SCRIPT="$HARNESS_DIR/../openwrt/amnezia-autotunnel.sh"

setup() {
  export AMNEZIA_LIB="$HARNESS_DIR/../openwrt/lib"
  export FORCE_DIR="$BATS_TEST_TMPDIR/amnezia"
  mkdir -p "$FORCE_DIR"
  export RESOLVER="127.0.0.1"
  # Override curl/nslookup to use test stubs on PATH (already on PATH via harness.bash).
  export CURL="curl"
  export NSLOOKUP="nslookup"
  export PROBE_MAXTIME="8"
  # Suppress dnsmasq HUP in all tests (pgrep stub returns nothing; kill is a no-op anyway).
  export DNSMASQ_HUP="0"
  # Stub amnezia-force-load (on PATH via stubs/).
  export AMNEZIA_FORCE_LOAD="amnezia-force-load"
  # Default: master enabled.
  export UCI_GET_amnezia_config_master_enabled=1
  # Default: no pre-existing force-tunnel list.
  : > "$STUB_LOG"
}

# ---------------------------------------------------------------------------
# Helper: write a state JSON with active_pool.
# ---------------------------------------------------------------------------
_write_state() {
  _pool="${1:-awg1}"
  _sf="$BATS_TEST_TMPDIR/amnezia-failover.json"
  printf '{"active_pool":"%s","routing_mode":"tunnel-default"}\n' "$_pool" > "$_sf"
  export STATE_FILE="$_sf"
}

# ---------------------------------------------------------------------------
# probe: verdict = throttled (direct 000, tunnel 200)
# ---------------------------------------------------------------------------
@test "probe: direct 000, tunnel 200 -> verdict throttled" {
  _write_state awg1
  # nslookup stub returns 1.2.3.4 when NSLOOKUP_ADDR is set.
  export NSLOOKUP_ADDR="1.2.3.4"
  # curl stub: we need different behaviour per invocation.
  # Use CURL_STUB_THROTTLED env: when set, direct probe returns 000 and tunnel returns 200.
  # We use a custom stub script to achieve this.
  _stub_dir="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$_stub_dir"
  cat > "$_stub_dir/curl" <<'CURLSTUB'
#!/bin/sh
echo "curl $*" >> "${STUB_LOG:-/dev/null}"
# Check if --interface arg is present (tunnel probe).
_has_iface=0
for _a in "$@"; do case "$_a" in awg*) _has_iface=1; break ;; esac; done
if [ "$_has_iface" = "1" ]; then
  # Tunnel probe: return 200 with fast time.
  printf '200 0.200'
else
  # Direct probe: return 000 (failure).
  printf '000 0.000'
fi
CURLSTUB
  chmod +x "$_stub_dir/curl"
  export CURL="$_stub_dir/curl"

  run sh "$SCRIPT" probe example.com
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"verdict":"throttled"'
  echo "$output" | grep -q '"domain":"example.com"'
}

# ---------------------------------------------------------------------------
# probe: verdict = throttled (direct slow 6s, tunnel 0.5s)
# Both responses succeed but direct is slow.
# ---------------------------------------------------------------------------
@test "probe: direct slow (6s), tunnel fast (0.5s) -> verdict throttled" {
  _write_state awg1
  export NSLOOKUP_ADDR="1.2.3.4"
  _stub_dir="$BATS_TEST_TMPDIR/stubs2"
  mkdir -p "$_stub_dir"
  cat > "$_stub_dir/curl" <<'CURLSTUB'
#!/bin/sh
echo "curl $*" >> "${STUB_LOG:-/dev/null}"
_has_iface=0
for _a in "$@"; do case "$_a" in awg*) _has_iface=1; break ;; esac; done
if [ "$_has_iface" = "1" ]; then
  # Tunnel probe: 200 at 0.5s.
  printf '200 0.500'
else
  # Direct probe: 200 but slow (6s -> well above 3*0.5=1.5, min threshold 1.5).
  printf '200 6.000'
fi
CURLSTUB
  chmod +x "$_stub_dir/curl"
  export CURL="$_stub_dir/curl"

  run sh "$SCRIPT" probe example.com
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"verdict":"throttled"'
}

# ---------------------------------------------------------------------------
# probe: verdict = ok (direct 0.4s, tunnel 0.5s)
# Both ok, direct is NOT slower than max(1.5, 3*0.5=1.5). 0.4 < 1.5 -> ok.
# ---------------------------------------------------------------------------
@test "probe: direct fast (0.4s), tunnel (0.5s) -> verdict ok" {
  _write_state awg1
  export NSLOOKUP_ADDR="1.2.3.4"
  _stub_dir="$BATS_TEST_TMPDIR/stubs3"
  mkdir -p "$_stub_dir"
  cat > "$_stub_dir/curl" <<'CURLSTUB'
#!/bin/sh
echo "curl $*" >> "${STUB_LOG:-/dev/null}"
_has_iface=0
for _a in "$@"; do case "$_a" in awg*) _has_iface=1; break ;; esac; done
if [ "$_has_iface" = "1" ]; then
  printf '200 0.500'
else
  printf '200 0.400'
fi
CURLSTUB
  chmod +x "$_stub_dir/curl"
  export CURL="$_stub_dir/curl"

  run sh "$SCRIPT" probe example.com
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"verdict":"ok"'
}

# ---------------------------------------------------------------------------
# probe: verdict = tunnel-down (tunnel 000)
# ---------------------------------------------------------------------------
@test "probe: all tunnel attempts return 000 -> verdict tunnel-down" {
  # No state file -> uses fallback awg1/awg2/awg3 probes.
  unset STATE_FILE
  export NSLOOKUP_ADDR="1.2.3.4"
  _stub_dir="$BATS_TEST_TMPDIR/stubs4"
  mkdir -p "$_stub_dir"
  cat > "$_stub_dir/curl" <<'CURLSTUB'
#!/bin/sh
echo "curl $*" >> "${STUB_LOG:-/dev/null}"
# All probes return 000 (both direct and tunnel).
printf '000 0.000'
CURLSTUB
  chmod +x "$_stub_dir/curl"
  export CURL="$_stub_dir/curl"

  run sh "$SCRIPT" probe example.com
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"verdict":"tunnel-down"'
}

# ---------------------------------------------------------------------------
# probe: unresolved domain
# ---------------------------------------------------------------------------
@test "probe: nslookup returns no address -> verdict unresolved" {
  export NSLOOKUP_ADDR=""
  run sh "$SCRIPT" probe unresolvable.example.invalid
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"verdict":"unresolved"'
}

# ---------------------------------------------------------------------------
# probe: invalid domain -> exit 2 with JSON error
# ---------------------------------------------------------------------------
@test "probe: invalid domain exits 2 with error JSON" {
  run sh "$SCRIPT" probe "not_a_domain"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q '"error":"invalid domain"'
}

@test "probe: domain starting with dot exits 2" {
  run sh "$SCRIPT" probe ".example.com"
  [ "$status" -eq 2 ]
}

@test "probe: domain ending with dash exits 2" {
  # String ending in '-' violates the constraint (no dot either, but '-' is the focus here).
  run sh "$SCRIPT" probe "example.com-"
  [ "$status" -eq 2 ]
}

@test "probe: domain with no dot exits 2" {
  run sh "$SCRIPT" probe "localhost"
  [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# add: appends + dedups + passes FULL list to save-manual
# ---------------------------------------------------------------------------
@test "add: appends domain and deduplicates via save-manual" {
  # Pre-seed the force-tunnel list with an existing domain.
  printf 'existing.com\nanother.org\n' > "$FORCE_DIR/force-tunnel.list"

  export NSLOOKUP_ADDR="5.6.7.8"
  # Make probe return throttled (direct 000, tunnel 200).
  _stub_dir="$BATS_TEST_TMPDIR/stubs5"
  mkdir -p "$_stub_dir"
  cat > "$_stub_dir/curl" <<'CURLSTUB'
#!/bin/sh
echo "curl $*" >> "${STUB_LOG:-/dev/null}"
_has_iface=0
for _a in "$@"; do case "$_a" in awg*) _has_iface=1; break ;; esac; done
[ "$_has_iface" = "1" ] && printf '200 0.300' || printf '000 0.000'
CURLSTUB
  chmod +x "$_stub_dir/curl"
  export CURL="$_stub_dir/curl"

  # Capture what save-manual receives by wrapping amnezia-force-load.
  _stub_dir2="$BATS_TEST_TMPDIR/fl-capture"
  mkdir -p "$_stub_dir2"
  _capture_file="$BATS_TEST_TMPDIR/save-manual-arg.txt"
  cat > "$_stub_dir2/amnezia-force-load" <<FLSTUB
#!/bin/sh
echo "amnezia-force-load \$*" >> "\${STUB_LOG:-/dev/null}"
if [ "\$1" = "save-manual" ]; then
  printf '%s' "\$2" > "$_capture_file"
fi
exit 0
FLSTUB
  chmod +x "$_stub_dir2/amnezia-force-load"
  export AMNEZIA_FORCE_LOAD="$_stub_dir2/amnezia-force-load"

  run sh "$SCRIPT" add newdomain.com
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"result":"added"'

  # The save-manual arg must contain all old lines + the new domain.
  [ -f "$_capture_file" ] || { echo "save-manual capture file missing"; false; }
  grep -q "existing.com" "$_capture_file"
  grep -q "another.org" "$_capture_file"
  grep -q "newdomain.com" "$_capture_file"
}

@test "add: passes full existing list + new domain to save-manual (full-list passthrough)" {
  # Pre-seed the list with two domains that differ from the new one.
  printf 'existing.com\nanother.org\n' > "$FORCE_DIR/force-tunnel.list"

  export NSLOOKUP_ADDR="5.6.7.8"
  _stub_dir="$BATS_TEST_TMPDIR/stubs6"
  mkdir -p "$_stub_dir"
  cat > "$_stub_dir/curl" <<'CURLSTUB'
#!/bin/sh
echo "curl $*" >> "${STUB_LOG:-/dev/null}"
_has_iface=0
for _a in "$@"; do case "$_a" in awg*) _has_iface=1; break ;; esac; done
[ "$_has_iface" = "1" ] && printf '200 0.300' || printf '000 0.000'
CURLSTUB
  chmod +x "$_stub_dir/curl"
  export CURL="$_stub_dir/curl"

  _capture_file="$BATS_TEST_TMPDIR/full-list-capture.txt"
  _stub_dir2="$BATS_TEST_TMPDIR/fl-full"
  mkdir -p "$_stub_dir2"
  cat > "$_stub_dir2/amnezia-force-load" <<FLSTUB
#!/bin/sh
echo "amnezia-force-load \$*" >> "\${STUB_LOG:-/dev/null}"
if [ "\$1" = "save-manual" ]; then
  printf '%s' "\$2" > "$_capture_file"
fi
exit 0
FLSTUB
  chmod +x "$_stub_dir2/amnezia-force-load"
  export AMNEZIA_FORCE_LOAD="$_stub_dir2/amnezia-force-load"

  run sh "$SCRIPT" add brandnew.com
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"result":"added"'

  # The save-manual arg must include the pre-existing domains AND the new one.
  [ -f "$_capture_file" ] || { echo "capture file missing"; false; }
  grep -q "existing.com" "$_capture_file"
  grep -q "another.org" "$_capture_file"
  grep -q "brandnew.com" "$_capture_file"
  # brandnew.com must appear exactly once.
  _count=$(grep -c "brandnew.com" "$_capture_file" 2>/dev/null || echo 0)
  [ "$_count" -eq 1 ] || { echo "brandnew.com appears $_count times; content: $(cat $_capture_file)"; false; }
}

# ---------------------------------------------------------------------------
# add: respects --force (adds an "ok" domain)
# ---------------------------------------------------------------------------
@test "add --force: skips probe and adds domain regardless of verdict" {
  export NSLOOKUP_ADDR="9.9.9.9"
  _stub_dir="$BATS_TEST_TMPDIR/stubs7"
  mkdir -p "$_stub_dir"
  cat > "$_stub_dir/curl" <<'CURLSTUB'
#!/bin/sh
echo "curl $*" >> "${STUB_LOG:-/dev/null}"
# Both return 200 fast -> would normally be "ok" and not added.
printf '200 0.300'
CURLSTUB
  chmod +x "$_stub_dir/curl"
  export CURL="$_stub_dir/curl"

  _capture_file="$BATS_TEST_TMPDIR/force-capture.txt"
  _stub_dir2="$BATS_TEST_TMPDIR/fl-force"
  mkdir -p "$_stub_dir2"
  cat > "$_stub_dir2/amnezia-force-load" <<FLSTUB
#!/bin/sh
echo "amnezia-force-load \$*" >> "\${STUB_LOG:-/dev/null}"
if [ "\$1" = "save-manual" ]; then printf '%s' "\$2" > "$_capture_file"; fi
exit 0
FLSTUB
  chmod +x "$_stub_dir2/amnezia-force-load"
  export AMNEZIA_FORCE_LOAD="$_stub_dir2/amnezia-force-load"

  run sh "$SCRIPT" add fastsite.com --force
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"result":"added"'
  [ -f "$_capture_file" ]
  grep -q "fastsite.com" "$_capture_file"
}

# ---------------------------------------------------------------------------
# add: rejects invalid domain (exit 2)
# ---------------------------------------------------------------------------
@test "add: invalid domain exits 2" {
  run sh "$SCRIPT" add "not_a_domain"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q '"error":"invalid domain"'
}

# ---------------------------------------------------------------------------
# add: already-present path
# ---------------------------------------------------------------------------
@test "add: domain already in list -> result already-present, exit 0" {
  printf 'existing.com\ntarget.com\n' > "$FORCE_DIR/force-tunnel.list"
  # No curl needed (short-circuit before probe).
  run sh "$SCRIPT" add target.com
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"result":"already-present"'
  # save-manual must NOT have been called.
  run grep "save-manual" "$STUB_LOG"
  [ "$status" -ne 0 ] || { echo "save-manual was unexpectedly called for already-present domain"; false; }
}

# ---------------------------------------------------------------------------
# add: master-disabled gate (exit 3)
# ---------------------------------------------------------------------------
@test "add: master disabled -> error master-disabled, exit 3" {
  export UCI_GET_amnezia_config_master_enabled=0
  run sh "$SCRIPT" add example.com
  [ "$status" -eq 3 ]
  echo "$output" | grep -q '"error":"master-disabled"'
}

# ---------------------------------------------------------------------------
# add: probe returns ok (without --force) -> not added
# ---------------------------------------------------------------------------
@test "add: probe verdict ok without --force -> result not-added, exit 0" {
  export NSLOOKUP_ADDR="1.2.3.4"
  _write_state awg1
  _stub_dir="$BATS_TEST_TMPDIR/stubs8"
  mkdir -p "$_stub_dir"
  cat > "$_stub_dir/curl" <<'CURLSTUB'
#!/bin/sh
echo "curl $*" >> "${STUB_LOG:-/dev/null}"
# Both direct and tunnel return 200 fast -> verdict ok.
printf '200 0.300'
CURLSTUB
  chmod +x "$_stub_dir/curl"
  export CURL="$_stub_dir/curl"

  run sh "$SCRIPT" add fastsite.com
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"result":"not-added"'
  echo "$output" | grep -q '"verdict":"ok"'
}

# ---------------------------------------------------------------------------
# add: probe verdict tunnel-down -> not added, exit 4
# ---------------------------------------------------------------------------
@test "add: probe verdict tunnel-down -> result not-added, exit 4" {
  unset STATE_FILE
  export NSLOOKUP_ADDR="1.2.3.4"
  _stub_dir="$BATS_TEST_TMPDIR/stubs9"
  mkdir -p "$_stub_dir"
  cat > "$_stub_dir/curl" <<'CURLSTUB'
#!/bin/sh
echo "curl $*" >> "${STUB_LOG:-/dev/null}"
printf '000 0.000'
CURLSTUB
  chmod +x "$_stub_dir/curl"
  export CURL="$_stub_dir/curl"

  run sh "$SCRIPT" add blocked.com
  [ "$status" -eq 4 ]
  echo "$output" | grep -q '"verdict":"tunnel-down"'
  echo "$output" | grep -q '"result":"not-added"'
}
