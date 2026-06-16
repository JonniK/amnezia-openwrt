#!/bin/sh
# deploy-cutover.sh — host-side launcher for the autonomous router cutover.
# One command to:
#   1. Pre-flight: verify router is in the expected pbr-active/amnezia-ready state.
#   2. Prep: ensure tunnel confs + build amnezia UCI (idempotent, keep-if-present).
#   3. Stage: push openwrt/ tree + router-cutover.sh to the router.
#   4. Launch: setsid-detached so the script survives SSH drops AND rollback reboots.
#   5. Poll: reconnect loop tolerant of SSH drops AND the rollback reboot.
#   6. Print: final RESULT + log tail.
#
# Usage:
#   SSH_HOST=openWRT ./dev/deploy-cutover.sh
#   SSH_HOST=openWRT SKIP_DATAPLANE=1 ./dev/deploy-cutover.sh
#
# SSH_HOST defaults to the user's 'openWRT' alias (see memory context).
# Do NOT hardcode credentials — the router must already have your key in
# authorized_keys.
#
# VM targeting (for validation):
#   SSH_HOST=root@127.0.0.1 \
#   SSH_OPTS="-p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -i $PWD/dev/vm/run/id_vmtest" \
#   SKIP_DATAPLANE=1 ./dev/deploy-cutover.sh
#
# POSIX sh; runs on the macOS host.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

SSH_HOST="${SSH_HOST:-openWRT}"
SKIP_DATAPLANE="${SKIP_DATAPLANE:-0}"
# How long (in 5-second ticks) to wait for RESULT: token — ~5 minutes.
POLL_MAX="${POLL_MAX:-60}"

RESULT_LOG_REMOTE=/root/cutover-result.log
LOGS_DIR="$SCRIPT_DIR/logs"

# SSH_OPTS: overridable for VM targeting.  Default: production router settings.
SSH_OPTS="${SSH_OPTS:--o ConnectTimeout=8 -o BatchMode=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o LogLevel=ERROR}"

# Tunnel conf sources (host-side).  Override via env.
AWG1_CONF="${AWG1_CONF:-$REPO_ROOT/local/awg.conf}"
AWG2_CONF="${AWG2_CONF:-$REPO_ROOT/local/awg2.conf}"

# amnezia UCI defaults — override via env for non-default deployments.
AMZ_MODE="${AMZ_MODE:-failover}"
AMZ_STICKY="${AMZ_STICKY:-awg1}"
TRACK_IP="${TRACK_IP:-1.1.1.1}"

log()  { echo "[deploy-cutover] $*"; }
die()  { echo "[deploy-cutover] FATAL: $*" >&2; exit 1; }
warn() { echo "[deploy-cutover] WARN: $*"; }

ssh_run() {
    # shellcheck disable=SC2086
    ssh $SSH_OPTS "$SSH_HOST" "$1"
}

# ssh_ok: return 0 if router reachable over SSH.
ssh_ok() {
    # shellcheck disable=SC2086
    ssh $SSH_OPTS "$SSH_HOST" 'true' 2>/dev/null
}

# ssh_wait <max_ticks> <tick_seconds>: poll until SSH is up or timeout.
ssh_wait() {
    _max="${1:-60}"; _tick="${2:-5}"
    _n=0
    while [ "$_n" -lt "$_max" ]; do
        ssh_ok && return 0
        _n=$((_n + 1))
        printf '  [%s/%s] waiting for %s...\n' "$_n" "$_max" "$SSH_HOST"
        sleep "$_tick"
    done
    return 1
}

# ===========================================================================
# 0. Basic reachability + pbr/internet checks (before prep)
# ===========================================================================
log "=== Pre-flight (basic) ==="

log "checking SSH reachability..."
ssh_wait 6 5 || die "router $SSH_HOST not reachable over SSH"

log "running basic remote pre-flight checks..."
ssh_run 'sh -s' <<'BASIC_PREFLIGHT' || die "basic pre-flight failed — see output above"
set -eu

_fail() { echo "PREFLIGHT FAIL: $*" >&2; exit 1; }
_ok()   { echo "PREFLIGHT OK: $*"; }

# 1a) pbr installed and enabled
if opkg list-installed 2>/dev/null | grep -q '^pbr '; then
    _ok "pbr installed"
else
    _fail "pbr is not installed (expected pre-state: pbr active)"
fi
if /etc/init.d/pbr enabled 2>/dev/null; then
    _ok "pbr enabled"
else
    _fail "pbr is not enabled (/etc/init.d/pbr enabled returned non-zero)"
fi

# 1b) internet connectivity (WAN up)
if ping -c 2 -W 3 1.1.1.1 >/dev/null 2>&1; then
    _ok "internet reachable (1.1.1.1)"
else
    _fail "no internet (ping 1.1.1.1 failed)"
fi

# 1e) classifier absent (this is the pre-migrate state)
if [ -f /etc/nftables.d/30-amnezia-classify.nft ]; then
    _fail "30-amnezia-classify.nft already present — migrate already ran or partial state"
fi
_ok "classifier absent (pre-migrate)"

echo "PREFLIGHT BASIC: all checks passed"
BASIC_PREFLIGHT

log "basic pre-flight passed"

# ===========================================================================
# prep_prestate: ensure tunnel confs + build amnezia UCI (idempotent).
# Runs BEFORE the amnezia-specific assertions so those assertions then PASS.
# ===========================================================================
prep_prestate() {
    log "=== Prep: pre-state ==="

    # ── 1. Tunnel confs: keep-if-present, push from host if absent ────────────
    for _entry in "awg1:$AWG1_CONF" "awg2:$AWG2_CONF"; do
        _name="${_entry%%:*}"
        _src="${_entry#*:}"
        _remote="/etc/amnezia/${_name}.conf"

        # Check if conf already exists on router.
        if ssh_run "test -f '$_remote' && echo exists" 2>/dev/null | grep -q exists; then
            log "prep: ${_remote} already present on router — keeping (not clobbering)"
            continue
        fi

        # Conf absent on router — need to push from host.
        if [ ! -f "$_src" ]; then
            die "prep: ${_remote} absent on router AND host source missing: ${_src}
Set ${_name%%[0-9]*^^}$(echo "$_name" | tr '[:lower:]' '[:upper:]')_CONF env to the path of the conf file."
        fi

        log "prep: pushing ${_src} → ${_remote} (never printing contents)"
        ssh_run "mkdir -p /etc/amnezia"
        # shellcheck disable=SC2086
        cat "$_src" | ssh $SSH_OPTS "$SSH_HOST" "cat > '${_remote}'"
        log "prep: ${_remote} pushed"
    done

    # ── 2. Build amnezia UCI idempotently ────────────────────────────────────
    # Preserve amnezia.config section; build globals + awg1 + awg2.
    log "prep: building amnezia UCI (globals + awg1 + awg2)..."
    # Pass env vars as shell assignments so the heredoc can expand them on the router.
    ssh_run "sh -s -- '$AMZ_MODE' '$AMZ_STICKY' '$TRACK_IP'" <<'UCI_BUILD'
set -eu
_mode="$1"
_sticky="$2"
_track="$3"

uci batch <<UCIEOF
set amnezia.globals=globals
set amnezia.globals.mode=${_mode}
set amnezia.globals.sticky_target=${_sticky}
set amnezia.awg1=tunnel
set amnezia.awg1.enabled=1
set amnezia.awg1.metric=1
set amnezia.awg1.weight=1
set amnezia.awg1.track_ip=${_track}
set amnezia.awg2=tunnel
set amnezia.awg2.enabled=1
set amnezia.awg2.metric=2
set amnezia.awg2.weight=1
set amnezia.awg2.track_ip=${_track}
UCIEOF

uci commit amnezia
echo "UCI: amnezia committed"
uci show amnezia
UCI_BUILD

    log "prep: amnezia UCI built"
    log "=== Prep: complete ==="
}

prep_prestate

# ===========================================================================
# 1. Amnezia-specific pre-flight assertions (now guaranteed to pass after prep)
# ===========================================================================
log "=== Pre-flight (amnezia state) ==="

ssh_run 'sh -s' <<'AMZ_PREFLIGHT' || die "amnezia pre-flight failed — see output above"
set -eu

_fail() { echo "PREFLIGHT FAIL: $*" >&2; exit 1; }
_ok()   { echo "PREFLIGHT OK: $*"; }

# 1c) amnezia UCI present (globals + awg1 + awg2 enabled)
_amz=$(uci show amnezia 2>/dev/null || true)
if [ -z "$_amz" ]; then
    _fail "uci show amnezia returned nothing — /etc/config/amnezia missing"
fi
if echo "$_amz" | grep -q 'globals'; then
    _ok "amnezia.globals present"
else
    _fail "amnezia.globals section missing from /etc/config/amnezia"
fi
for _t in awg1 awg2; do
    if echo "$_amz" | grep -qE "amnezia.${_t}.enabled='?1"; then
        _ok "amnezia.${_t}.enabled=1"
    else
        _fail "amnezia.${_t}.enabled=1 not found in uci show amnezia"
    fi
done

# 1d) /etc/amnezia/awg{1,2}.conf present
for _cf in /etc/amnezia/awg1.conf /etc/amnezia/awg2.conf; do
    if [ -f "$_cf" ]; then
        _ok "$_cf present"
    else
        _fail "$_cf missing — required for migrate"
    fi
done

echo "PREFLIGHT AMZ: all checks passed"
AMZ_PREFLIGHT

log "amnezia pre-flight passed"

# ===========================================================================
# 2. Stage files
# ===========================================================================
log "=== Staging ==="

# Push the full openwrt/ tree to /root/cutover (same as provision.sh does for VM).
log "staging openwrt/ tree to /root/cutover..."
ssh_run "mkdir -p /root/cutover /usr/lib/amnezia"

_tar_tmp=$(mktemp)
cd "$REPO_ROOT"
tar czf "$_tar_tmp" openwrt/
_sz=$(wc -c < "$_tar_tmp" | tr -d ' ')
log "tar size: ${_sz} bytes"
# shellcheck disable=SC2086
cat "$_tar_tmp" | ssh $SSH_OPTS "$SSH_HOST" \
    "cat > /tmp/cutover-stage.tar.gz && \
     mkdir -p /tmp/_cutover_src && \
     cd /tmp/_cutover_src && \
     tar xzf /tmp/cutover-stage.tar.gz && \
     cp -r openwrt/* /root/cutover/ && \
     rm -rf /tmp/_cutover_src /tmp/cutover-stage.tar.gz && \
     echo 'tree staged'"
rm -f "$_tar_tmp"

# Refresh the shared lib at the installed path.
# shellcheck disable=SC2086
cat "$REPO_ROOT/openwrt/lib/amnezia-common.sh" \
    | ssh $SSH_OPTS "$SSH_HOST" "cat > /usr/lib/amnezia/amnezia-common.sh"
# shellcheck disable=SC2086
cat "$REPO_ROOT/openwrt/lib/amnezia-routing.sh" \
    | ssh $SSH_OPTS "$SSH_HOST" "cat > /usr/lib/amnezia/amnezia-routing.sh"
log "libs refreshed at /usr/lib/amnezia/"

# Push router-cutover.sh.
# shellcheck disable=SC2086
cat "$SCRIPT_DIR/router-cutover.sh" \
    | ssh $SSH_OPTS "$SSH_HOST" "cat > /root/router-cutover.sh"
log "router-cutover.sh pushed to /root/"

# Make executables.
ssh_run "chmod +x /root/router-cutover.sh /root/cutover/install-amnezia-pbr.sh 2>/dev/null || true"
ssh_run "chmod +x /root/cutover/*.sh 2>/dev/null || true"
ssh_run "chmod +x /root/cutover/amnezia-failover 2>/dev/null || true"
log "permissions set"

# Truncate any previous result log so polling starts clean.
ssh_run ": > $RESULT_LOG_REMOTE" 2>/dev/null || true
log "result log cleared: $RESULT_LOG_REMOTE"

# ===========================================================================
# 3. Launch detached
# ===========================================================================
log "=== Launching cutover (detached) ==="

_launch_cmd="SKIP_DATAPLANE=${SKIP_DATAPLANE} setsid sh /root/router-cutover.sh </dev/null >/dev/null 2>&1 & echo launched-pid:\$!"
_launched=$(ssh_run "$_launch_cmd" 2>/dev/null || true)
log "launch result: ${_launched}"

echo ""
echo "Cutover running on router.  Polling $RESULT_LOG_REMOTE for RESULT: token..."
echo "(safe to Ctrl-C — the router process is fully detached)"
echo ""

# ===========================================================================
# 4. Poll for RESULT: token — resilient to SSH drops and the rollback reboot
# ===========================================================================
log "=== Polling (max ${POLL_MAX} ticks x 5s = $(( POLL_MAX * 5 ))s) ==="

_tick=0
_last_tail=""
while [ "$_tick" -lt "$POLL_MAX" ]; do
    _tick=$((_tick + 1))

    # Try to connect; if router is rebooting (rollback), wait quietly.
    if ! ssh_ok 2>/dev/null; then
        printf '  [%s/%s] router not reachable (may be rebooting)...\n' "$_tick" "$POLL_MAX"
        sleep 5
        continue
    fi

    # Fetch the current tail of the result log.
    _tail=$(ssh_run "tail -5 $RESULT_LOG_REMOTE 2>/dev/null" 2>/dev/null || true)

    # Print new lines (avoid spamming identical output).
    if [ "$_tail" != "$_last_tail" ] && [ -n "$_tail" ]; then
        printf '%s\n' "$_tail"
        _last_tail="$_tail"
    fi

    # Check for terminal tokens.
    if echo "$_tail" | grep -q 'RESULT: SUCCESS'; then
        log "=== RESULT: SUCCESS ==="
        break
    elif echo "$_tail" | grep -q 'RESULT: ROLLED_BACK'; then
        log "=== RESULT: ROLLED_BACK ==="
        break
    elif echo "$_tail" | grep -q 'RESULT: ROLLBACK_FAILED'; then
        log "=== RESULT: ROLLBACK_FAILED ==="
        break
    elif echo "$_tail" | grep -q 'RESULT: BACKUP_FAILED'; then
        log "=== RESULT: BACKUP_FAILED (no changes made) ==="
        break
    fi

    sleep 5
done

# ===========================================================================
# 5. Print final result + log tail
# ===========================================================================
log "=== Final result ==="

# If router rebooted (ROLLED_BACK), give it extra time to come back.
if ! ssh_ok 2>/dev/null; then
    log "router not yet reachable — waiting up to 90s for post-rollback reboot..."
    ssh_wait 18 5 || warn "router still not reachable after 90s"
fi

echo ""
echo "---------- /root/cutover-result.log (last 30 lines) ----------"
ssh_run "tail -30 $RESULT_LOG_REMOTE 2>/dev/null" 2>/dev/null || true
echo "---------------------------------------------------------------"
echo ""

# Determine exit code from the log.
_final=$(ssh_run "grep '^RESULT:' $RESULT_LOG_REMOTE 2>/dev/null | tail -1" 2>/dev/null || true)
log "Final token: ${_final:-<not found>}"

# ---------------------------------------------------------------------------
# Pull the full persistent log back to the host — guaranteed to survive
# any subsequent router reboots or log rotation.
# ---------------------------------------------------------------------------
_log_stamp=$(date -u +%Y%m%dT%H%M%SZ)
_local_log="${LOGS_DIR}/cutover-${_log_stamp}.log"
mkdir -p "$LOGS_DIR"
# shellcheck disable=SC2086
if ssh $SSH_OPTS "$SSH_HOST" "cat $RESULT_LOG_REMOTE" > "$_local_log" 2>/dev/null; then
    log "Full router log saved to: ${_local_log}"
else
    warn "Could not pull router log — router may not be reachable; partial log at: ${_local_log}"
fi

case "$_final" in
    "RESULT: SUCCESS")
        echo "CUTOVER SUCCEEDED — new failover stack is live."
        exit 0
        ;;
    "RESULT: ROLLED_BACK")
        echo "CUTOVER ROLLED BACK — router restored to pre-cutover state."
        echo "Check the log above for which verification check failed."
        exit 1
        ;;
    "RESULT: ROLLBACK_FAILED")
        echo "CUTOVER ROLLBACK FAILED — router may be in a degraded state!"
        echo "Manual intervention required: ssh $SSH_HOST"
        exit 2
        ;;
    "RESULT: BACKUP_FAILED")
        echo "BACKUP FAILED — no changes were made to the router."
        exit 1
        ;;
    *)
        echo "TIMEOUT or no RESULT token found in log."
        echo "Router may still be running the cutover."
        echo "Check: ssh $SSH_HOST 'tail -f $RESULT_LOG_REMOTE'"
        exit 1
        ;;
esac
