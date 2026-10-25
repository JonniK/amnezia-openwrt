#!/usr/bin/env bats
# Direct-override set (amnezia_direct4): classifier ordering, force-load
# population, warm re-resolution, and failover-ctl verbs.
# See docs/superpowers/specs/2026-07-22-direct-override-set-design.md.
load '../lib/harness.bash'

FORCE_LOAD_SCRIPT="$HARNESS_DIR/../openwrt/amnezia-force-load.sh"
CTL="$HARNESS_DIR/../openwrt/amnezia-failover-ctl.sh"
NFT_TUNNEL="$HARNESS_DIR/../openwrt/nftables.d/30-amnezia-classify.nft"
NFT_DIRECT="$HARNESS_DIR/../openwrt/nftables.d/30-amnezia-classify-direct.nft"

setup() {
  export FORCE_DIR="$BATS_TEST_TMPDIR/amnezia"; mkdir -p "$FORCE_DIR/force.d"
  export AMNEZIA_FAILOVER_INIT="amnezia-failover-init"
  export AMNEZIA_DNSMASQ_INIT="dnsmasq"
  export AMZ_DNSMASQ_CONFDIR="$BATS_TEST_TMPDIR/dnsmasq.d"
  export AMNEZIA_LIB="$HARNESS_DIR/../openwrt/lib"
  export AMNEZIA_FORCE_LOAD="amnezia-force-load"
}

# ---------------------------------------------------------------------------
# 1. Both classifier templates declare amnezia_direct4, and the direct rule
#    precedes both the sticky4 and force4 rules.
# ---------------------------------------------------------------------------
@test "both classifier templates declare amnezia_direct4 and order it before sticky/force" {
  for _f in "$NFT_TUNNEL" "$NFT_DIRECT"; do
    grep -q 'set amnezia_direct4' "$_f" \
      || { echo "amnezia_direct4 not declared in $_f"; false; }
    grep -q 'ip daddr @amnezia_direct4 return' "$_f" \
      || { echo "direct-override rule missing in $_f"; false; }
    # Ordering: line number of the direct4 rule must be lower than sticky4/force4 rules.
    _direct_ln=$(grep -n 'ip daddr @amnezia_direct4 return' "$_f" | head -1 | cut -d: -f1)
    _sticky_ln=$(grep -n 'ip daddr @amnezia_sticky4' "$_f" | head -1 | cut -d: -f1)
    _force_ln=$(grep -n 'ip daddr @amnezia_force4' "$_f" | head -1 | cut -d: -f1)
    [ -n "$_sticky_ln" ] || { echo "no sticky4 rule in $_f"; false; }
    [ "$_direct_ln" -lt "$_sticky_ln" ] \
      || { echo "direct4 rule ($_direct_ln) not before sticky4 ($_sticky_ln) in $_f"; false; }
    if [ -n "$_force_ln" ]; then
      [ "$_direct_ln" -lt "$_force_ln" ] \
        || { echo "direct4 rule ($_direct_ln) not before force4 ($_force_ln) in $_f"; false; }
    fi
  done
}

# ---------------------------------------------------------------------------
# 2. force-load populates amnezia_direct4 from direct-tunnel.list.
# ---------------------------------------------------------------------------
@test "force-load populates amnezia_direct4 from direct-tunnel.list (IP + domain)" {
  printf 'chat.google.com\n9.9.9.9\n' > "$FORCE_DIR/direct-tunnel.list"
  run sh "$FORCE_LOAD_SCRIPT"
  [ "$status" -eq 0 ]
  grep -q 'amnezia_direct4.*9.9.9.9' "$STUB_LOG" \
    || { echo "expected IP loaded into amnezia_direct4"; cat "$STUB_LOG"; false; }
  [ -f "$AMZ_DNSMASQ_CONFDIR/amnezia-direct.conf" ]
  grep -q 'nftset=.*chat\.google\.com.*amnezia_direct4' "$AMZ_DNSMASQ_CONFDIR/amnezia-direct.conf" \
    || { echo "expected domain nftset directive for amnezia_direct4"; cat "$AMZ_DNSMASQ_CONFDIR/amnezia-direct.conf"; false; }
}

# ---------------------------------------------------------------------------
# 3. Precedence: a domain present in BOTH lists yields both directives.
#    (Structural routing precedence itself is asserted via rule ordering in
#    test 1: the direct rule executes before the force rule in the chain.)
# ---------------------------------------------------------------------------
@test "a domain in both force-tunnel.list and direct-tunnel.list yields both nftset directives" {
  printf 'chat.google.com\n' > "$FORCE_DIR/force-tunnel.list"
  printf 'chat.google.com\n' > "$FORCE_DIR/direct-tunnel.list"
  run sh "$FORCE_LOAD_SCRIPT"
  [ "$status" -eq 0 ]
  grep -q 'nftset=.*chat\.google\.com.*amnezia_force4' "$AMZ_DNSMASQ_CONFDIR/amnezia-force.conf" \
    || { echo "expected force4 directive for chat.google.com"; false; }
  grep -q 'nftset=.*chat\.google\.com.*amnezia_direct4' "$AMZ_DNSMASQ_CONFDIR/amnezia-direct.conf" \
    || { echo "expected direct4 directive for chat.google.com"; false; }
}

# ---------------------------------------------------------------------------
# 4. Regression: force4 loading behaviour is unchanged after the refactor.
# ---------------------------------------------------------------------------
@test "REGRESSION: force4 still loads from force.d/*.list + force-tunnel.list" {
  printf '8.8.8.8\nexample.com\n' > "$FORCE_DIR/force.d/itdoginfo_inside.list"
  printf 'manual.example\n9.9.9.9\n' > "$FORCE_DIR/force-tunnel.list"
  run sh "$FORCE_LOAD_SCRIPT"
  [ "$status" -eq 0 ]
  grep -q 'amnezia_force4.*8.8.8.8' "$STUB_LOG"
  grep -q 'amnezia_force4.*9.9.9.9' "$STUB_LOG"
  [ -f "$AMZ_DNSMASQ_CONFDIR/amnezia-force.conf" ]
  grep -q 'nftset=.*example\.com.*amnezia_force4' "$AMZ_DNSMASQ_CONFDIR/amnezia-force.conf"
  grep -q 'nftset=.*manual\.example.*amnezia_force4' "$AMZ_DNSMASQ_CONFDIR/amnezia-force.conf"
  # Only one dnsmasq restart for the whole invocation (force4 + direct4 combined).
  _restarts=$(grep -c 'dnsmasq restart' "$STUB_LOG" || true)
  [ "${_restarts:-0}" -eq 1 ] || { echo "expected exactly 1 dnsmasq restart, got $_restarts"; cat "$STUB_LOG"; false; }
}

# ---------------------------------------------------------------------------
# 5. direct-add / direct-remove mutate direct-tunnel.list and invoke force-load.
# ---------------------------------------------------------------------------
@test "direct-add appends the domain and invokes force-load" {
  run sh "$CTL" direct-add chat.google.com
  [ "$status" -eq 0 ]
  grep -q '"result":"added"' <<< "$output"
  grep -q '^chat\.google\.com$' "$FORCE_DIR/direct-tunnel.list"
  grep -q 'amnezia-force-load' "$STUB_LOG"
}

@test "direct-add is idempotent: second add reports already-present, no duplicate line" {
  sh "$CTL" direct-add chat.google.com >/dev/null
  run sh "$CTL" direct-add chat.google.com
  [ "$status" -eq 0 ]
  grep -q '"result":"already-present"' <<< "$output"
  _count=$(grep -c '^chat\.google\.com$' "$FORCE_DIR/direct-tunnel.list")
  [ "$_count" -eq 1 ] || { echo "expected 1 line, got $_count"; false; }
}

@test "direct-add rejects garbage/empty domain" {
  run sh "$CTL" direct-add ""
  [ "$status" -ne 0 ]
  run sh "$CTL" direct-add "not a domain; rm -rf /"
  [ "$status" -ne 0 ]
}

@test "direct-remove removes the matching line and invokes force-load --flush-direct" {
  printf 'chat.google.com\nmail.google.com\n' > "$FORCE_DIR/direct-tunnel.list"
  run sh "$CTL" direct-remove chat.google.com
  [ "$status" -eq 0 ]
  grep -q '"result":"removed"' <<< "$output"
  run grep -qx 'chat.google.com' "$FORCE_DIR/direct-tunnel.list"
  [ "$status" -ne 0 ] || { echo "domain was not removed"; false; }
  grep -q '^mail\.google\.com$' "$FORCE_DIR/direct-tunnel.list"
  grep -q 'amnezia-force-load --flush-direct' "$STUB_LOG"
}

@test "direct-remove on absent domain reports not-found" {
  printf 'mail.google.com\n' > "$FORCE_DIR/direct-tunnel.list"
  run sh "$CTL" direct-remove chat.google.com
  [ "$status" -eq 0 ]
  grep -q '"result":"not-found"' <<< "$output"
}

# ---------------------------------------------------------------------------
# H1 regression: --flush is SET-SCOPED. direct-remove must never flush
# amnezia_force4, amnezia-force-load --flush must never flush amnezia_direct4,
# and a not-found direct-remove must not invoke force-load at all.
# ---------------------------------------------------------------------------
@test "H1: direct-remove flushes ONLY amnezia_direct4, never amnezia_force4" {
  printf 'chat.google.com\nmail.google.com\n' > "$FORCE_DIR/direct-tunnel.list"
  # Route through the REAL force-load script (not the force-load stub) so we
  # can observe the actual nft flush calls it issues.
  AMNEZIA_FORCE_LOAD="sh $FORCE_LOAD_SCRIPT" run sh "$CTL" direct-remove chat.google.com
  [ "$status" -eq 0 ]
  grep -q 'nft flush set inet fw4 amnezia_direct4' "$STUB_LOG" \
    || { echo "expected amnezia_direct4 to be flushed"; cat "$STUB_LOG"; false; }
  ! grep -q 'nft flush set inet fw4 amnezia_force4' "$STUB_LOG" \
    || { echo "amnezia_force4 must NOT be flushed by direct-remove"; cat "$STUB_LOG"; false; }
}

@test "H1: amnezia-force-load --flush flushes ONLY amnezia_force4, not amnezia_direct4" {
  printf '8.8.8.8\n' > "$FORCE_DIR/force.d/x.list"
  printf '9.9.9.9\n' > "$FORCE_DIR/direct-tunnel.list"
  run sh "$FORCE_LOAD_SCRIPT" --flush
  [ "$status" -eq 0 ]
  grep -q 'nft flush set inet fw4 amnezia_force4' "$STUB_LOG" \
    || { echo "expected amnezia_force4 to be flushed"; cat "$STUB_LOG"; false; }
  ! grep -q 'nft flush set inet fw4 amnezia_direct4' "$STUB_LOG" \
    || { echo "amnezia_direct4 must NOT be flushed by --flush"; cat "$STUB_LOG"; false; }
}

@test "H1: direct-remove on not-found domain does not invoke force-load at all" {
  printf 'mail.google.com\n' > "$FORCE_DIR/direct-tunnel.list"
  run sh "$CTL" direct-remove chat.google.com
  [ "$status" -eq 0 ]
  grep -q '"result":"not-found"' <<< "$output"
  ! grep -q 'amnezia-force-load' "$STUB_LOG" \
    || { echo "force-load must not run on a not-found direct-remove"; cat "$STUB_LOG"; false; }
}

@test "_ctl_direct_valid rejects a leading-dash token like -x" {
  run sh "$CTL" direct-add "-x"
  [ "$status" -ne 0 ]
  [ ! -f "$FORCE_DIR/direct-tunnel.list" ] || {
    run grep -qx -- "-x" "$FORCE_DIR/direct-tunnel.list"
    [ "$status" -ne 0 ]
  }
}

@test "direct-list prints entries, skipping comments and blank lines" {
  printf '# comment\nchat.google.com\n\nmail.google.com\n' > "$FORCE_DIR/direct-tunnel.list"
  run sh "$CTL" direct-list
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "chat.google.com" ]
  [ "${lines[1]}" = "mail.google.com" ]
}

@test "direct-list on absent list prints nothing and exits 0" {
  run sh "$CTL" direct-list
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# 6. Empty direct-tunnel.list writes an empty amnezia-direct.conf.
# ---------------------------------------------------------------------------
@test "empty direct-tunnel.list writes an empty amnezia-direct.conf (no stale directives)" {
  : > "$FORCE_DIR/direct-tunnel.list"
  run sh "$FORCE_LOAD_SCRIPT"
  [ "$status" -eq 0 ]
  [ -f "$AMZ_DNSMASQ_CONFDIR/amnezia-direct.conf" ]
  _count=$(grep -c '^nftset=' "$AMZ_DNSMASQ_CONFDIR/amnezia-direct.conf" 2>/dev/null; true)
  _count="${_count:-0}"
  [ "$_count" -eq 0 ] || { echo "expected 0 nftset lines, got $_count"; false; }
}
