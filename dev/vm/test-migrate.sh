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
_pbr_rules=$(vm_run "ip rule show 2>/dev/null | grep -i pbr" 2>/dev/null || true)
if [ -z "$_pbr_installed" ]; then
  assert_pass "E1" "pbr package not in opkg list-installed (removed)"
else
  assert_fail "E1" "pbr still installed: $_pbr_installed"
fi
# pbr adds ip rules with comments including 'pbr'; those should be gone.
if [ -z "$_pbr_rules" ]; then
  assert_pass "E2" "no pbr ip rules remain"
else
  assert_fail "E2" "pbr ip rules still present: $_pbr_rules"
fi

# ── F. amnezia_block_quic preserved ──────────────────────────────────────────
log "F: amnezia_block_quic preserved"
assert_block_quic_preserved

# ── Summary ──────────────────────────────────────────────────────────────────
print_summary
