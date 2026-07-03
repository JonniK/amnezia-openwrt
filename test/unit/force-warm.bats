#!/usr/bin/env bats
load '../lib/harness.bash'
SCRIPT="$HARNESS_DIR/../openwrt/amnezia-force-warm.sh"

setup() {
  export FORCE_DIR="$BATS_TEST_TMPDIR/amnezia"
  mkdir -p "$FORCE_DIR"
  export WARM_RESOLVER="127.0.0.1"
  # Redirect the lock to the test tmpdir so /var/lock is not required.
  export FORCE_WARM_LOCK="$BATS_TEST_TMPDIR/amnezia-force-warm.lock"
  # Master is enabled by default (uci returns 1).
  export UCI_GET_amnezia_config_master_enabled=1
}

# ---------------------------------------------------------------------------
# Test 1: domains are resolved; IPs, comments and blanks are skipped
# ---------------------------------------------------------------------------
@test "re-resolves domains only: skips IPs, CIDRs, comments, blank lines" {
  cat > "$FORCE_DIR/force-tunnel.list" <<'EOF'
# comment line
example.com
  # another comment
8.8.8.8
1.2.3.0/24
google.com

EOF
  run sh "$SCRIPT"
  [ "$status" -eq 0 ]

  # nslookup must be called for the two domains.
  grep -q 'nslookup example.com' "$STUB_LOG"
  grep -q 'nslookup google.com' "$STUB_LOG"

  # nslookup must NOT be called for the IP, CIDR, or any empty/comment line.
  run grep 'nslookup 8.8.8.8' "$STUB_LOG";   [ "$status" -ne 0 ] || { echo "IP was resolved"; false; }
  run grep 'nslookup 1.2.3.0' "$STUB_LOG";   [ "$status" -ne 0 ] || { echo "CIDR was resolved"; false; }
  run grep 'nslookup #' "$STUB_LOG";         [ "$status" -ne 0 ] || { echo "comment was resolved"; false; }
}

# ---------------------------------------------------------------------------
# Test 2: missing force-tunnel.list -> exit 0, no nslookup calls
# ---------------------------------------------------------------------------
@test "missing force-tunnel.list exits 0 silently" {
  # No list file written in this test.
  run sh "$SCRIPT"
  [ "$status" -eq 0 ]
  run grep 'nslookup' "$STUB_LOG"; [ "$status" -ne 0 ] || { echo "nslookup called with no list"; false; }
}

# ---------------------------------------------------------------------------
# Test 3: master disabled -> exit 0, no nslookup calls
# ---------------------------------------------------------------------------
@test "master disabled: exits 0 and performs no nslookup calls" {
  cat > "$FORCE_DIR/force-tunnel.list" <<'EOF'
example.com
another.org
EOF
  UCI_GET_amnezia_config_master_enabled=0 run sh "$SCRIPT"
  [ "$status" -eq 0 ]
  run grep 'nslookup' "$STUB_LOG"; [ "$status" -ne 0 ] || { echo "nslookup called when master is off"; false; }
}

# ---------------------------------------------------------------------------
# Test 4: inline comments on domain lines are stripped before lookup
# ---------------------------------------------------------------------------
@test "inline comments on domain lines are stripped before resolution" {
  cat > "$FORCE_DIR/force-tunnel.list" <<'EOF'
example.com  # this is a CDN domain
EOF
  run sh "$SCRIPT"
  [ "$status" -eq 0 ]
  # The lookup must be against the clean domain name, not the comment.
  grep -q 'nslookup example.com' "$STUB_LOG"
  run grep 'nslookup example.com  #' "$STUB_LOG"; [ "$status" -ne 0 ] || { echo "comment leaked into nslookup arg"; false; }
}

# ---------------------------------------------------------------------------
# Test 5: resolver argument is passed to nslookup
# ---------------------------------------------------------------------------
@test "nslookup receives the WARM_RESOLVER argument" {
  cat > "$FORCE_DIR/force-tunnel.list" <<'EOF'
check.example
EOF
  WARM_RESOLVER=192.0.2.1 run sh "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q 'nslookup check.example 192.0.2.1' "$STUB_LOG"
}

# ---------------------------------------------------------------------------
# Test 6: bounded-wave batching — a 25-domain list still resolves all 25
# ---------------------------------------------------------------------------
@test "wave batching: 25-domain list completes with all 25 nslookup calls" {
  # Build a list with 25 unique domains (more than the default wave size of 10).
  {
    i=1
    while [ "$i" -le 25 ]; do
      printf 'site%d.example\n' "$i"
      i=$(( i + 1 ))
    done
  } > "$FORCE_DIR/force-tunnel.list"

  run sh "$SCRIPT"
  [ "$status" -eq 0 ]

  # All 25 nslookup calls must be present in the stub log.
  _count=$(grep -c 'nslookup site' "$STUB_LOG" 2>/dev/null || printf '0')
  [ "$_count" -eq 25 ] \
    || { echo "expected 25 nslookup calls, got $_count"; false; }
}
