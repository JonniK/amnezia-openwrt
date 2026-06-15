#!/bin/sh
# Test the clean first_install_wiring path (no pbr present).
#
# Runs against a VM that has been provisioned WITHOUT the pbr pre-state.
# The easiest way to get a clean VM is to run fetch-image.sh first (fresh
# overlay disk) and then skip the pbr install steps in provision.sh, or
# re-run fetch-image.sh then run-vm.sh + a stripped-down provision that
# only does SSH setup + openwrt/ push (no pbr install, no pbr enable).
#
# Asserts the same end-state A–D as test-migrate.sh (no check E or F since
# there is no pbr to remove and no amnezia_block_quic to preserve here).
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
  die "VM not reachable over SSH -- is the VM booted and SSH configured?"

# Verify pbr is NOT present (pre-condition for the first-install path).
_pbr=$(vm_run "opkg list-installed 2>/dev/null | grep '^pbr '" 2>/dev/null || true)
if [ -n "$_pbr" ]; then
  log "WARN: pbr is installed -- installer will detect it and run --migrate instead of --first-install."
  log "      For the clean first-install test, use a fresh VM disk (fetch-image.sh to reset)."
  log "      Continuing anyway; check that the installer path taken is --first-install."
fi

log "=== Phase: pre-seed amnezia config + dummy tunnels ==="

# Write /etc/config/amnezia for the first-install case.
log "writing /etc/config/amnezia (failover, awg1+awg2)"
ssh $VM_SSH_OPTS "root@$SSH_HOST" "mkdir -p /etc/amnezia"
ssh $VM_SSH_OPTS "root@$SSH_HOST" 'cat > /etc/config/amnezia << '"'"'UCI_EOF'"'"'
config amnezia '"'"'config'"'"'
	option routing_mode '"'"'tunnel-default'"'"'

config globals '"'"'globals'"'"'
	option mode '"'"'failover'"'"'
	option sticky_target '"'"'awg1'"'"'

config tunnel '"'"'awg1'"'"'
	option enabled '"'"'1'"'"'
	option label '"'"'Primary'"'"'
	option metric '"'"'1'"'"'
	option weight '"'"'1'"'"'

config tunnel '"'"'awg2'"'"'
	option enabled '"'"'1'"'"'
	option label '"'"'Secondary'"'"'
	option metric '"'"'2'"'"'
	option weight '"'"'1'"'"'
UCI_EOF
'

# Create dummy tunnel interfaces (same as provision.sh).
log "creating dummy interfaces awg1 awg2"
ssh $VM_SSH_OPTS "root@$SSH_HOST" '
  ip link add awg1 type dummy 2>/dev/null || true
  ip addr add 10.8.1.15/32 dev awg1 2>/dev/null || true
  ip link set awg1 up 2>/dev/null || true
  ip link add awg2 type dummy 2>/dev/null || true
  ip addr add 10.8.1.4/32 dev awg2 2>/dev/null || true
  ip link set awg2 up 2>/dev/null || true
'

# Pre-seed amnezia_ru4 so configure-dnsmasq-amnezia doesn't abort the wiring.
# The first-install path calls routing_firewall_apply and routing_install_rules
# without a gate check, so the ru4 pre-seed is less critical here; but
# configure-dnsmasq-amnezia may still reference the set.
log "pre-seeding amnezia_ru4 (for configure-dnsmasq-amnezia compatibility)"
ssh $VM_SSH_OPTS "root@$SSH_HOST" '
  nft add table inet fw4 2>/dev/null || true
  nft add set inet fw4 amnezia_ru4 \
    "{ type ipv4_addr; flags interval; auto-merge; }" 2>/dev/null || true
  nft add element inet fw4 amnezia_ru4 { 77.88.8.8 } 2>/dev/null || true
'

log "=== Running installer --first-install inside VM ==="

# shellcheck disable=SC2086
ssh $VM_SSH_OPTS "root@$SSH_HOST" \
  'CONF_DIR=/etc/amnezia sh /root/cutover/install-amnezia-pbr.sh --first-install 2>&1' \
  && log "installer --first-install returned 0" \
  || log "WARN: installer --first-install returned non-zero (assertions may clarify)"

log "=== Assertions A–D ==="

# ── A. ip rules present ───────────────────────────────────────────────────────
log "A: ip rules"
assert_ip_rules_present

# ── B. no WAN leak ────────────────────────────────────────────────────────────
log "B: no WAN leak"
assert_no_wan_leak

# ── C. classifier live ────────────────────────────────────────────────────────
log "C: nft classifier"
assert_classifier_live

# ── D. vpn masquerade zone ────────────────────────────────────────────────────
log "D: vpn zone with masquerade"
assert_vpn_zone_masq

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
