#!/bin/sh
# Orchestrator: runs the full test pipeline end-to-end.
#
#   fetch-image.sh  (if disk missing or --reset)
#   run-vm.sh &     (boot headless)
#   wait for SSH    (poll with timeout)
#   provision.sh    (pbr pre-state)
#   test-migrate.sh (regression suite)
#   [optional] reset + test-first-install.sh
#
# Usage:
#   test-all.sh               run migrate test only
#   test-all.sh --all         run migrate + first-install test
#   test-all.sh --reset       re-fetch image even if disk exists
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
RUN_FIRST_INSTALL=0
FORCE_RESET=0
for _arg in "$@"; do
  case "$_arg" in
    --all)   RUN_FIRST_INSTALL=1 ;;
    --reset) FORCE_RESET=1 ;;
    *) warn "unknown argument: $_arg (ignoring)" ;;
  esac
done

SUITE_MIGRATE_RC=0
SUITE_FIRST_RC=0

# ── helpers ──────────────────────────────────────────────────────────────────

stop_vm() {
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    log "stopping VM (pid $(cat "$PIDFILE"))"
    kill "$(cat "$PIDFILE")" 2>/dev/null || true
    sleep 2
    rm -f "$PIDFILE" "$SERIAL_SOCK" "$MON_SOCK"
  fi
}

wait_for_ssh() {
  _deadline="${1:-90}"
  _elapsed=0
  log "waiting up to ${_deadline}s for SSH on $SSH_HOST:$SSH_PORT..."
  while [ "$_elapsed" -lt "$_deadline" ]; do
    # shellcheck disable=SC2086
    if ssh $VM_SSH_OPTS "root@$SSH_HOST" 'echo ok' 2>/dev/null | grep -q '^ok$'; then
      log "SSH up after ${_elapsed}s"
      return 0
    fi
    sleep 3
    _elapsed=$((_elapsed + 3))
  done
  return 1
}

fresh_vm() {
  _label="${1:-}"
  log "--- fresh VM for: ${_label} ---"
  stop_vm || true
  # Reset the overlay disk so each scenario starts from a clean rootfs.
  log "resetting VM disk (fetch-image.sh)"
  "$VM_DIR/fetch-image.sh"
  log "booting VM in background"
  "$VM_DIR/run-vm.sh" &
  _vm_bg_pid=$!
  # Brief wait for QEMU to create the sockets before we start polling.
  sleep 5
  wait_for_ssh 120 || {
    log "SSH did not come up; checking if VM is still running"
    if ! kill -0 "$_vm_bg_pid" 2>/dev/null; then
      die "VM process exited unexpectedly"
    fi
    die "SSH timeout; check serial log: $SERIAL_LOG"
  }
}

# ── Migrate test suite ────────────────────────────────────────────────────────

log "======================================================"
log " SCENARIO 1: pbr -> failover MIGRATE"
log "======================================================"

# Fetch image if disk is missing or --reset requested.
if [ ! -f "$DISK" ] || [ "$FORCE_RESET" = 1 ]; then
  log "fetching/resetting image"
  "$VM_DIR/fetch-image.sh"
fi

# Boot VM if not running.
if [ ! -f "$PIDFILE" ] || ! kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  log "booting VM"
  "$VM_DIR/run-vm.sh" &
  sleep 5
fi

wait_for_ssh 120 || {
  # VM may not have SSH yet because provision.sh hasn't run.
  log "SSH not up yet; running provision.sh to set up WAN + key"
  "$VM_DIR/provision.sh"
  wait_for_ssh 60 || die "SSH still not up after provision.sh"
}

# If SSH was already up (re-run scenario), provision anyway (idempotent).
log "provisioning VM to pbr pre-state"
"$VM_DIR/provision.sh"

log "running test-migrate.sh"
"$VM_DIR/test-migrate.sh" && SUITE_MIGRATE_RC=0 || SUITE_MIGRATE_RC=$?

# ── First-install test suite (optional) ───────────────────────────────────────

if [ "$RUN_FIRST_INSTALL" = 1 ]; then
  log "======================================================"
  log " SCENARIO 2: clean FIRST INSTALL (no pbr)"
  log "======================================================"

  # Reset to a fresh disk for the clean-install scenario.
  fresh_vm "first-install"

  # Minimal provision: SSH key + openwrt/ push, no pbr install.
  # Inline the essential steps here rather than calling full provision.sh
  # (which installs pbr, which would put us on the migrate path again).
  log "SSH keypair check"
  [ -f "$SSH_KEY" ] || ssh-keygen -t ed25519 -N '' -f "$SSH_KEY" >/dev/null

  log "pushing openwrt/ tree to VM"
  # shellcheck disable=SC2086
  ssh $VM_SSH_OPTS "root@$SSH_HOST" "mkdir -p /root/cutover /usr/lib/amnezia"
  cd "$REPO_ROOT"
  tar cf - openwrt/ | \
    ssh $VM_SSH_OPTS "root@$SSH_HOST" \
    "cd /root/cutover && tar xf - --strip-components=1 2>/dev/null && echo 'tar done'"
  # shellcheck disable=SC2086
  cat "$REPO_ROOT/openwrt/lib/amnezia-common.sh" | \
    ssh $VM_SSH_OPTS "root@$SSH_HOST" "cat > /usr/lib/amnezia/amnezia-common.sh"
  # shellcheck disable=SC2086
  cat "$REPO_ROOT/openwrt/lib/amnezia-routing.sh" | \
    ssh $VM_SSH_OPTS "root@$SSH_HOST" "cat > /usr/lib/amnezia/amnezia-routing.sh"
  # shellcheck disable=SC2086
  ssh $VM_SSH_OPTS "root@$SSH_HOST" \
    "chmod +x /root/cutover/install-amnezia-pbr.sh 2>/dev/null || true"

  log "running test-first-install.sh"
  "$VM_DIR/test-first-install.sh" && SUITE_FIRST_RC=0 || SUITE_FIRST_RC=$?
fi

# ── Final summary ─────────────────────────────────────────────────────────────

echo ""
echo "======================================================"
echo " FINAL SUMMARY"
echo "======================================================"
_overall=0
if [ "$SUITE_MIGRATE_RC" -eq 0 ]; then
  echo "  SCENARIO 1 (migrate):        PASS"
else
  echo "  SCENARIO 1 (migrate):        FAIL (rc=$SUITE_MIGRATE_RC)"
  _overall=1
fi
if [ "$RUN_FIRST_INSTALL" = 1 ]; then
  if [ "$SUITE_FIRST_RC" -eq 0 ]; then
    echo "  SCENARIO 2 (first-install):  PASS"
  else
    echo "  SCENARIO 2 (first-install):  FAIL (rc=$SUITE_FIRST_RC)"
    _overall=1
  fi
fi
echo "======================================================"

exit "$_overall"
