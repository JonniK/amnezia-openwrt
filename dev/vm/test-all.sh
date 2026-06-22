#!/bin/sh
# Orchestrator: runs BOTH test scenarios end-to-end, each from a fresh disk.
#
#   SCENARIO 1 — MIGRATE:
#     fetch-image.sh (fresh disk) → run-vm.sh → provision.sh (pbr mode)
#     → test-migrate.sh
#
#   SCENARIO 2 — FIRST INSTALL:
#     fetch-image.sh (fresh disk) → run-vm.sh → provision.sh --first-install
#     → test-first-install.sh
#
# Both scenarios always run. No flags needed.
#
# console_bootstrap() in provision.sh handles the serial-console activation
# and polls SSH until it's up; test-all.sh does not need its own boot-wait
# beyond what provision.sh already does.
#
# Usage:
#   test-all.sh            run both scenarios (always)
#   test-all.sh --reset    same, but also re-downloads the image (rarely needed)
#
# Exit code: 0 = all suites PASS, 1 = any FAIL.
# POSIX sh; runs on the macOS HOST.

set -eu
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/lib.sh"

VM_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

log()  { echo "[test-all] $*"; }
die()  { echo "[test-all] FATAL: $*" >&2; exit 1; }
warn() { echo "[test-all] WARN: $*"; }

# Parse args.
FORCE_RESET=0
for _arg in "$@"; do
  case "$_arg" in
    --reset) FORCE_RESET=1 ;;
    *) warn "unknown argument: $_arg (ignoring)" ;;
  esac
done

SUITE_MIGRATE_RC=0
SUITE_FIRST_RC=0
SUITE_TUNNEL_MGMT_RC=0
SUITE_AUTOLEARN_RC=0
_T0=$(date +%s)

# ── helpers ──────────────────────────────────────────────────────────────────

stop_vm() {
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    log "stopping VM (pid $(cat "$PIDFILE"))"
    kill "$(cat "$PIDFILE")" 2>/dev/null || true
    # Allow a moment for QEMU to release port 2222 before the next boot.
    sleep 3
    rm -f "$PIDFILE" "$SERIAL_SOCK" "$MON_SOCK"
  else
    log "no running VM to stop"
    rm -f "$PIDFILE" "$SERIAL_SOCK" "$MON_SOCK" 2>/dev/null || true
  fi
}

# fresh_disk: fetch-image.sh recreates the qcow2 overlay from the pristine
# raw image (fast; no re-download unless FORCE_RESET is set and the raw is
# absent). This resets the VM rootfs to the factory OpenWrt state.
fresh_disk() {
  _scenario="${1:-}"
  log "--- resetting disk for: ${_scenario} ---"
  if [ "$FORCE_RESET" = 1 ] || [ ! -f "$IMG_RAW" ]; then
    log "running fetch-image.sh (full reset / first run)"
    "$VM_DIR/fetch-image.sh"
  else
    log "raw image present; recreating overlay only (fast reset)"
    # fetch-image.sh is idempotent: it always recreates the qcow2 even if the
    # raw image is already present, so calling it here is the canonical reset.
    "$VM_DIR/fetch-image.sh"
  fi
}

# boot_vm: start the VM in the background, brief settle, then let
# provision.sh's console_bootstrap drive the serial console + SSH setup.
boot_vm() {
  log "booting VM in background"
  "$VM_DIR/run-vm.sh" &
  # Give QEMU a moment to create the unix sockets before provision.sh tries
  # to open them. 5s is generous; QEMU creates them almost immediately.
  sleep 5
}

# elapsed: print seconds since _T0.
elapsed() { echo "$(( $(date +%s) - _T0 ))s"; }

# ── SCENARIO 1: MIGRATE ───────────────────────────────────────────────────────

log "======================================================"
log " SCENARIO 1: pbr -> failover MIGRATE"
log "======================================================"

stop_vm || true
fresh_disk "migrate"
boot_vm

log "provisioning VM to pbr pre-state (pbr mode)"
# provision.sh runs console_bootstrap internally (skips if SSH already up),
# installs pbr + deps, creates dummy tunnels, seeds pbr ip rules, pushes
# openwrt/ tree. This is the blocking step — it waits for SSH itself.
"$VM_DIR/provision.sh"

log "running test-migrate.sh"
_S1_START=$(date +%s)
"$VM_DIR/test-migrate.sh" && SUITE_MIGRATE_RC=0 || SUITE_MIGRATE_RC=$?
_S1_END=$(date +%s)
log "SCENARIO 1 finished in $(( _S1_END - _S1_START ))s, rc=${SUITE_MIGRATE_RC}"

# ── SCENARIO 2: FIRST INSTALL ─────────────────────────────────────────────────

log "======================================================"
log " SCENARIO 2: clean FIRST INSTALL (no pbr)"
log "======================================================"

stop_vm || true
fresh_disk "first-install"
boot_vm

log "provisioning VM to no-pbr state (first-install mode)"
# provision.sh --first-install: same bootstrap + opkg (EXCEPT pbr), same
# dummy tunnels + amnezia config, NO Phase D (no pbr ip rules).
# CRITICAL: do NOT install pbr here — the installer must see an absence of
# pbr to take the first_install branch in the STEPS=3 dispatch.
"$VM_DIR/provision.sh" --first-install

log "running test-first-install.sh"
_S2_START=$(date +%s)
"$VM_DIR/test-first-install.sh" && SUITE_FIRST_RC=0 || SUITE_FIRST_RC=$?
_S2_END=$(date +%s)
log "SCENARIO 2 finished in $(( _S2_END - _S2_START ))s, rc=${SUITE_FIRST_RC}"

stop_vm || true

# ── SCENARIO 3: PHASE G — TUNNEL MGMT + ALLOWLIST ────────────────────────────

log "======================================================"
log " SCENARIO 3: Phase G tunnel-mgmt + allowlist"
log "======================================================"

fresh_disk "tunnel-mgmt"
boot_vm

log "provisioning VM to no-pbr state (first-install mode)"
"$VM_DIR/provision.sh" --first-install

log "pre-seeding amnezia_ru4 nft set (gate pass for installer)"
# shellcheck disable=SC2086
ssh $VM_SSH_OPTS "root@$SSH_HOST" '
  nft add table inet fw4 2>/dev/null || true
  nft add set inet fw4 amnezia_ru4 "{ type ipv4_addr; flags interval; auto-merge; }" 2>/dev/null || true
  nft add element inet fw4 amnezia_ru4 { 77.88.8.8 } 2>/dev/null || true
' 2>/dev/null || log "WARN: amnezia_ru4 pre-seed had errors (may be non-fatal)"

log "running installer --first-install to install the full stack"
# shellcheck disable=SC2086
ssh $VM_SSH_OPTS "root@$SSH_HOST" \
  'CONF_DIR=/etc/amnezia sh /root/cutover/install-amnezia-pbr.sh --first-install 2>&1' \
  || log "WARN: installer returned non-zero (assertions in test-tunnel-mgmt.sh will clarify)"

log "running test-tunnel-mgmt.sh"
_S3_START=$(date +%s)
"$VM_DIR/test-tunnel-mgmt.sh" && SUITE_TUNNEL_MGMT_RC=0 || SUITE_TUNNEL_MGMT_RC=$?
_S3_END=$(date +%s)
log "SCENARIO 3 finished in $(( _S3_END - _S3_START ))s, rc=${SUITE_TUNNEL_MGMT_RC}"

stop_vm || true

# ── SCENARIO 4: PHASE 10 — AUTOLEARN DIRECT-DEFAULT LEARNING ─────────────────

log "======================================================"
log " SCENARIO 4: Phase 10 autolearn direct-default learning"
log "======================================================"

fresh_disk "autolearn"
boot_vm

log "provisioning VM to no-pbr state (first-install mode)"
"$VM_DIR/provision.sh" --first-install

log "pre-seeding amnezia_ru4 nft set (gate pass for installer)"
# shellcheck disable=SC2086
ssh $VM_SSH_OPTS "root@$SSH_HOST" '
  nft add table inet fw4 2>/dev/null || true
  nft add set inet fw4 amnezia_ru4 "{ type ipv4_addr; flags interval; auto-merge; }" 2>/dev/null || true
  nft add element inet fw4 amnezia_ru4 { 77.88.8.8 } 2>/dev/null || true
' 2>/dev/null || log "WARN: amnezia_ru4 pre-seed had errors (may be non-fatal)"

log "running installer --first-install to install the full stack"
# shellcheck disable=SC2086
ssh $VM_SSH_OPTS "root@$SSH_HOST" \
  'CONF_DIR=/etc/amnezia sh /root/cutover/install-amnezia-pbr.sh --first-install 2>&1' \
  || log "WARN: installer returned non-zero (assertions in test-autolearn.sh will clarify)"

log "running test-autolearn.sh"
_S4_START=$(date +%s)
"$VM_DIR/test-autolearn.sh" && SUITE_AUTOLEARN_RC=0 || SUITE_AUTOLEARN_RC=$?
_S4_END=$(date +%s)
log "SCENARIO 4 finished in $(( _S4_END - _S4_START ))s, rc=${SUITE_AUTOLEARN_RC}"

stop_vm || true

# ── Final summary ─────────────────────────────────────────────────────────────

_T1=$(date +%s)
_TOTAL=$(( _T1 - _T0 ))

echo ""
echo "======================================================"
echo " FINAL SUMMARY  (total wall-clock: ${_TOTAL}s)"
echo "======================================================"
_overall=0
if [ "$SUITE_MIGRATE_RC" -eq 0 ]; then
  echo "  SCENARIO 1 (migrate):        PASS"
else
  echo "  SCENARIO 1 (migrate):        FAIL (rc=$SUITE_MIGRATE_RC)"
  _overall=1
fi
if [ "$SUITE_FIRST_RC" -eq 0 ]; then
  echo "  SCENARIO 2 (first-install):  PASS"
else
  echo "  SCENARIO 2 (first-install):  FAIL (rc=$SUITE_FIRST_RC)"
  _overall=1
fi
if [ "$SUITE_TUNNEL_MGMT_RC" -eq 0 ]; then
  echo "  SCENARIO 3 (tunnel-mgmt):   PASS"
else
  echo "  SCENARIO 3 (tunnel-mgmt):   FAIL (rc=$SUITE_TUNNEL_MGMT_RC)"
  _overall=1
fi
if [ "$SUITE_AUTOLEARN_RC" -eq 0 ]; then
  echo "  SCENARIO 4 (autolearn):      PASS"
else
  echo "  SCENARIO 4 (autolearn):      FAIL (rc=$SUITE_AUTOLEARN_RC)"
  _overall=1
fi
if [ "$_overall" -eq 0 ]; then
  echo "  OVERALL:                     PASS"
else
  echo "  OVERALL:                     FAIL"
fi
echo "======================================================"

exit "$_overall"
