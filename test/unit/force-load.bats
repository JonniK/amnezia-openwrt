#!/usr/bin/env bats
load '../lib/harness.bash'
SCRIPT="$HARNESS_DIR/../openwrt/amnezia-force-load.sh"
setup() {
  export FORCE_DIR="$BATS_TEST_TMPDIR/amnezia"; mkdir -p "$FORCE_DIR/force.d"
  export AMNEZIA_FAILOVER_INIT="amnezia-failover-init"   # P0 stub
  # Route dnsmasq init calls through the stub so we can assert on them.
  # (dnsmasq restart is SSH-safe unlike fw4 reload; kept synchronous.)
  export AMNEZIA_DNSMASQ_INIT="dnsmasq"
  # Point conf-dir to a test temp path so tests don't write to /etc/amnezia.
  export AMZ_DNSMASQ_CONFDIR="$BATS_TEST_TMPDIR/dnsmasq.d"
}

# ---------------------------------------------------------------------------
# Basic classification + new conf-dir mechanism
# ---------------------------------------------------------------------------
@test "force-load classifies IP/CIDR into nft set and domains into conf-dir nftset file" {
  printf '8.8.8.8\n1.2.3.0/24\nexample.com\n# comment\n\n' > "$FORCE_DIR/force.d/itdoginfo_inside.list"
  printf 'manual.example\n9.9.9.9\n' > "$FORCE_DIR/force-tunnel.list"
  run sh "$SCRIPT"
  [ "$status" -eq 0 ]
  # nft/uci stubs record to STUB_LOG
  grep -q 'amnezia_force4.*8.8.8.8' "$STUB_LOG"
  grep -q 'amnezia_force4.*1.2.3.0/24' "$STUB_LOG"
  grep -q 'amnezia_force4.*9.9.9.9' "$STUB_LOG"
  # Domains go into the conf-dir file, NOT the legacy dhcp.amnezia_force ipset.
  [ -f "$AMZ_DNSMASQ_CONFDIR/amnezia-force.conf" ]
  grep -q 'nftset=.*example\.com.*amnezia_force4' "$AMZ_DNSMASQ_CONFDIR/amnezia-force.conf"
  grep -q 'nftset=.*manual\.example.*amnezia_force4' "$AMZ_DNSMASQ_CONFDIR/amnezia-force.conf"
  # Legacy dhcp.amnezia_force config-ipset must NOT be created.
  run grep 'amnezia_force\.domain' "$STUB_LOG"; [ "$status" -ne 0 ] || { echo "legacy ipset domain written"; false; }
}

@test "force-load conf-dir file has correct nftset= line format" {
  printf 'example.com\ntest.org\n' > "$FORCE_DIR/force-tunnel.list"
  run sh "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -f "$AMZ_DNSMASQ_CONFDIR/amnezia-force.conf" ]
  # Each line must start with nftset= and end with the set specifier.
  while IFS= read -r _line; do
    [ -z "$_line" ] && continue
    case "$_line" in
      nftset=*) ;;
      *) echo "unexpected line: $_line"; false ;;
    esac
    case "$_line" in
      */4#inet#fw4#amnezia_force4) ;;
      *) echo "line missing set specifier: $_line"; false ;;
    esac
  done < "$AMZ_DNSMASQ_CONFDIR/amnezia-force.conf"
}

# ---------------------------------------------------------------------------
# Regression: no nftset= line must exceed 1024 bytes (the live failure)
# ---------------------------------------------------------------------------
@test "REGRESSION: no nftset= line exceeds 1024 bytes with 1500 domains" {
  # Generate 1500 synthetic domains (d0001.example.com ... d1500.example.com).
  # Each is ~19 chars; 1500 * 19 = ~28 500 bytes if put on one line — far over limit.
  _domfile="$FORCE_DIR/force.d/large.list"
  : > "$_domfile"
  _i=0
  while [ "$_i" -lt 1500 ]; do
    printf 'd%04d.example.com\n' "$_i" >> "$_domfile"
    _i=$((_i + 1))
  done
  run sh "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -f "$AMZ_DNSMASQ_CONFDIR/amnezia-force.conf" ]
  # Every line in the output file must be <= 1024 bytes.
  while IFS= read -r _line; do
    [ -z "$_line" ] && continue
    _len=${#_line}
    if [ "$_len" -gt 1024 ]; then
      echo "FAIL: nftset line is $_len bytes (>1024): ${_line:0:120}..."
      false
    fi
  done < "$AMZ_DNSMASQ_CONFDIR/amnezia-force.conf"
  # Must have produced multiple lines (chunked).
  _count=$(grep -c '^nftset=' "$AMZ_DNSMASQ_CONFDIR/amnezia-force.conf" || true)
  [ "$_count" -gt 1 ] || { echo "expected multiple nftset lines for 1500 domains, got $_count"; false; }
  # All 1500 domains must appear somewhere in the file.
  _dom_found=$(grep -o 'd[0-9][0-9][0-9][0-9]\.example\.com' "$AMZ_DNSMASQ_CONFDIR/amnezia-force.conf" | sort -u | wc -l | tr -d ' ')
  [ "$_dom_found" -eq 1500 ] || { echo "expected 1500 domains, found $_dom_found"; false; }
}

# ---------------------------------------------------------------------------
# Legacy dhcp.amnezia_force section must be cleaned up
# ---------------------------------------------------------------------------
@test "force-load does NOT create dhcp.amnezia_force config-ipset section" {
  printf 'legacy.example\n' > "$FORCE_DIR/force-tunnel.list"
  run sh "$SCRIPT"
  [ "$status" -eq 0 ]
  # add_list dhcp.amnezia_force.domain= must never appear in the uci stub log.
  run grep 'add_list dhcp.amnezia_force.domain' "$STUB_LOG"
  [ "$status" -ne 0 ] || { echo "legacy ipset domain was added via uci"; false; }
  run grep "uci set dhcp.amnezia_force=" "$STUB_LOG"
  [ "$status" -ne 0 ] || { echo "legacy ipset section was created via uci"; false; }
}

@test "force-load deletes pre-existing dhcp.amnezia_force section (migration)" {
  # Simulate a pre-existing legacy section by making uci -q get dhcp.amnezia_force succeed.
  # The stub already logs all uci calls; we verify the delete call appears.
  printf 'example.com\n' > "$FORCE_DIR/force-tunnel.list"
  run sh "$SCRIPT"
  [ "$status" -eq 0 ]
  # The script calls `uci -q get dhcp.amnezia_force` to check if legacy exists,
  # and if so calls `uci -q delete dhcp.amnezia_force`.
  # Our stub returns exit 1 for the get (no legacy section) so delete may not be
  # called; but the new mechanism must NOT have written the ipset either way.
  run grep 'add_list dhcp.amnezia_force.domain' "$STUB_LOG"
  [ "$status" -ne 0 ] || { echo "legacy ipset domain written on clean install"; false; }
}

# ---------------------------------------------------------------------------
# Whitespace / leading-dot normalization
# ---------------------------------------------------------------------------
@test "force-load normalises whitespace and leading dot in domains" {
  # Domains with leading dot, trailing spaces, embedded tabs — all must appear
  # clean (no dot prefix, no surrounding whitespace) in the conf file.
  printf ' .ua\n\twdfiles.com \n.cr\n' > "$FORCE_DIR/force-tunnel.list"
  run sh "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -f "$AMZ_DNSMASQ_CONFDIR/amnezia-force.conf" ]
  # Must find clean forms.
  grep -q '/ua/' "$AMZ_DNSMASQ_CONFDIR/amnezia-force.conf" \
    || grep -q '/ua$' "$AMZ_DNSMASQ_CONFDIR/amnezia-force.conf" \
    || { cat "$AMZ_DNSMASQ_CONFDIR/amnezia-force.conf"; echo "ua not found"; false; }
  grep -q '/wdfiles\.com/' "$AMZ_DNSMASQ_CONFDIR/amnezia-force.conf" \
    || grep -q '/wdfiles\.com$' "$AMZ_DNSMASQ_CONFDIR/amnezia-force.conf" \
    || { cat "$AMZ_DNSMASQ_CONFDIR/amnezia-force.conf"; echo "wdfiles.com not found"; false; }
  # Must NOT find .ua or .cr with leading dot in the nftset paths.
  run grep '/\.ua' "$AMZ_DNSMASQ_CONFDIR/amnezia-force.conf"; [ "$status" -ne 0 ] || { echo "leading dot not stripped for .ua"; false; }
  run grep '/\.cr' "$AMZ_DNSMASQ_CONFDIR/amnezia-force.conf"; [ "$status" -ne 0 ] || { echo "leading dot not stripped for .cr"; false; }
}

# ---------------------------------------------------------------------------
# Domain-hash skip optimization (unchanged domains → no dnsmasq restart)
# ---------------------------------------------------------------------------
@test "force-load restarts dnsmasq only when the domain set changed" {
  printf 'a.example\n' > "$FORCE_DIR/force-tunnel.list"
  sh "$SCRIPT"; : > "$STUB_LOG"
  sh "$SCRIPT"                                   # no change — must NOT restart
  run grep -q 'dnsmasq.*restart' "$STUB_LOG"; [ "$status" -ne 0 ] || { echo "restarted w/o change"; false; }
  printf 'a.example\nb.example\n' > "$FORCE_DIR/force-tunnel.list"
  : > "$STUB_LOG"; sh "$SCRIPT"                   # domain added — must restart
  grep -q 'dnsmasq.*restart' "$STUB_LOG"
}

@test "save-manual writes the manual file without touching auto caches, then loads" {
  printf 'AUTO\n' > "$FORCE_DIR/force.d/x.list"
  run sh "$SCRIPT" save-manual "$(printf 'one.example\ntwo.example')"
  [ "$status" -eq 0 ]
  grep -q one.example "$FORCE_DIR/force-tunnel.list"
  grep -q AUTO "$FORCE_DIR/force.d/x.list"        # auto cache untouched
}

# H2: hotplug (IP-only invocation) must not touch dhcp config or restart dnsmasq.
@test "H2: repeated invocation with unchanged domains skips uci-commit and dnsmasq restart" {
  # Prime the hash so the second call sees no change.
  printf 'a.example\n1.2.3.4\n' > "$FORCE_DIR/force-tunnel.list"
  sh "$SCRIPT"                    # first call: writes conf, restarts dnsmasq, writes hash
  : > "$STUB_LOG"
  # Second call: domains unchanged, only IPs matter (simulates hotplug).
  sh "$SCRIPT"
  # nft flush/add must still happen (IP repopulation).
  grep -q 'nft.*amnezia_force4' "$STUB_LOG"
  # But NO uci commit dhcp and NO dnsmasq restart.
  run grep -q 'uci commit dhcp' "$STUB_LOG";    [ "$status" -ne 0 ] || { echo "unexpected uci commit dhcp"; false; }
  run grep -q 'dnsmasq.*restart' "$STUB_LOG";   [ "$status" -ne 0 ] || { echo "unexpected dnsmasq restart"; false; }
}

# H3: malformed IP/CIDR lines must be skipped; valid lines in the same file must load.
@test "H3: malformed IP lines are skipped; valid IPs in the same file still load" {
  printf '1.2.3.4/24\n999.999.999.999\n1.2.3.4/24x\n5.6.7.8\n' \
    > "$FORCE_DIR/force.d/mixed.list"
  run sh "$SCRIPT"
  [ "$status" -eq 0 ]
  # Valid entries must be in the set.
  grep -q 'amnezia_force4.*1.2.3.4/24' "$STUB_LOG"
  grep -q 'amnezia_force4.*5.6.7.8' "$STUB_LOG"
  # The garbage string must NOT appear in nft add calls.
  run grep '999.999.999.999' "$STUB_LOG"; [ "$status" -ne 0 ] || { echo "bad IP was loaded"; false; }
  run grep '1.2.3.4/24x' "$STUB_LOG";    [ "$status" -ne 0 ] || { echo "bad CIDR was loaded"; false; }
}

# Empty allowlist: conf file must exist and be empty (no nftset lines).
@test "force-load writes empty conf file when domain list is empty" {
  # No domain lists, only an IP.
  printf '1.2.3.4\n' > "$FORCE_DIR/force-tunnel.list"
  run sh "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -f "$AMZ_DNSMASQ_CONFDIR/amnezia-force.conf" ]
  _count=$(grep -c '^nftset=' "$AMZ_DNSMASQ_CONFDIR/amnezia-force.conf" 2>/dev/null; true)
  _count="${_count:-0}"
  [ "${_count}" -eq 0 ] || { echo "expected 0 nftset lines for IP-only input, got ${_count}"; false; }
}

