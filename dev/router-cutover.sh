#!/bin/sh
# router-cutover.sh — autonomous pbr→failover cutover with self-verification
# and automatic rollback on failure.  Runs ON the router, launched via setsid
# so it survives SSH disconnects.
#
# Persistent log: /root/cutover-result.log  (NOT /tmp — survives reboot).
# Final status token appended to log:
#   RESULT: SUCCESS | RESULT: ROLLED_BACK | RESULT: ROLLBACK_FAILED
#
# Data-plane checks (awg handshake, ping through tunnel) are enabled by default.
# Disable for VM testing of the structural (success) path:
#   SKIP_DATAPLANE=1 sh /root/router-cutover.sh
#
# POSIX sh / BusyBox ash compatible.
# shellcheck disable=SC2039,SC2169,SC2015

RESULT_LOG=/root/cutover-result.log
BACKUP_FILE=/root/cutover-rollback.tar.gz
CUTOVER_DIR=/root/cutover
SKIP_DATAPLANE="${SKIP_DATAPLANE:-0}"

# Redirect everything to the persistent log from here on out.
exec >> "$RESULT_LOG" 2>&1

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
ts()     { date '+%Y-%m-%dT%H:%M:%S'; }
log()    { printf '%s [cutover] %s\n' "$(ts)" "$*"; }
log_sep(){ printf '%s [cutover] ===== %s =====\n' "$(ts)" "$*"; }

# ---------------------------------------------------------------------------
# _redact: pipe helper — redacts long base64-like secrets (30+ chars).
# Applied to all snapshot / syslog output before appending to the log.
# ---------------------------------------------------------------------------
_redact() { sed 's#[A-Za-z0-9+/]\{30,\}#<REDACTED>#g'; }

# ---------------------------------------------------------------------------
# snapshot_state <label>
# Appends a labeled state dump (redacted) to the persistent log.
# Each command is wrapped so failures produce "(none)"/"(error)" rather than
# aborting the script.
# ---------------------------------------------------------------------------
snapshot_state() {
    _snap_label="$1"
    log_sep "SNAPSHOT: ${_snap_label}"

    log "[snap] ip rule show"
    ip rule show 2>/dev/null | _redact || echo "(none)"

    log "[snap] ip route show table main (head 20)"
    ip route show table main 2>/dev/null | head -20 | _redact || echo "(none)"

    log "[snap] ip route show table 100"
    ip route show table 100 2>/dev/null | _redact || echo "(none)"

    log "[snap] ip route show table 101"
    ip route show table 101 2>/dev/null | _redact || echo "(none)"

    log "[snap] ip route show table vpn_sticky"
    ip route show table vpn_sticky 2>/dev/null | _redact || echo "(none)"

    log "[snap] ip route show table vpn_pool"
    ip route show table vpn_pool 2>/dev/null | _redact || echo "(none)"

    log "[snap] nft list table inet fw4 (chains+sets)"
    nft list table inet fw4 2>/dev/null | _redact || echo "(none)"

    log "[snap] uci show amnezia"
    uci show amnezia 2>/dev/null | _redact || echo "(none)"

    log "[snap] uci show firewall"
    uci show firewall 2>/dev/null | _redact || echo "(none)"

    log "[snap] uci show network (head 60)"
    uci show network 2>/dev/null | head -60 | _redact || echo "(none)"

    log "[snap] opkg list-installed (amnezia/pbr)"
    opkg list-installed 2>/dev/null | grep -E 'pbr|amnezia' | _redact || echo "(none)"

    log "[snap] awg show"
    awg show 2>/dev/null | _redact || echo "(none)"

    log "[snap] ifstatus awg1"
    ifstatus awg1 2>/dev/null | _redact || echo "(none)"

    log "[snap] ifstatus awg2"
    ifstatus awg2 2>/dev/null | _redact || echo "(none)"

    log "[snap] pgrep amnezia-failover"
    pgrep -fa amnezia-failover 2>/dev/null | _redact || echo "(none)"

    log "[snap] /var/run/amnezia-failover.json"
    if [ -f /var/run/amnezia-failover.json ]; then
        _redact < /var/run/amnezia-failover.json || echo "(error)"
    else
        echo "(none)"
    fi

    log "[snap] /etc/init.d/pbr enabled state"
    if [ -x /etc/init.d/pbr ]; then
        /etc/init.d/pbr enabled 2>/dev/null && echo "pbr: enabled" || echo "pbr: disabled"
    else
        echo "pbr: /etc/init.d/pbr absent"
    fi

    log "[snap] ls /etc/nftables.d/"
    ls -l /etc/nftables.d/ 2>/dev/null || echo "(none)"

    log "[snap] ls /etc/init.d/amnezia-*"
    ls -l /etc/init.d/amnezia-* 2>/dev/null || echo "(none)"

    log "[snap] ls /usr/sbin/amnezia-failover"
    ls -l /usr/sbin/amnezia-failover 2>/dev/null || echo "(none)"

    log_sep "SNAPSHOT END: ${_snap_label}"
}

# ---------------------------------------------------------------------------
# capture_syslog <label>
# Appends recent amnezia/pbr/cutover/fw4/udhcp syslog lines (redacted) to log.
# Captures the LAST 300 matching lines — enough to cover a full migrate run.
# ---------------------------------------------------------------------------
capture_syslog() {
    _slog_label="$1"
    log_sep "SYSLOG: ${_slog_label}"
    logread 2>/dev/null \
        | grep -iE 'amnezia|pbr|cutover|fw4|udhcp' \
        | tail -300 \
        | _redact \
        || echo "(no syslog data)"
    log_sep "SYSLOG END: ${_slog_label}"
}

log_sep "START"
log "SKIP_DATAPLANE=${SKIP_DATAPLANE}"
snapshot_state "after-start"

# ---------------------------------------------------------------------------
# _PHASE tracker.  Updated before each major section so the EXIT trap knows
# whether we are in a state that requires rollback.
# ---------------------------------------------------------------------------
_PHASE="init"
_ROLLBACK_REASON=""

# ---------------------------------------------------------------------------
# inject_rc_local_kick — write a standalone one-shot pbr-kick script and
# insert a single-line launcher in /etc/rc.local before `exit 0`.
# The kick script self-deletes after it runs.
# Idempotent: checks for the sentinel comment before inserting.
# Called from do_rollback AFTER sysupgrade -r has restored /etc/rc.local.
# ---------------------------------------------------------------------------
inject_rc_local_kick() {
    _rclocal=/etc/rc.local
    _kick_script=/etc/amnezia-pbr-kick.sh

    if grep -q 'amnezia-pbr-kick' "$_rclocal" 2>/dev/null; then
        log "rollback: rc.local kick already present (idempotent)"
        return 0
    fi

    # Write the kick as a standalone shell script.
    # It waits up to 120 s for awg1 to get a fresh handshake, restarts pbr,
    # logs the event, then removes both itself and its rc.local entry.
    # Using a heredoc with a quoted delimiter: nothing expands here.
    cat > "$_kick_script" << 'KICK_EOF'
#!/bin/sh
# amnezia-pbr-kick: one-shot post-rollback pbr restart.  Self-deletes after run.
_i=0
while [ "$_i" -lt 24 ]; do
    _hs=$(awg show awg1 latest-handshakes 2>/dev/null | awk '{print $2}' | head -1)
    _now=$(date +%s)
    [ "${_hs:-0}" -gt 0 ] && [ $(( _now - _hs )) -lt 180 ] && break
    _i=$(( _i + 1 ))
    sleep 5
done
/etc/init.d/pbr enabled 2>/dev/null || /etc/init.d/pbr enable 2>/dev/null || true
/etc/init.d/pbr restart 2>/dev/null || true
logger -t amnezia-pbr-kick "post-rollback pbr restart done"
# Self-delete: strip our rc.local entry, then remove this script.
grep -v 'amnezia-pbr-kick' /etc/rc.local > /tmp/rc.local.amz.$$ 2>/dev/null \
    && mv /tmp/rc.local.amz.$$ /etc/rc.local
rm -f /etc/amnezia-pbr-kick.sh
KICK_EOF
    chmod +x "$_kick_script"

    # Insert a ONE-LINE background launcher before the first `exit 0`.
    _line="sh /etc/amnezia-pbr-kick.sh & # amnezia-pbr-kick one-shot"
    _tmp=/tmp/rc.local.cutover.$$
    awk -v line="$_line" '
        /^exit 0/ && !_done { print line; _done=1 }
        { print }
    ' "$_rclocal" > "$_tmp" 2>/dev/null && mv "$_tmp" "$_rclocal" 2>/dev/null || {
        printf '%s\n' "$_line" >> "$_rclocal"
    }
    log "rollback: rc.local one-shot pbr-kick injected (${_kick_script})"
}

# ---------------------------------------------------------------------------
# do_rollback — teardown new stack, restore backup, inject kick, reboot.
# Mirrors rollback-multitunnel.sh teardown logic exactly.
# Sets _PHASE="done" before returning/rebooting so the EXIT trap skips.
# ---------------------------------------------------------------------------
do_rollback() {
    log_sep "ROLLBACK: ${_ROLLBACK_REASON}"

    # Capture state and syslog BEFORE any teardown so the migrate trace is preserved.
    capture_syslog "pre-rollback"
    snapshot_state "pre-rollback"

    # 1) Stop + disable + remove failover-stack services.
    for _svc in amnezia-failover amnezia-ru-load; do
        if [ -x "/etc/init.d/${_svc}" ]; then
            "/etc/init.d/${_svc}" stop 2>/dev/null || true
            "/etc/init.d/${_svc}" disable 2>/dev/null || true
        fi
        rm -f "/etc/init.d/${_svc}" 2>/dev/null || true
        rm -f /etc/rc.d/*"${_svc}" 2>/dev/null || true
        log "rollback: service ${_svc} stopped/disabled/removed"
    done

    # 2) Remove new-stack files that sysupgrade -r will NOT delete
    #    (it only adds/overwrites, never removes files absent from the backup).
    rm -f /etc/nftables.d/30-amnezia-classify.nft \
          /etc/hotplug.d/firewall/99-amnezia-ru-load \
          /etc/iproute2/rt_tables.d/amnezia.conf \
          /var/run/amnezia-failover.json 2>/dev/null || true
    log "rollback: new-stack files removed"

    # 3) Tear down fwmark ip rules + flush routing tables 100/101.
    #    Loop a few times in case of duplicates.
    _i=0
    while [ "$_i" -lt 4 ]; do
        ip rule del fwmark 0x0a0000/0x0ff0000 2>/dev/null || true
        _i=$((_i + 1))
    done
    _i=0
    while [ "$_i" -lt 4 ]; do
        ip rule del fwmark 0x0b0000/0x0ff0000 2>/dev/null || true
        _i=$((_i + 1))
    done
    ip route flush table 100 2>/dev/null || true
    ip route flush table 101 2>/dev/null || true
    log "rollback: ip rules + tables 100/101 flushed"

    # 4) Restore config from on-router backup.
    log "rollback: sysupgrade -r $BACKUP_FILE"
    if sysupgrade -r "$BACKUP_FILE" 2>&1; then
        log "rollback: config restored from backup"
    else
        log "ERROR: sysupgrade -r failed — last-resort pbr restart in place"
        /etc/init.d/pbr enable 2>/dev/null || true
        /etc/init.d/pbr restart 2>/dev/null || true
        printf 'RESULT: ROLLBACK_FAILED\n' >> "$RESULT_LOG"
        _PHASE="done"
        return 1
    fi

    # 5) Ensure pbr is enabled in restored config.
    #    sysupgrade -r restores UCI config but NOT opkg-installed packages.
    #    If pbr init is absent (can happen when backup pre-dates the opkg install
    #    or on a VM), try opkg reinstall as a best-effort recovery.
    if [ -x /etc/init.d/pbr ]; then
        /etc/init.d/pbr enable 2>/dev/null || true
        log "rollback: pbr re-enabled (init present)"
    else
        log "rollback: /etc/init.d/pbr absent after sysupgrade -r — trying opkg reinstall"
        if opkg install pbr 2>&1; then
            /etc/init.d/pbr enable 2>/dev/null || true
            log "rollback: pbr reinstalled + re-enabled via opkg"
        else
            log "rollback: WARN: pbr opkg reinstall failed — manual /etc/init.d/pbr install needed"
        fi
    fi

    # 6) Inject one-shot post-boot pbr kick (awg1 wait → pbr restart → self-delete).
    inject_rc_local_kick

    # 7) Write final result token, then reboot.
    printf 'RESULT: ROLLED_BACK\n' >> "$RESULT_LOG"
    log "rollback: rebooting in 2s"
    _PHASE="done"
    ( sleep 2 && reboot ) &
    return 0
}

# ---------------------------------------------------------------------------
# EXIT trap: catches any unhandled exit (belt-and-suspenders; main flow uses
# explicit rc checks to ensure rollback is always reachable).
# ---------------------------------------------------------------------------
_trap_exit() {
    _ec=$?
    case "$_PHASE" in
        migrate|verify)
            if [ -z "$_ROLLBACK_REASON" ]; then
                _ROLLBACK_REASON="unexpected-exit-phase=${_PHASE}-rc=${_ec}"
                log "TRAP: unexpected exit in ${_PHASE}, rc=${_ec} — triggering rollback"
                do_rollback
            fi
            ;;
        *)
            ;;
    esac
}
trap '_trap_exit' EXIT

# ===========================================================================
# Phase 1: Backup
# ===========================================================================
_PHASE="backup"
log_sep "PHASE 1: BACKUP"

log "sysupgrade -b $BACKUP_FILE"
if ! sysupgrade -b "$BACKUP_FILE" 2>&1; then
    log "FATAL: sysupgrade -b failed — aborting with NO changes made"
    printf 'RESULT: BACKUP_FAILED\n' >> "$RESULT_LOG"
    _PHASE="done"
    exit 1
fi

_bsize=$(wc -c < "$BACKUP_FILE" 2>/dev/null || echo '?')
log "backup written: $BACKUP_FILE (${_bsize} bytes)"

if ! tar tzf "$BACKUP_FILE" >/dev/null 2>&1; then
    log "FATAL: backup archive corrupt"
    printf 'RESULT: BACKUP_FAILED\n' >> "$RESULT_LOG"
    _PHASE="done"
    exit 1
fi
log "backup integrity OK"

# ===========================================================================
# Phase 2: Migrate
# ===========================================================================
_PHASE="migrate"
log_sep "PHASE 2: MIGRATE"

MIGRATE_SCRIPT="$CUTOVER_DIR/install-amnezia-pbr.sh"
if [ ! -f "$MIGRATE_SCRIPT" ]; then
    _ROLLBACK_REASON="migrate-script-missing"
    log "ERROR: $MIGRATE_SCRIPT not found"
    do_rollback
    exit 1
fi

log "CONF_DIR=/etc/amnezia sh $MIGRATE_SCRIPT --migrate"
_migrate_rc=0
CONF_DIR=/etc/amnezia sh "$MIGRATE_SCRIPT" --migrate 2>&1 || _migrate_rc=$?
log "migrate exit code: ${_migrate_rc}"

if [ "$_migrate_rc" -ne 0 ]; then
    _ROLLBACK_REASON="migrate-failed-rc=${_migrate_rc}"
    log "ERROR: migrate returned ${_migrate_rc} — triggering rollback"
    do_rollback
    exit 1
fi

log "migrate completed; settling 5s..."
sleep 5

capture_syslog "post-migrate"
snapshot_state "post-migrate"

# ===========================================================================
# Phase 3: Verify
# ===========================================================================
_PHASE="verify"
log_sep "PHASE 3: VERIFY"

_any_fail=0
_failed_check=""

_note_fail() {
    _any_fail=1
    [ -z "$_failed_check" ] && _failed_check="$1"
}

# ── V1: monitor process running ──────────────────────────────────────────────
log "V1: amnezia-failover process"
if pgrep -f amnezia-failover >/dev/null 2>&1; then
    log "CHECK V1: PASS"
else
    log "CHECK V1: FAIL (amnezia-failover not running)"
    _note_fail "V1-monitor-not-running"
fi

# ── V2: pbr actually removed (gap B — verify opkg remove worked) ─────────────
log "V2: pbr removed or inert"
_pbr_row=$(opkg list-installed 2>/dev/null | grep '^pbr ' || true)
if [ -z "$_pbr_row" ]; then
    log "CHECK V2: PASS (pbr absent from opkg list-installed)"
else
    # Package lingers (e.g. --force-depends removal blocked). That is acceptable
    # ONLY if pbr is fully inert: disabled (won't autostart on boot) AND no live
    # pbr_ nft chains (a stopped pbr removes its own chains, so it cannot mark or
    # route anything). A still-enabled pbr, or live pbr_ chains, is a real
    # conflict with the native stack and must fail.
    _pbr_enabled=0
    /etc/init.d/pbr enabled 2>/dev/null && _pbr_enabled=1
    _pbr_chains=$(nft list chains inet fw4 2>/dev/null | grep -c 'chain pbr_' || true)
    if [ "$_pbr_enabled" = 1 ]; then
        log "CHECK V2: FAIL (pbr still installed AND enabled: ${_pbr_row})"
        _note_fail "V2-pbr-still-enabled"
    elif [ "${_pbr_chains:-0}" -gt 0 ]; then
        log "CHECK V2: FAIL (pbr still installed with ${_pbr_chains} live pbr_ nft chains: ${_pbr_row})"
        _note_fail "V2-pbr-chains-live"
    else
        log "CHECK V2: PASS-WARN (pbr pkg lingers but is disabled + no live pbr_ chains = inert: ${_pbr_row})"
    fi
fi

# ── V3: fwmark ip rules present + priorities above pbr cleanup range ─────────
log "V3: fwmark ip rules"
_ip_rules=$(ip rule show 2>/dev/null || true)
_v3_ok=1

if echo "$_ip_rules" | grep -qE 'fwmark 0x0*a0000/0x0*ff0000.*lookup (100|vpn_sticky)'; then
    log "CHECK V3a: PASS (sticky rule present)"
else
    log "CHECK V3a: FAIL (sticky fwmark rule absent)"
    _v3_ok=0
fi

if echo "$_ip_rules" | grep -qE 'fwmark 0x0*b0000/0x0*ff0000.*lookup (101|vpn_pool)'; then
    log "CHECK V3b: PASS (pool rule present)"
else
    log "CHECK V3b: FAIL (pool fwmark rule absent)"
    _v3_ok=0
fi

_sticky_prio=$(echo "$_ip_rules" \
    | awk '/fwmark.*0x0*a0000\/0x0*ff0000/{sub(/:$/,"",$1); print $1}' | head -1)
_pool_prio=$(echo "$_ip_rules" \
    | awk '/fwmark.*0x0*b0000\/0x0*ff0000/{sub(/:$/,"",$1); print $1}' | head -1)
log "V3: sticky_prio=${_sticky_prio} pool_prio=${_pool_prio}"

if [ "$_v3_ok" -eq 1 ]; then
    if [ -n "$_sticky_prio" ] && [ "$_sticky_prio" -gt 30000 ] && \
       [ -n "$_pool_prio"  ] && [ "$_pool_prio"  -gt 30000 ]; then
        log "CHECK V3c: PASS (prefs ${_sticky_prio}/${_pool_prio} both > 30000)"
    else
        log "CHECK V3c: FAIL (prefs not > 30000)"
        _v3_ok=0
    fi
fi

[ "$_v3_ok" -eq 0 ] && _note_fail "V3-fwmark-rules"

# ── V4: amnezia_classify chain live in nft ───────────────────────────────────
log "V4: nft amnezia_classify chain"
if nft list chain inet fw4 amnezia_classify >/dev/null 2>&1; then
    log "CHECK V4: PASS"
else
    log "CHECK V4: FAIL (chain absent)"
    _note_fail "V4-classifier-absent"
fi

# ── V5: firewall vpn zone with masq=1 ───────────────────────────────────────
log "V5: firewall.vpn masq"
if uci show firewall 2>/dev/null | grep -q "firewall.vpn.masq='1'"; then
    log "CHECK V5: PASS"
else
    log "CHECK V5: FAIL (firewall.vpn.masq=1 absent)"
    _note_fail "V5-vpn-zone-masq"
fi

# ── V6: routing tables 100/101 ───────────────────────────────────────────────
# With SKIP_DATAPLANE=0 (real router): tables must have a tunnel default route
# (the monitor populates these within seconds of starting).
# With SKIP_DATAPLANE=1 (VM/test): tables just need to exist (fail-closed is OK).
log "V6: routing tables 100/101 populated by monitor"
if [ "$SKIP_DATAPLANE" = "1" ]; then
    log "V6: SKIP_DATAPLANE=1 — checking tables exist (fail-closed state OK)"
    _v6_ok=1
    for _tbl in 100 101; do
        _trow=$(ip route show table "$_tbl" 2>/dev/null | head -3 || true)
        if [ -n "$_trow" ]; then
            log "CHECK V6 table ${_tbl}: PASS (table exists: ${_trow})"
        else
            log "CHECK V6 table ${_tbl}: FAIL (table ${_tbl} empty/absent)"
            _v6_ok=0
        fi
    done
    [ "$_v6_ok" -eq 0 ] && _note_fail "V6-routing-tables-absent"
else
    _v6_ok=1
    for _tbl in 100 101; do
        _tries=0
        _trow=""
        while [ "$_tries" -lt 5 ]; do
            _trow=$(ip route show table "$_tbl" 2>/dev/null | head -3 || true)
            if echo "$_trow" | grep -qE 'default dev awg'; then
                log "CHECK V6 table ${_tbl}: PASS"
                break
            fi
            _tries=$((_tries + 1))
            log "V6 table ${_tbl}: not ready yet (try ${_tries}/5): ${_trow}"
            [ "$_tries" -lt 5 ] && sleep 3
        done
        if ! echo "$_trow" | grep -qE 'default dev awg'; then
            log "CHECK V6 table ${_tbl}: FAIL (no tunnel default after retries)"
            _v6_ok=0
        fi
    done
    [ "$_v6_ok" -eq 0 ] && _note_fail "V6-routing-tables-empty"
fi

# ── V7: amnezia_block_quic preserved ────────────────────────────────────────
log "V7: amnezia_block_quic preserved"
if uci -q get firewall.amnezia_block_quic >/dev/null 2>&1; then
    log "CHECK V7: PASS"
else
    log "CHECK V7: FAIL (amnezia_block_quic missing)"
    _note_fail "V7-block-quic-missing"
fi

# ── Data-plane checks (real router only; SKIP_DATAPLANE=1 skips) ─────────────
if [ "$SKIP_DATAPLANE" = "1" ]; then
    log "SKIP_DATAPLANE=1 — skipping V8/V9/V10"
else
    log_sep "DATA-PLANE CHECKS"

    # V8: awg1 handshake fresh (< 180 s)
    log "V8: awg1 handshake freshness"
    _hs=$(awg show awg1 latest-handshakes 2>/dev/null \
        | awk '{print $2}' | head -1 || true)
    _now=$(date +%s)
    if [ -n "$_hs" ] && [ "$_hs" -gt 0 ]; then
        _age=$(( _now - _hs ))
        log "V8: handshake age=${_age}s"
        if [ "$_age" -lt 180 ]; then
            log "CHECK V8: PASS"
        else
            log "CHECK V8: FAIL (stale: ${_age}s)"
            _note_fail "V8-awg1-stale-handshake"
        fi
    else
        log "CHECK V8: FAIL (no handshake data)"
        _note_fail "V8-awg1-no-handshake"
    fi

    # V9: pool-marked traffic routes via awg*, not WAN
    log "V9: marked traffic routing"
    _wan_dev=$(uci -q get network.wan.device 2>/dev/null || echo eth0)
    _rget=$(ip route get 1.1.1.1 mark 0x0b0000 2>&1 || true)
    log "V9 route get: ${_rget}"
    if echo "$_rget" | grep -qE 'dev awg'; then
        log "CHECK V9: PASS (via awg*)"
    elif echo "$_rget" | grep -q "dev ${_wan_dev}"; then
        log "CHECK V9: FAIL (WAN leak via ${_wan_dev})"
        _note_fail "V9-wan-leak"
    else
        log "CHECK V9: FAIL (unexpected route: ${_rget})"
        _note_fail "V9-route-unexpected"
    fi

    # V10: ping through awg1
    log "V10: ping 1.1.1.1 via awg1"
    if ping -I awg1 -c 2 -W 4 1.1.1.1 >/dev/null 2>&1; then
        log "CHECK V10: PASS"
    else
        log "CHECK V10: FAIL"
        _note_fail "V10-awg1-ping-failed"
    fi
fi

snapshot_state "post-verify"

# ===========================================================================
# Phase 4/5: Success or Rollback
# ===========================================================================
if [ "$_any_fail" -eq 0 ]; then
    log_sep "PHASE 4: SUCCESS"
    log "All verification checks passed — new failover stack is live"
    printf 'RESULT: SUCCESS\n' >> "$RESULT_LOG"
    _PHASE="done"
    exit 0
fi

log_sep "PHASE 5: AUTO-ROLLBACK"
log "Verification failed (first failed check: ${_failed_check}) — rolling back"
_ROLLBACK_REASON="verify-failed:${_failed_check}"
do_rollback
exit 1
