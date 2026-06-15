#!/bin/sh
# Regression suite for the pbr→failover migrate path.
#
# Runs AFTER provision.sh (VM is in pbr pre-state with dummy tunnels).
# Invokes install-amnezia-pbr.sh --migrate inside the VM (NOT over a
# droppable SSH session — runs as a local subshell so SIGHUP is eliminated).
# Then asserts the 6 regression checks A–F.
#
# Exit code: 0 = all PASS, 1 = one or more FAIL.
# POSIX sh; runs on the macOS HOST.

set -eu
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/lib.sh"
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/assert.sh"

VM_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

log() { echo "[test-migrate] $*"; }
die() { echo "[test-migrate] FATAL: $*" >&2; exit 1; }

# Verify SSH connectivity before we start.
"$VM_DIR/vm-ssh.sh" 'echo ok' | grep -q '^ok$' || \
  die "VM not reachable over SSH -- is provision.sh complete?"

log "=== Capturing ip rules BEFORE migrate (Goal 2 baseline) ==="
# Capture the full ip rule show with pbr actively running.
# provision.sh already stored this in /tmp/pbr_rules_before.txt but we
# echo it here for the report.
vm_run "echo '=== ip rule show WITH pbr running ==='; ip rule show" 2>/dev/null || true

log "=== Running migrate in VM (STEPS=3 --migrate) ==="

# Run the installer locally inside the VM (no detached SSH session).
# CONF_DIR=/etc/amnezia so the installer reads the pre-staged amnezia config.
# The NFT_FAKE_RU4_COUNT override bypasses the amnezia_ru4 gate check:
# the gate normally requires a non-empty RU CIDR set, which isn't populated
# in Tier 1 (no real dnsmasq/ru-cidr pipeline). We gate-pass the migration
# by seeding a fake ru4 set BEFORE the migrate, then passing the check.
#
# Strategy: pre-seed the amnezia_ru4 set with one element so the gate passes.
# The gate checks `nft list set inet fw4 amnezia_ru4` for 'elements'.
# We must also ensure the fw4 table exists first.

log "pre-seeding amnezia_ru4 set for the gate check"
# shellcheck disable=SC2086
ssh $VM_SSH_OPTS "root@$SSH_HOST" '
  # Ensure fw4 table and the set exist before the installer gets there.
  nft add table inet fw4 2>/dev/null || true
  nft add set inet fw4 amnezia_ru4 \
    "{ type ipv4_addr; flags interval; auto-merge; }" 2>/dev/null || true
  # Add one element so the gate check (grep for "elements") passes.
  nft add element inet fw4 amnezia_ru4 { 77.88.8.8 } 2>/dev/null || true
  # Verify the set is non-empty.
  nft list set inet fw4 amnezia_ru4 2>/dev/null | grep -c elements || echo 0
' || log "WARN: pre-seed step had errors (may be non-fatal)"

log "starting installer --migrate inside VM (local exec, no SSH detach risk)"
# Run the installer synchronously inside the VM via SSH.
# 'sh /root/cutover/install-amnezia-pbr.sh --migrate' runs the migrate path
# because the top-of-script --migrate intercept fires before STEPS parsing.
#
# NOTE: even though we're running this over SSH, the SIGHUP risk in the
# original failure was from the *deploy* script backgrounding the installer.
# Here we run it foreground and synchronously, so if SSH drops the test
# itself fails (detectable) rather than leaving a half-migrated state.
# shellcheck disable=SC2086
ssh $VM_SSH_OPTS "root@$SSH_HOST" \
  'CONF_DIR=/etc/amnezia sh /root/cutover/install-amnezia-pbr.sh --migrate 2>&1' \
  && log "installer --migrate returned 0" \
  || log "WARN: installer --migrate returned non-zero (assertions may clarify)"

log "=== ip rules AFTER migrate (Goal 2 evidence) ==="
vm_run "echo '=== ip rule show AFTER migrate (pbr removed) ==='; ip rule show" 2>/dev/null || true

log "=== Assertions A–F ==="

# ── A. ip rules survive pbr removal (THE regression) ─────────────────────────
log "A: ip rules after pbr removal"
assert_ip_rules_present

# ── B. no WAN leak of marked traffic ─────────────────────────────────────────
log "B: no WAN leak"
assert_no_wan_leak

# ── C. classifier live ───────────────────────────────────────────────────────
log "C: nft classifier"
assert_classifier_live

# ── D. vpn masquerade zone ───────────────────────────────────────────────────
log "D: vpn firewall zone with masquerade"
assert_vpn_zone_masq

# ── E. pbr actually removed ──────────────────────────────────────────────────
log "E: pbr removed"
_pbr_installed=$(vm_run "opkg list-installed 2>/dev/null | grep '^pbr '" 2>/dev/null || true)
if [ -z "$_pbr_installed" ]; then
  assert_pass "E1" "pbr package not in opkg list-installed (removed)"
else
  assert_fail "E1" "pbr still installed: $_pbr_installed"
fi

# E2 (strengthened): use the pbr rules captured BEFORE migrate to assert they
# are GONE after. provision.sh stored pbr's non-kernel rules (priorities other
# than 0/32766/32767) in /tmp/pbr_own_rules.txt. We read back those priorities
# and verify none of them remain in the post-migrate ip rule show.
# This is much stronger than grep -i pbr (pbr rules have no "pbr" comment text).
_pbr_before=$(vm_run "cat /tmp/pbr_own_rules.txt 2>/dev/null || true" 2>/dev/null || true)
_rules_after=$(vm_run "ip rule show 2>/dev/null" 2>/dev/null || true)
if [ -z "$_pbr_before" ]; then
  # pbr never installed its own rules — the pre-state was trivial.
  # This is a test setup warning, not a pass (it means Goal 2 wasn't met).
  assert_fail "E2" "pbr installed NO non-kernel ip rules before migrate — pre-state was trivial (Goal 2 not achieved; pbr may not have had a working policy)"
else
  # Count simulated pbr rules that survived.
  _survived_count=0
  while IFS= read -r _rule; do
    [ -z "$_rule" ] && continue
    _prio=$(echo "$_rule" | awk -F: '{print $1}' | tr -d ' ')
    if echo "$_rules_after" | grep -qE "^[[:space:]]*${_prio}:"; then
      _survived_count=$((_survived_count + 1))
    fi
  done << PBRRULES
$_pbr_before
PBRRULES
  _pbr_count=$(echo "$_pbr_before" | grep -c '[^[:space:]]' || true)

  # VM NOTE: The simulated pbr rules (priorities 29999/30000) survive in the VM
  # because pbr 1.2.2-r14 did NOT actually install nft state (no WireGuard kernel
  # module → pbr starts but detects no tunnel interfaces → installs no nft chains
  # → stop_service returns early without running cleanup 'main_table').
  #
  # On real hardware with a fully-active pbr:
  # - stop_service DOES run cleanup 'main_table' (pbr has live nft state)
  # - cleanup deletes ALL ip rules in priority range [29745, 30000]
  # - Our routing_install_rules (step 6) places rules at 29997/29998 (adjacent
  #   to pbr's rules at ~30000) — WITHIN pbr's cleanup range
  # - Therefore pbr stop (step 14) WOULD delete our fwmark rules too
  #
  # This IS the second installer defect (matches the hardware failure).
  # The surviving simulated rules in E2 are a VM artifact, not an installer pass.
  if [ "$_survived_count" -eq 0 ]; then
    assert_pass "E2" "all $_pbr_count pbr-installed ip rules are gone after pbr removal"
  else
    # E2 FAIL: Simulated pbr rules survived because pbr's stop returned early (no live state).
    # On real hardware with live pbr state, pbr stop WOULD clean up priority range 29745-30000,
    # which includes our fwmark rules at 29997/29998 — this is the confirmed second defect.
    assert_fail "E2-vm-artifact" "$_survived_count of $_pbr_count simulated pbr rules survived (expected: pbr stop returned early — no live state in VM). ON REAL HARDWARE this means pbr cleanup would also delete our fwmark rules at 29997/29998. SECOND DEFECT CONFIRMED via code analysis."
  fi
fi

# E2-detail: log the before/after for the report.
log "E2 detail: pbr rules BEFORE migrate:"
vm_run "cat /tmp/pbr_rules_before.txt 2>/dev/null || echo '(not found)'" 2>/dev/null || true
log "E2 detail: ip rules AFTER migrate:"
vm_run "ip rule show 2>/dev/null" 2>/dev/null || true

# E2-simulation: run pbr cleanup logic against post-migrate ip rules to prove the defect.
log "E2 simulation: rules pbr cleanup WOULD DELETE on real hardware (priority range 29745-30000)"
vm_run "
  uplink_ip_rules_priority=30000
  fw_mask=16711680
  uplink_mark=65536
  max_ifaces=\$((fw_mask / uplink_mark))
  prio_max=\$uplink_ip_rules_priority
  prio_min=\$((uplink_ip_rules_priority - max_ifaces))
  echo \"pbr cleanup range: priorities \$prio_min to \$prio_max\"
  ip -4 rule show | while IFS= read -r line; do
    prio=\"\${line%%:*}\"
    prio=\$(echo \"\$prio\" | tr -d ' ')
    if [ \"\$prio\" -ge \"\$prio_min\" ] 2>/dev/null && [ \"\$prio\" -le \"\$prio_max\" ] 2>/dev/null; then
      echo \"  WOULD DELETE: \$line\"
    fi
  done
" 2>/dev/null || true

# ── F. amnezia_block_quic preserved ──────────────────────────────────────────
log "F: amnezia_block_quic preserved"
assert_block_quic_preserved

# ── Summary ──────────────────────────────────────────────────────────────────
print_summary
