#!/bin/sh
# Test the clean first_install_wiring path (no pbr present).
#
# Runs against a VM that has been provisioned in first-install mode:
#   provision.sh --first-install
#
# That provision sets up: SSH, opkg deps (no pbr), dnsmasq-full, ip-full,
# kmod-veth, kmod-dummy, dummy awg1/awg2 interfaces, /etc/config/amnezia,
# br-lan, lanclient netns, and pushes the openwrt/ tree to /root/cutover.
#
# This test:
#   1. Confirms pbr is NOT installed (pre-condition for first_install path).
#   2. Pre-seeds amnezia_ru4 nft set (configure-dnsmasq-amnezia compatibility).
#   3. Runs STEPS=3 CONF_DIR=/etc/amnezia sh /root/cutover/install-amnezia-pbr.sh
#      inside the VM. With no pbr the STEPS=3 dispatch calls --first-install.
#   4. Asserts end state A–D:
#        A: fwmark ip rules at pref 31000/31001 (vpn_sticky/vpn_pool)
#        B: no WAN leak (marked traffic → tunnel or blackhole, never wan)
#        C: amnezia_classify nft chain is live with pool-mark set rule
#        D: vpn masquerade zone present in UCI/nft
#      Checks E and F are NOT applicable (no pbr to remove; no block_quic
#      pre-staged in first-install mode; first_install_wiring does not create it).
#
# Exit code: 0 = all PASS, 1 = one or more FAIL.
# POSIX sh; runs on the macOS HOST.

set -eu
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/lib.sh"
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/assert.sh"

VM_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

log() { echo "[test-first-install] $*"; }
die() { echo "[test-first-install] FATAL: $*" >&2; exit 1; }

# Verify SSH connectivity.
"$VM_DIR/vm-ssh.sh" 'echo ok' | grep -q '^ok$' || \
  die "VM not reachable over SSH -- is the VM booted and provisioned with --first-install?"

# Verify pbr is NOT present (pre-condition for the first-install path).
log "=== Pre-condition: pbr must NOT be installed ==="
_pbr=$(vm_run "opkg list-installed 2>/dev/null | grep '^pbr '" 2>/dev/null || true)
if [ -n "$_pbr" ]; then
  die "pbr is installed ($_pbr) — installer will run --migrate instead of first_install. Use provision.sh --first-install to get a clean state."
fi
log "OK: pbr absent -- installer will take the first_install path"

# Pre-seed amnezia_ru4 so configure-dnsmasq-amnezia does not abort.
# The first-install STEPS=3 path runs configure-dnsmasq-amnezia.sh which
# may reference the amnezia_ru4 nft set; ensure the set exists and is
# non-empty so any gate checks pass.
log "=== Pre-seeding amnezia_ru4 nft set ==="
# shellcheck disable=SC2086
ssh $VM_SSH_OPTS "root@$SSH_HOST" '
  nft add table inet fw4 2>/dev/null || true
  nft add set inet fw4 amnezia_ru4 \
    "{ type ipv4_addr; flags interval; auto-merge; }" 2>/dev/null || true
  nft add element inet fw4 amnezia_ru4 { 77.88.8.8 } 2>/dev/null || true
  nft list set inet fw4 amnezia_ru4 2>/dev/null | grep -c elements || echo 0
' || log "WARN: amnezia_ru4 pre-seed had errors (may be non-fatal)"

log "=== Running installer --first-install inside VM ==="
# Invoke the installer with --first-install, NOT STEPS=3.
#
# STEPS=3 is the PRODUCTION path used when a real awg.conf exists: it runs
# Step 1 (AWG UCI + kmod install, requires /etc/amnezia/awg.conf with real
# keys), then Step 2 (dnsmasq-full), then Step 3 (detect pbr/no-pbr dispatch).
# In Tier 1 (dummy interfaces, no real WG keys) we have no awg.conf, so the
# STEPS=3 path fails at the preflight check ("missing AWG config"). This is
# EXPECTED behaviour — STEPS=3 is not designed for keyless harness runs.
#
# --first-install invokes first_install_wiring() directly: it installs the
# classifier, ip rules, amnezia-failover monitor, and firewall zones without
# touching AWG keys or kmod install. This is what Step 3 of the STEPS=3 path
# calls internally when it detects no pbr, so we exercise the exact same wiring
# logic in isolation.
#
# CONF_DIR=/etc/amnezia points to the pre-staged amnezia UCI config.
# shellcheck disable=SC2086
ssh $VM_SSH_OPTS "root@$SSH_HOST" \
  'CONF_DIR=/etc/amnezia sh /root/cutover/install-amnezia-pbr.sh --first-install 2>&1' \
  && log "installer --first-install returned 0" \
  || log "WARN: installer --first-install returned non-zero (assertions may clarify)"

log "=== ip rules AFTER first_install ==="
vm_run "echo '=== ip rule show AFTER first_install ==='; ip rule show" 2>/dev/null || true

log "=== Assertions A–D ==="

# ── A. ip rules present ───────────────────────────────────────────────────────
log "A: ip rules (fwmark→table for vpn_sticky/vpn_pool)"
assert_ip_rules_present

# ── B. no WAN leak ────────────────────────────────────────────────────────────
log "B: no WAN leak"
assert_no_wan_leak

# ── C. classifier live ────────────────────────────────────────────────────────
log "C: nft classifier (amnezia_classify chain)"
assert_classifier_live

# ── D. vpn masquerade zone ────────────────────────────────────────────────────
log "D: vpn zone with masquerade"
assert_vpn_zone_masq

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
