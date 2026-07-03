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
  printf '200 0.200 500000 102400'
else
  # Direct probe: return 000 (failure).
  printf '000 0.000 0 0'
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
  printf '200 0.500 400000 200000'
else
  # Direct probe: 200 but slow (6s -> well above 3*0.5=1.5, min threshold 1.5).
  printf '200 6.000 5000 30000'
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
  printf '200 0.500 400000 200000'
else
  printf '200 0.400 500000 200000'
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
printf '000 0.000 0 0'
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
[ "$_has_iface" = "1" ] && printf '200 0.300 500000 150000' || printf '000 0.000 0 0'
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
[ "$_has_iface" = "1" ] && printf '200 0.300 500000 150000' || printf '000 0.000 0 0'
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
printf '200 0.300 500000 150000'
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
printf '200 0.300 500000 150000'
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
printf '000 0.000 0 0'
CURLSTUB
  chmod +x "$_stub_dir/curl"
  export CURL="$_stub_dir/curl"

  run sh "$SCRIPT" add blocked.com
  [ "$status" -eq 4 ]
  echo "$output" | grep -q '"verdict":"tunnel-down"'
  echo "$output" | grep -q '"result":"not-added"'
}

# ---------------------------------------------------------------------------
# verdict v2: stall scenario — direct exit 28 mid-body, tunnel completes -> throttled
# ---------------------------------------------------------------------------
@test "probe: direct exit 28 mid-body (stall), tunnel ok -> verdict throttled" {
  _write_state awg1
  export NSLOOKUP_ADDR="1.2.3.4"
  _stub_dir="$BATS_TEST_TMPDIR/stubs-stall"
  mkdir -p "$_stub_dir"
  cat > "$_stub_dir/curl" <<'CURLSTUB'
#!/bin/sh
echo "curl $*" >> "${STUB_LOG:-/dev/null}"
_has_iface=0
for _a in "$@"; do case "$_a" in awg*) _has_iface=1; break ;; esac; done
if [ "$_has_iface" = "1" ]; then
  # Tunnel completes cleanly.
  printf '200 1.000 500000 500000'
  exit 0
else
  # Direct: hits max-time mid-body (TSPU stall signature: partial 17KB, exit 28).
  printf '200 8.000 1024 17408'
  exit 28
fi
CURLSTUB
  chmod +x "$_stub_dir/curl"
  export CURL="$_stub_dir/curl"

  run sh "$SCRIPT" probe example.com
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"verdict":"throttled"'
}

# ---------------------------------------------------------------------------
# verdict v2: throughput scenario — direct 50KB/s, tunnel 500KB/s -> throttled
# ---------------------------------------------------------------------------
@test "probe: throughput rule — direct 50KB/s vs tunnel 500KB/s (100KB body) -> throttled" {
  _write_state awg1
  export NSLOOKUP_ADDR="1.2.3.4"
  _stub_dir="$BATS_TEST_TMPDIR/stubs-throughput"
  mkdir -p "$_stub_dir"
  cat > "$_stub_dir/curl" <<'CURLSTUB'
#!/bin/sh
echo "curl $*" >> "${STUB_LOG:-/dev/null}"
_has_iface=0
for _a in "$@"; do case "$_a" in awg*) _has_iface=1; break ;; esac; done
if [ "$_has_iface" = "1" ]; then
  # Tunnel: 100KB at 500KB/s; timing not throttled (th=max(1.5,3*0.8)=2.4, d=2.0<2.4).
  printf '200 0.800 512000 102400'
  exit 0
else
  # Direct: 100KB at 50KB/s; d_speed(51200) < t_speed/3(170666) -> throughput throttled.
  printf '200 2.000 51200 102400'
  exit 0
fi
CURLSTUB
  chmod +x "$_stub_dir/curl"
  export CURL="$_stub_dir/curl"

  run sh "$SCRIPT" probe example.com
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"verdict":"throttled"'
}

# ---------------------------------------------------------------------------
# verdict v2: tiny-body regression — small body must NOT trip throughput rule
# ---------------------------------------------------------------------------
@test "probe: tiny body (2KB) both fast -> verdict ok, throughput rule does not fire" {
  _write_state awg1
  export NSLOOKUP_ADDR="1.2.3.4"
  _stub_dir="$BATS_TEST_TMPDIR/stubs-tiny"
  mkdir -p "$_stub_dir"
  cat > "$_stub_dir/curl" <<'CURLSTUB'
#!/bin/sh
echo "curl $*" >> "${STUB_LOG:-/dev/null}"
# Both paths: small 403 body (2KB), fast; d_size=2048 < 65536 -> throughput rule skipped.
printf '403 0.300 10240 2048'
exit 0
CURLSTUB
  chmod +x "$_stub_dir/curl"
  export CURL="$_stub_dir/curl"

  run sh "$SCRIPT" probe example.com
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"verdict":"ok"'
}

# ---------------------------------------------------------------------------
# verdict v2: sample_url is passed through to curl
# ---------------------------------------------------------------------------
@test "probe: sample_url arg is forwarded to curl" {
  _write_state awg1
  export NSLOOKUP_ADDR="1.2.3.4"
  _stub_dir="$BATS_TEST_TMPDIR/stubs-sampleurl"
  mkdir -p "$_stub_dir"
  cat > "$_stub_dir/curl" <<'CURLSTUB'
#!/bin/sh
echo "curl $*" >> "${STUB_LOG:-/dev/null}"
_has_iface=0
for _a in "$@"; do case "$_a" in awg*) _has_iface=1; break ;; esac; done
if [ "$_has_iface" = "1" ]; then
  printf '200 0.300 500000 150000'
  exit 0
else
  printf '200 0.200 500000 150000'
  exit 0
fi
CURLSTUB
  chmod +x "$_stub_dir/curl"
  export CURL="$_stub_dir/curl"

  run sh "$SCRIPT" probe example.com "https://example.com/large-asset.js"
  [ "$status" -eq 0 ]
  # The sample URL must appear in the stub log (passed as curl target).
  grep -q "large-asset.js" "$STUB_LOG" \
    || { echo "sample_url not forwarded to curl; stub log: $(cat $STUB_LOG)"; false; }
}

# ---------------------------------------------------------------------------
# verdict v2: JSON contains the four new speed/size fields
# ---------------------------------------------------------------------------
@test "probe: JSON output contains d_speed, d_size, t_speed, t_size fields" {
  _write_state awg1
  export NSLOOKUP_ADDR="1.2.3.4"
  _stub_dir="$BATS_TEST_TMPDIR/stubs-json4"
  mkdir -p "$_stub_dir"
  cat > "$_stub_dir/curl" <<'CURLSTUB'
#!/bin/sh
echo "curl $*" >> "${STUB_LOG:-/dev/null}"
_has_iface=0
for _a in "$@"; do case "$_a" in awg*) _has_iface=1; break ;; esac; done
if [ "$_has_iface" = "1" ]; then
  printf '200 0.300 512000 102400'
  exit 0
else
  printf '200 0.250 600000 150000'
  exit 0
fi
CURLSTUB
  chmod +x "$_stub_dir/curl"
  export CURL="$_stub_dir/curl"

  run sh "$SCRIPT" probe example.com
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"d_speed":'
  echo "$output" | grep -q '"d_size":'
  echo "$output" | grep -q '"t_speed":'
  echo "$output" | grep -q '"t_size":'
  # Spot-check that numeric values are present (non-empty).
  echo "$output" | grep -qE '"d_speed":[0-9]+'
  echo "$output" | grep -qE '"d_size":[0-9]+'
}

# ===========================================================================
# probe-page and watch tests
# ===========================================================================

# ---------------------------------------------------------------------------
# Helper: build a per-test curl stub that handles both page-fetch (no -w flag)
# and probe-fetch (-w flag).  Accepts env vars:
#   PAGE_HTML_FILE  — path to the HTML fixture to echo for page fetches
#   CURL_DIRECT_OUT — 4-field string for direct probes (default: throttled)
#   CURL_TUNNEL_OUT — 4-field string for tunnel probes (default: fast)
# ---------------------------------------------------------------------------
_make_pp_curl_stub() {
  _stub_dir="$1"
  mkdir -p "$_stub_dir"
  cat > "$_stub_dir/curl" <<'CURLSTUB'
#!/bin/sh
echo "curl $*" >> "${STUB_LOG:-/dev/null}"
# Distinguish page-fetch (-s --max-time 15 ...) from probe-fetch (-w flag).
_has_w=0
for _a in "$@"; do case "$_a" in -w) _has_w=1; break ;; esac; done
if [ "$_has_w" = "0" ]; then
  # Page fetch: return HTML fixture if provided.
  if [ -n "${PAGE_HTML_FILE:-}" ] && [ -f "$PAGE_HTML_FILE" ]; then
    cat "$PAGE_HTML_FILE"
  fi
  exit 0
fi
# Probe fetch: check for --interface (tunnel) vs direct.
_has_iface=0
for _a in "$@"; do case "$_a" in awg*) _has_iface=1; break ;; esac; done
if [ "$_has_iface" = "1" ]; then
  printf '%s' "${CURL_TUNNEL_OUT:-200 0.200 500000 102400}"
else
  printf '%s' "${CURL_DIRECT_OUT:-000 0.000 0 0}"
fi
CURLSTUB
  chmod +x "$_stub_dir/curl"
}

# (a) probe-page harvest: 3 probed hosts + 1 forced, IP-literal excluded
@test "probe-page: harvests 3 hosts, excludes IP-literal, marks force-covered as forced" {
  _write_state awg1
  export NSLOOKUP_ADDR="1.2.3.4"

  # Force list: covers cdn.forced.com (entry "forced.com" suffix-matches it).
  mkdir -p "$FORCE_DIR"
  printf 'forced.com\n' > "$FORCE_DIR/force-tunnel.list"

  # HTML fixture: absolute https, protocol-relative, plain link, IP-literal, forced host.
  _html_f="$BATS_TEST_TMPDIR/page.html"
  cat > "$_html_f" <<'HTML'
<html><head>
<script src="https://js.example.com/app.js?v=1"></script>
<link rel="stylesheet" href="https://css.example.com/main.css">
<img src="//img.example.com/logo.png">
<script src="//cdn.forced.com/vendor.js"></script>
<a href="https://192.168.1.1/admin">admin</a>
<a href="https://other.example.com/page">other</a>
</head></html>
HTML
  export PAGE_HTML_FILE="$_html_f"

  _stub_dir="$BATS_TEST_TMPDIR/pp-stubs-a"
  _make_pp_curl_stub "$_stub_dir"
  export CURL="$_stub_dir/curl"

  run sh "$SCRIPT" probe-page "https://js.example.com/app.js"
  [ "$status" -eq 0 ] || { echo "output: $output"; false; }

  # 1 forced (cdn.forced.com covered by forced.com entry)
  echo "$output" | grep -q '"status":"forced"' \
    || { echo "missing forced: $output"; false; }
  # IP literal 192.168.1.1 must NOT appear in hosts array
  echo "$output" | grep -qF '"host":"192.168.1.1"' \
    && { echo "IP literal appeared in output: $output"; false; } || true
  # At least 3 probed hosts present
  _probed_count=$(echo "$output" | grep -o '"status":"probed"' | wc -l | tr -d ' ')
  [ "$_probed_count" -ge 3 ] \
    || { echo "expected >=3 probed, got $_probed_count: $output"; false; }
  # JSON has expected top-level fields
  echo "$output" | grep -q '"page_host":'
  echo "$output" | grep -q '"total":'
  echo "$output" | grep -q '"hosts":'
}

# (b) sample-url selection: asset URL (.js) is passed to curl for that host's probe
@test "probe-page: asset URL (.js) is used as sample_url for the probe" {
  _write_state awg1
  export NSLOOKUP_ADDR="1.2.3.4"
  mkdir -p "$FORCE_DIR"
  : > "$FORCE_DIR/force-tunnel.list"

  _html_f="$BATS_TEST_TMPDIR/page-b.html"
  cat > "$_html_f" <<'HTML'
<html><body>
<a href="https://assets.example.com/plain-page">link</a>
<script src="https://assets.example.com/bundle.js"></script>
</body></html>
HTML
  export PAGE_HTML_FILE="$_html_f"

  _stub_dir="$BATS_TEST_TMPDIR/pp-stubs-b"
  _make_pp_curl_stub "$_stub_dir"
  # Make both direct and tunnel return ok so the test completes cleanly.
  export CURL_DIRECT_OUT="200 0.200 500000 102400"
  export CURL_TUNNEL_OUT="200 0.200 500000 102400"
  export CURL="$_stub_dir/curl"

  run sh "$SCRIPT" probe-page "https://page.example.com/"
  [ "$status" -eq 0 ] || { echo "output: $output"; false; }

  # The .js URL must appear as a curl argument in the stub log
  grep -q "bundle.js" "$STUB_LOG" \
    || { echo "bundle.js not passed to curl; stub log: $(cat "$STUB_LOG")"; false; }
}

# (c) --add-throttled: throttled host gets added (added:1 in JSON, save-manual called)
@test "probe-page --add-throttled: throttled host is added to force list (added:1)" {
  _write_state awg1
  export NSLOOKUP_ADDR="1.2.3.4"
  mkdir -p "$FORCE_DIR"
  : > "$FORCE_DIR/force-tunnel.list"

  _html_f="$BATS_TEST_TMPDIR/page-c.html"
  cat > "$_html_f" <<'HTML'
<html><body>
<script src="https://slow.example.com/app.js"></script>
</body></html>
HTML
  export PAGE_HTML_FILE="$_html_f"

  # page host = slow.example.com: direct 000 → throttled
  _stub_dir="$BATS_TEST_TMPDIR/pp-stubs-c"
  _make_pp_curl_stub "$_stub_dir"
  export CURL_DIRECT_OUT="000 0.000 0 0"
  export CURL_TUNNEL_OUT="200 0.200 500000 102400"
  export CURL="$_stub_dir/curl"

  _cap_f="$BATS_TEST_TMPDIR/save-manual-c.txt"
  _fl_dir="$BATS_TEST_TMPDIR/fl-c"
  mkdir -p "$_fl_dir"
  cat > "$_fl_dir/amnezia-force-load" <<FLSTUB
#!/bin/sh
echo "amnezia-force-load \$*" >> "\${STUB_LOG:-/dev/null}"
if [ "\$1" = "save-manual" ]; then printf '%s' "\$2" > "$_cap_f"; fi
exit 0
FLSTUB
  chmod +x "$_fl_dir/amnezia-force-load"
  export AMNEZIA_FORCE_LOAD="$_fl_dir/amnezia-force-load"

  run sh "$SCRIPT" probe-page "https://slow.example.com/" --add-throttled
  [ "$status" -eq 0 ] || { echo "output: $output"; false; }

  # At least one host must have added:1
  echo "$output" | grep -q '"added":1' \
    || { echo "no added:1 found: $output"; false; }
  # save-manual must have been called
  grep -q "save-manual" "$STUB_LOG" \
    || { echo "save-manual not called; stub log: $(cat "$STUB_LOG")"; false; }
}

# (d) watch: 127.0.0.1 queries excluded, LAN queries probed
@test "watch: excludes 127.0.0.1 queries, probes LAN-client queries" {
  _write_state awg1
  export NSLOOKUP_ADDR="1.2.3.4"
  mkdir -p "$FORCE_DIR"
  : > "$FORCE_DIR/force-tunnel.list"

  # logread stub: emits queries from LAN IP (192.168.1.5) and from 127.0.0.1.
  _lr_dir="$BATS_TEST_TMPDIR/lr-d"
  mkdir -p "$_lr_dir"
  cat > "$_lr_dir/logread" <<'LRSTUB'
#!/bin/sh
echo "logread $*" >> "${STUB_LOG:-/dev/null}"
# Simulate dnsmasq query log lines.
printf 'Jun 30 10:00:01 router dnsmasq[123]: query[A] lansite.example.com from 192.168.1.5\n'
printf 'Jun 30 10:00:02 router dnsmasq[123]: query[A] selfsite.example.com from 127.0.0.1\n'
printf 'Jun 30 10:00:03 router dnsmasq[123]: query[A] another.example.com from 192.168.1.10\n'
LRSTUB
  chmod +x "$_lr_dir/logread"
  export LOGREAD="$_lr_dir/logread"

  _stub_dir="$BATS_TEST_TMPDIR/pp-stubs-d"
  _make_pp_curl_stub "$_stub_dir"
  export CURL_DIRECT_OUT="200 0.200 500000 102400"
  export CURL_TUNNEL_OUT="200 0.200 500000 102400"
  export CURL="$_stub_dir/curl"

  run sh "$SCRIPT" watch 10
  [ "$status" -eq 0 ] || { echo "output: $output"; false; }

  # JSON has window field
  echo "$output" | grep -q '"window":10'
  # lansite and another must appear in hosts array (LAN client queries)
  echo "$output" | grep -q '"lansite.example.com"' \
    || { echo "lansite not in output: $output"; false; }
  echo "$output" | grep -q '"another.example.com"' \
    || { echo "another.example.com not in output: $output"; false; }
  # selfsite (from 127.0.0.1) must NOT appear
  echo "$output" | grep -qF '"selfsite.example.com"' \
    && { echo "selfsite appeared (should be excluded): $output"; false; } || true
}

# (e) async probe-page: prints {"started":1}, writes state file with running:0
@test "probe-page --async: prints started:1, state file reaches running:0" {
  _write_state awg1
  export NSLOOKUP_ADDR="1.2.3.4"
  mkdir -p "$FORCE_DIR"
  : > "$FORCE_DIR/force-tunnel.list"

  _html_f="$BATS_TEST_TMPDIR/page-e.html"
  printf '<html><body><a href="https://async.example.com/page">x</a></body></html>\n' \
    > "$_html_f"
  export PAGE_HTML_FILE="$_html_f"

  _stub_dir="$BATS_TEST_TMPDIR/pp-stubs-e"
  _make_pp_curl_stub "$_stub_dir"
  export CURL_DIRECT_OUT="200 0.200 500000 102400"
  export CURL_TUNNEL_OUT="200 0.200 500000 102400"
  export CURL="$_stub_dir/curl"

  _pp_state="$BATS_TEST_TMPDIR/probe-page-async.json"
  export PROBE_PAGE_STATE="$_pp_state"
  export PROBE_PAGE_LOCK="$BATS_TEST_TMPDIR/probe-page-async.lock"

  run sh "$SCRIPT" probe-page "https://async.example.com/" --async
  [ "$status" -eq 0 ] || { echo "output: $output"; false; }
  # Must immediately print {"started":1}
  echo "$output" | grep -q '"started":1' \
    || { echo "missing started:1: $output"; false; }

  # Poll until state file shows running:0 (background job completes fast).
  _tries=0
  while [ "$_tries" -lt 30 ]; do
    if [ -f "$_pp_state" ] && grep -q '"running":0' "$_pp_state" 2>/dev/null; then
      break
    fi
    sleep 0.2
    _tries=$((_tries + 1))
  done

  [ -f "$_pp_state" ] || { echo "state file not created"; false; }
  grep -q '"running":0' "$_pp_state" \
    || { echo "state file never reached running:0: $(cat "$_pp_state" 2>/dev/null)"; false; }
  grep -q '"url":' "$_pp_state"
  grep -q '"hosts":' "$_pp_state"
}

# (f) invalid url -> exit 2
@test "probe-page: missing url arg exits 2" {
  run sh "$SCRIPT" probe-page
  [ "$status" -eq 2 ]
}

@test "probe-page: unsupported scheme (ftp://) exits 2" {
  run sh "$SCRIPT" probe-page "ftp://example.com/"
  [ "$status" -eq 2 ]
}

@test "probe-page: bare host with no dot exits 2" {
  run sh "$SCRIPT" probe-page "localhost"
  [ "$status" -eq 2 ]
}
