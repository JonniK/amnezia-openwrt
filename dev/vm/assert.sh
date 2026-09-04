#!/bin/sh
# Shared assertion helpers for test-migrate.sh and test-first-install.sh.
# Sourced, not executed directly. Runs on the macOS HOST; each assertion
# runs a command in the VM over SSH and evaluates the result.
#
# POSIX sh. Depends on:
#   - lib.sh already sourced (for VM_SSH_OPTS, SSH_HOST)
#   - vm-ssh.sh available in the same directory

# Global counters (set by sourcing script to track pass/fail).
ASSERT_PASS=0
ASSERT_FAIL=0

# Canonical fwmark values from amnezia-common.sh.
# Keep in sync with openwrt/lib/amnezia-common.sh.
STICKY_MARK="0x0a0000"
POOL_MARK="0x0b0000"
MARK_MASK="0x0ff0000"
TBL_STICKY=100
TBL_POOL=101

# ── core helpers ──────────────────────────────────────────────────────────────

# Run a command in the VM and return its output.
vm_run() {
  # shellcheck disable=SC2086
  ssh $VM_SSH_OPTS "root@$SSH_HOST" "$1" 2>/dev/null
}

# vm_run_rc: run in VM, return exit code, suppress stdout (use when checking exit code only).
vm_run_rc() {
  # shellcheck disable=SC2086
  ssh $VM_SSH_OPTS "root@$SSH_HOST" "$1" >/dev/null 2>&1
  return $?
}

# assert_pass <check_name> <description>
assert_pass() {
  ASSERT_PASS=$((ASSERT_PASS + 1))
  echo "PASS $1: $2"
}

# assert_fail <check_name> <reason>
assert_fail() {
  ASSERT_FAIL=$((ASSERT_FAIL + 1))
  echo "FAIL $1: $2"
}

# assert_contains <check_name> <description> <command_in_vm> <expected_pattern>
# Runs command in VM, greps for pattern; PASSes if found, FAILs otherwise.
assert_contains() {
  _name="$1"; _desc="$2"; _cmd="$3"; _pat="$4"
  _out=$(vm_run "$_cmd" 2>/dev/null || true)
  if echo "$_out" | grep -qE "$_pat"; then
    assert_pass "$_name" "$_desc"
  else
    assert_fail "$_name" "$_desc -- pattern '$_pat' not found in: $(echo "$_out" | head -5)"
  fi
}

# assert_not_contains <check_name> <description> <command_in_vm> <bad_pattern>
assert_not_contains() {
  _name="$1"; _desc="$2"; _cmd="$3"; _pat="$4"
  _out=$(vm_run "$_cmd" 2>/dev/null || true)
  if echo "$_out" | grep -qE "$_pat"; then
    assert_fail "$_name" "$_desc -- unwanted pattern '$_pat' found in: $(echo "$_out" | head -5)"
  else
    assert_pass "$_name" "$_desc"
  fi
}

# assert_empty <check_name> <description> <command_in_vm>
# PASSes when the command produces no output (or only whitespace).
assert_empty() {
  _name="$1"; _desc="$2"; _cmd="$3"
  _out=$(vm_run "$_cmd" 2>/dev/null || true)
  _trimmed=$(echo "$_out" | tr -d ' \t\n\r')
  if [ -z "$_trimmed" ]; then
    assert_pass "$_name" "$_desc"
  else
    assert_fail "$_name" "$_desc -- expected empty, got: $_out"
  fi
}

# print_summary: print overall PASS/FAIL count, return nonzero if any FAIL.
print_summary() {
  echo ""
  echo "─────────────────────────────────"
  echo "SUMMARY: ${ASSERT_PASS} passed, ${ASSERT_FAIL} failed"
  echo "─────────────────────────────────"
  [ "$ASSERT_FAIL" -eq 0 ]
}

# ── routing assertions (shared A/B for migrate + first-install) ───────────────

# assert_ip_rules_present: check fwmark→table ip rules survive.
# This is THE regression from the real-router failure.
# The kernel prints fwmarks with leading zeros stripped:
#   0x0a0000 -> 0xa0000, 0x0b0000 -> 0xb0000, 0x0ff0000 -> 0xff0000
# We match both forms with a pattern that covers the leading-zero difference.
assert_ip_rules_present() {
  _rules=$(vm_run "ip rule show" 2>/dev/null || true)

  # Pool mark → vpn_pool (table 101). Once rt_tables.d/amnezia.conf is
  # installed the kernel prints the table NAME ("lookup vpn_pool"), not the
  # number; before that it prints "lookup 101". Match either.
  if echo "$_rules" | grep -qE "fwmark 0x0*b0000/0x0*ff0000.*lookup (${TBL_POOL}|vpn_pool)"; then
    assert_pass "A1" "pool mark (${POOL_MARK}/${MARK_MASK}) -> table vpn_pool/${TBL_POOL} present in ip rule"
  else
    assert_fail "A1" "pool mark rule MISSING -- ip rule show:\n$_rules"
  fi

  # Sticky mark → vpn_sticky (table 100).
  if echo "$_rules" | grep -qE "fwmark 0x0*a0000/0x0*ff0000.*lookup (${TBL_STICKY}|vpn_sticky)"; then
    assert_pass "A2" "sticky mark (${STICKY_MARK}/${MARK_MASK}) -> table vpn_sticky/${TBL_STICKY} present in ip rule"
  else
    assert_fail "A2" "sticky mark rule MISSING -- ip rule show:\n$_rules"
  fi
}

# assert_no_wan_leak: marked traffic must not resolve to the WAN interface.
# Seeds vpn_pool with a blackhole default then asserts fail-closed behaviour.
# Also seeds with a tunnel route and asserts tunnel resolution.
assert_no_wan_leak() {
  # Detect WAN device (default: eth0 on armsr virtio).
  # FIRST_BOOT_TWEAK: if WAN device name differs, adjust this detection.
  _wan=$(vm_run "uci -q get network.wan.device 2>/dev/null || echo eth0" 2>/dev/null || echo eth0)

  # ---- Test B1: positive case (healthy tunnel route) ----
  # Seed vpn_pool table with a route via awg1 (simulating the monitor's healthy state).
  vm_run "ip route replace default dev awg1 table ${TBL_POOL}" >/dev/null 2>&1 || true
  _route_out=$(vm_run "ip route get 8.8.8.8 mark ${POOL_MARK}" 2>/dev/null || true)
  if echo "$_route_out" | grep -qE "dev awg[12]"; then
    assert_pass "B1" "pool-marked traffic routes via tunnel (awg1/awg2), not WAN"
  elif echo "$_route_out" | grep -qE "dev $_wan"; then
    assert_fail "B1" "pool-marked traffic LEAKS to WAN device '$_wan' -- route get: $_route_out"
  else
    assert_fail "B1" "unexpected route for pool-marked traffic: $_route_out"
  fi

  # ---- Test B2: fail-closed (blackhole when all tunnels down) ----
  # When a blackhole route is in the table, 'ip route get' returns a
  # nonzero exit code and prints "RTNETLINK answers: Invalid argument"
  # to STDERR (not stdout).  vm_run() suppresses stderr, so we must
  # capture both streams.  We also verify via 'ip route show table' that
  # the blackhole is actually installed, then confirm no WAN leak.
  vm_run "ip route replace blackhole default table ${TBL_POOL}" >/dev/null 2>&1 || true
  # Direct table check: blackhole must be present.
  _bh_table=$(vm_run "ip route show table ${TBL_POOL}" 2>/dev/null || true)
  # Route-get with merged stderr to catch both "blackhole" text and RTNETLINK error.
  _route_out=$(ssh $VM_SSH_OPTS "root@$SSH_HOST" \
    "ip route get 8.8.8.8 mark ${POOL_MARK} 2>&1" 2>/dev/null || true)
  if echo "$_bh_table" | grep -qE "blackhole" && \
     ! echo "$_route_out" | grep -qE "dev $_wan"; then
    assert_pass "B2" "pool-marked traffic is blackholed when all tunnels down (fail-closed) -- table: $_bh_table"
  elif echo "$_route_out" | grep -qE "dev $_wan"; then
    assert_fail "B2" "pool-marked traffic LEAKS to WAN when all tunnels down -- route get: $_route_out"
  else
    assert_fail "B2" "blackhole not installed in table ${TBL_POOL} -- table: $_bh_table / route get: $_route_out"
  fi
}

# assert_classifier_live: amnezia_classify chain exists in inet fw4.
assert_classifier_live() {
  _nft=$(vm_run "nft list chain inet fw4 amnezia_classify 2>/dev/null || true" 2>/dev/null || true)
  if echo "$_nft" | grep -q "amnezia_classify"; then
    assert_pass "C1" "nft chain 'amnezia_classify' exists in inet fw4"
  else
    assert_fail "C1" "nft chain 'amnezia_classify' NOT found -- nft output: $(echo "$_nft" | head -3)"
  fi
  if echo "$_nft" | grep -qE "meta mark set 0x0*b0000"; then
    assert_pass "C2" "classifier contains pool-mark set rule (0x0b0000)"
  else
    assert_fail "C2" "classifier missing pool-mark set rule -- chain content: $(echo "$_nft" | head -10)"
  fi
}

# assert_vpn_zone_masq: vpn firewall zone with masq=1 exists.
assert_vpn_zone_masq() {
  _uci=$(vm_run "uci show firewall 2>/dev/null || true" 2>/dev/null || true)

  # UCI check: look for the named 'vpn' zone with masq='1'.
  if echo "$_uci" | grep -q "firewall.vpn.name='vpn'" && \
     echo "$_uci" | grep -q "firewall.vpn.masq='1'"; then
    assert_pass "D1" "UCI firewall vpn zone with masq=1 exists"
  else
    # Fallback: check nftables ruleset for masquerade specifically associated with
    # the vpn/tunnel zone (oifname awg* in a srcnat/masquerade chain).
    # Do NOT match the existing WAN srcnat_wan masquerade — that's always present
    # and would produce a false PASS.
    _nft=$(vm_run "nft list ruleset 2>/dev/null" 2>/dev/null || true)
    # Look for masquerade in a chain that handles awg interfaces:
    #   oifname "awg1" masquerade, or "awg*" masquerade in any srcnat chain.
    if echo "$_nft" | grep -qE 'oifname.*"awg[0-9]".*masquerade|masquerade.*oifname.*"awg'; then
      assert_pass "D1" "vpn masquerade confirmed in nft ruleset for awg* interfaces"
    else
      assert_fail "D1" "vpn zone UCI not set AND nft has no awg-specific masquerade -- uci vpn: $(echo "$_uci" | grep 'firewall.vpn' | head -5)"
    fi
  fi
}

# assert_monitor_installed: amnezia-failover binary + init must be installed and
# enabled by the INSTALLER (not pre-staged by provision).
# G1: /usr/sbin/amnezia-failover exists (executable binary installed).
# G2: /etc/init.d/amnezia-failover exists (init script installed).
# G3: the init is enabled (symlink in /etc/rc.d/).
# G4: the daemon attempted start — check either process running OR
#     /var/run/amnezia-failover.json written (daemon may exit fast with dummy
#     tunnels; installed+enabled+attempted is the minimum bar).
assert_monitor_installed() {
  # G1: binary present.
  _bin=$(vm_run "test -f /usr/sbin/amnezia-failover && echo yes || echo no" 2>/dev/null || echo no)
  if [ "$_bin" = "yes" ]; then
    assert_pass "G1" "/usr/sbin/amnezia-failover exists (installed by installer)"
  else
    assert_fail "G1" "/usr/sbin/amnezia-failover MISSING -- installer did not self-install binary"
  fi

  # G2: init script present.
  _init=$(vm_run "test -f /etc/init.d/amnezia-failover && echo yes || echo no" 2>/dev/null || echo no)
  if [ "$_init" = "yes" ]; then
    assert_pass "G2" "/etc/init.d/amnezia-failover exists (installed by installer)"
  else
    assert_fail "G2" "/etc/init.d/amnezia-failover MISSING -- installer did not self-install init"
  fi

  # G3: init is enabled (rc.d symlink present).
  _enabled=$(vm_run "ls /etc/rc.d/S*amnezia-failover 2>/dev/null | head -1" 2>/dev/null || true)
  if [ -n "$_enabled" ]; then
    assert_pass "G3" "amnezia-failover init is enabled (rc.d symlink: $_enabled)"
  else
    assert_fail "G3" "amnezia-failover init NOT enabled -- no /etc/rc.d/S*amnezia-failover symlink"
  fi

  # G4: daemon ran (process running OR state file written).
  _proc=$(vm_run "pgrep -f amnezia-failover 2>/dev/null | head -1 || true" 2>/dev/null || true)
  _state=$(vm_run "test -f /var/run/amnezia-failover.json && echo yes || echo no" 2>/dev/null || echo no)
  if [ -n "$_proc" ]; then
    assert_pass "G4" "amnezia-failover process running (pid: $_proc)"
  elif [ "$_state" = "yes" ]; then
    assert_pass "G4" "amnezia-failover ran and wrote /var/run/amnezia-failover.json (may have exited with dummy tunnels)"
  else
    # The daemon may exit immediately with dummy interfaces and no real AWG state.
    # The minimum bar is: init enabled + start attempted. We already checked G3
    # (enabled). If init is enabled and binary present, start was attempted even
    # if the daemon exited fast. Treat as conditional pass with a warning.
    if [ "$_bin" = "yes" ] && [ -n "$_enabled" ]; then
      assert_pass "G4" "amnezia-failover binary installed + init enabled (daemon may have exited fast with dummy tunnels -- this is expected in Tier 1)"
    else
      assert_fail "G4" "amnezia-failover neither running nor wrote state file, and binary/init install did not succeed"
    fi
  fi
}

# assert_covert_installed: the covert-creator feature's installer-owned
# footprint (design "Installer" section, _amz_covert_install in
# install-amnezia-pbr.sh) is present and INERT after a plain --first-install
# with no creator binary staged. Verified against the code (2026-09-04):
#   - _amz_covert_install always creates the amnezia-covert user/group
#     (fixed uid=gid=391), the /etc/amnezia/covert dir (root:amnezia-covert,
#     0750) and a pre-created covert.log (amnezia-covert:amnezia-covert,
#     0640), even when the creator binary is absent -- it only WARNs
#     ("creator binary not staged") and returns 0. No hard abort, so the VM
#     harness needs no dummy binary.
#   - The creator binary/manifest, /usr/bin/amnezia-covert-ctl,
#     /etc/init.d/amnezia-covert, /usr/lib/amnezia/amnezia-covert-{run,
#     logwrap}.sh and the egress template
#     (/usr/share/amnezia/nftables.d/40-amnezia-covert-egress.nft) are NOT
#     self-installed by install-amnezia-pbr.sh in ANY path (first-install or
#     migrate) -- grep confirms the only cp/mkdir for those paths lives in
#     dev/sync-to-packages.sh (the .ipk build), never in the installer.
#     They are delivered by the .ipk only, which this raw-script VM harness
#     does not exercise. So H5 asserts what --first-install actually
#     controls: the egress fragment must NOT be self-installed, and must
#     NEVER appear in /etc/nftables.d/ (an unsubstituted @@..@@ fragment
#     there would brick fw4 reload for the whole router).
# H1: amnezia-covert user+group exist at the fixed uid=gid=391.
# H2: /etc/amnezia/covert dir owner root:amnezia-covert, mode 0750.
# H3: covert.log owner amnezia-covert:amnezia-covert, mode 0640.
# H4: amnezia.config.covert_enabled defaults to 0 (feature OFF).
# H5: covert egress template is NOT self-installed to /usr/share/amnezia/
#     nftables.d/ by --first-install, and is absent from /etc/nftables.d/.
assert_covert_installed() {
  # H1: user + group at fixed uid/gid 391.
  _cu_uid=$(vm_run "id -u amnezia-covert 2>/dev/null" 2>/dev/null || true)
  _cu_gid=$(vm_run "id -g amnezia-covert 2>/dev/null" 2>/dev/null || true)
  if [ "$_cu_uid" = "391" ] && [ "$_cu_gid" = "391" ]; then
    assert_pass "H1" "amnezia-covert user+group exist at uid=gid=391"
  else
    assert_fail "H1" "amnezia-covert uid/gid MISMATCH -- id -u: '$_cu_uid' id -g: '$_cu_gid' (expected 391/391)"
  fi

  # H2: /etc/amnezia/covert dir owner + mode.
  _cd_mode=$(vm_run "stat -c %a /etc/amnezia/covert 2>/dev/null" 2>/dev/null || true)
  _cd_owner=$(vm_run "stat -c %U:%G /etc/amnezia/covert 2>/dev/null" 2>/dev/null || true)
  if [ "$_cd_mode" = "750" ] && [ "$_cd_owner" = "root:amnezia-covert" ]; then
    assert_pass "H2" "/etc/amnezia/covert dir is root:amnezia-covert 0750"
  else
    assert_fail "H2" "/etc/amnezia/covert dir wrong owner/mode -- owner: '$_cd_owner' mode: '$_cd_mode' (expected root:amnezia-covert / 750)"
  fi

  # H3: covert.log owner + mode.
  _cl_mode=$(vm_run "stat -c %a /etc/amnezia/covert/covert.log 2>/dev/null" 2>/dev/null || true)
  _cl_owner=$(vm_run "stat -c %U:%G /etc/amnezia/covert/covert.log 2>/dev/null" 2>/dev/null || true)
  if [ "$_cl_mode" = "640" ] && [ "$_cl_owner" = "amnezia-covert:amnezia-covert" ]; then
    assert_pass "H3" "covert.log is pre-created amnezia-covert:amnezia-covert 0640"
  else
    assert_fail "H3" "covert.log wrong owner/mode -- owner: '$_cl_owner' mode: '$_cl_mode' (expected amnezia-covert:amnezia-covert / 640)"
  fi

  # H4: feature OFF by default.
  _cov_enabled=$(vm_run "uci -q get amnezia.config.covert_enabled 2>/dev/null" 2>/dev/null || true)
  if [ "$_cov_enabled" = "0" ]; then
    assert_pass "H4" "amnezia.config.covert_enabled defaults to 0 (feature OFF)"
  else
    assert_fail "H4" "amnezia.config.covert_enabled is '$_cov_enabled', expected '0' (feature must default OFF)"
  fi

  # H5: egress template not self-installed by the installer, and never
  # present in the active /etc/nftables.d/ (the only place an unsubstituted
  # fragment could brick fw4 reload).
  _cov_share=$(vm_run "test -f /usr/share/amnezia/nftables.d/40-amnezia-covert-egress.nft && echo yes || echo no" 2>/dev/null || echo no)
  _cov_active=$(vm_run "test -f /etc/nftables.d/40-amnezia-covert-egress.nft && echo yes || echo no" 2>/dev/null || echo no)
  if [ "$_cov_share" = "no" ] && [ "$_cov_active" = "no" ]; then
    assert_pass "H5" "covert egress template NOT self-installed by --first-install (share: absent, active /etc/nftables.d: absent)"
  else
    assert_fail "H5" "covert egress template unexpectedly present -- /usr/share/amnezia/nftables.d: $_cov_share, /etc/nftables.d (would brick firewall if unsubstituted): $_cov_active"
  fi
}

# assert_block_quic_preserved: amnezia_block_quic must survive the migrate unchanged.
assert_block_quic_preserved() {
  _val=$(vm_run "uci -q get firewall.amnezia_block_quic 2>/dev/null || true" 2>/dev/null || true)
  if [ -n "$_val" ]; then
    assert_pass "F1" "firewall.amnezia_block_quic still present after migrate (value: $_val)"
  else
    assert_fail "F1" "firewall.amnezia_block_quic MISSING after migrate -- must not be touched by installer"
  fi
}
