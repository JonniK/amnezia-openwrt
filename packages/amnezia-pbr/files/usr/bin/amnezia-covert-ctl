#!/bin/sh
# amnezia-covert-ctl -> /usr/bin/amnezia-covert-ctl
#
# CLI for the opt-in, default-OFF headless VK "creator" (whitelist-bypass
# covert transport). Verbs: enable | disable | apply | status.
#
# UCI keys (under amnezia.config):
#   covert_enabled  — 0/1 feature flag (default 0)
#
# Env test hooks (all default to the real fixed router paths/values):
#   AMNEZIA_COVERT_INIT   — init path (default /etc/init.d/amnezia-covert).
#                           Tests set this to a bare command name (e.g.
#                           "amnezia-covert-init") so it routes through a
#                           PATH-shadowed stub instead of the real init.
#   AMZ_COVERT_FRAGMENT   — active egress fragment path (default
#                           /etc/nftables.d/40-amnezia-covert-egress.nft).
#   AMZ_COVERT_TEMPLATE   — egress template source, checked first in the
#                           template search list.
#   AMZ_COVERT_MEMINFO    — /proc/meminfo path (test seam).
#   AMZ_COVERT_MIN_MEM_KB — MemAvailable preflight threshold in kB (default
#                           32768; pinned against live measurement per the
#                           design doc's open items -- override in prod once
#                           measured).
#   AMZ_COVERT_STALE_S    — seconds since the last state.json write before a
#                           "connected" report is downgraded to "unknown"
#                           (default 90; also an unpinned live value).
#   AMZ_COVERT_REAP_WAIT  — seconds to wait between TERM and KILL during a
#                           reap-and-confirm pass (default 1; tests set 0).
#
# Consumes (from amnezia-common.sh, unconditionally exported so any caller
# override must be captured BEFORE sourcing it and re-applied after --
# mirrors the amnezia-covert-run.sh launcher's own pattern):
#   AMZ_COVERT_BIN, AMZ_COVERT_DIR, AMZ_COVERT_COOKIES, AMZ_COVERT_MANIFEST,
#   AMZ_COVERT_RUN_DIR, AMZ_PROC_DIR, amz_covert_uid, amz_covert_enabled,
#   amz_covert_reap, amz_log.

_bin_override="${AMZ_COVERT_BIN:-}"
_dir_override="${AMZ_COVERT_DIR:-}"
_cookies_override="${AMZ_COVERT_COOKIES:-}"
_manifest_override="${AMZ_COVERT_MANIFEST:-}"
_rundir_override="${AMZ_COVERT_RUN_DIR:-}"

AMNEZIA_LIB="${AMNEZIA_LIB:-/usr/lib/amnezia}"
# shellcheck source=lib/amnezia-common.sh
if [ -f "$AMNEZIA_LIB/amnezia-common.sh" ]; then
  . "$AMNEZIA_LIB/amnezia-common.sh"
else
  . "$(dirname "$0")/lib/amnezia-common.sh"
fi

# Re-apply: common.sh's own unconditional `export AMZ_COVERT_*=<fixed path>`
# just clobbered any caller override in the process environment.
AMZ_COVERT_BIN="${_bin_override:-$AMZ_COVERT_BIN}"
AMZ_COVERT_DIR="${_dir_override:-$AMZ_COVERT_DIR}"
AMZ_COVERT_COOKIES="${_cookies_override:-$AMZ_COVERT_COOKIES}"
AMZ_COVERT_MANIFEST="${_manifest_override:-$AMZ_COVERT_MANIFEST}"
AMZ_COVERT_RUN_DIR="${_rundir_override:-$AMZ_COVERT_RUN_DIR}"
export AMZ_COVERT_BIN AMZ_COVERT_DIR AMZ_COVERT_COOKIES AMZ_COVERT_MANIFEST AMZ_COVERT_RUN_DIR

AMNEZIA_COVERT_INIT="${AMNEZIA_COVERT_INIT:-/etc/init.d/amnezia-covert}"
AMZ_COVERT_FRAGMENT="${AMZ_COVERT_FRAGMENT:-/etc/nftables.d/40-amnezia-covert-egress.nft}"

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

_covert_json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# Portable mtime: GNU/BusyBox `stat -c`, else BSD/macOS `stat -f`.
_covert_file_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0
}

# Locate the egress template across the AMZ_COVERT_TEMPLATE override, the
# installed share location, and the source tree (mirrors
# lib/amnezia-routing.sh's _amz_find_fragment convention).
_covert_find_template() {
  for _p in "${AMZ_COVERT_TEMPLATE:-}" \
            "/usr/share/amnezia/nftables.d/40-amnezia-covert-egress.nft" \
            "$(dirname "$0")/nftables.d/40-amnezia-covert-egress.nft" \
            "$(dirname "$0")/../nftables.d/40-amnezia-covert-egress.nft"; do
    [ -n "$_p" ] && [ -f "$_p" ] && { printf '%s' "$_p"; return 0; }
  done
  return 1
}

# Structural cookie validator ONLY: file exists, non-empty, a JSON array,
# every element carries non-empty "name" and "value". NEVER dials VK.
_cookie_check() {
  _f="$1"
  [ -f "$_f" ] && [ -s "$_f" ] || return 1
  _flat="$(tr -d ' \t\r\n' < "$_f")"
  case "$_flat" in
    \[*\]) ;;
    *) return 1 ;;
  esac
  case "$_flat" in *'"name"'*) ;; *) return 1 ;; esac
  case "$_flat" in *'"value"'*) ;; *) return 1 ;; esac
  case "$_flat" in *'"name":""'*) return 1 ;; esac
  case "$_flat" in *'"value":""'*) return 1 ;; esac
  return 0
}

# MemAvailable preflight. Unreadable /proc/meminfo (e.g. off-router dev/test
# host with no fixture supplied) never blocks -- the real router always has
# /proc/meminfo, this only degrades gracefully off-target.
_mem_ok() {
  _mi="${AMZ_COVERT_MEMINFO:-/proc/meminfo}"
  [ -f "$_mi" ] || return 0
  _avail="$(awk '/^MemAvailable:/{print $2; exit}' "$_mi" 2>/dev/null)"
  case "$_avail" in ''|*[!0-9]*) return 0 ;; esac
  [ "$_avail" -ge "${AMZ_COVERT_MIN_MEM_KB:-32768}" ]
}

# True (exit 0) iff a process under amz_covert_uid is currently present in
# AMZ_PROC_DIR. Read-only sibling of amz_covert_reap's own scan.
_covert_uid_procs_present() {
  _cuid="$(amz_covert_uid 2>/dev/null)" || return 1
  [ -n "$_cuid" ] || return 1
  for _statf in "$AMZ_PROC_DIR"/[0-9]*/status; do
    [ -f "$_statf" ] || continue
    _uline="$(awk '/^Uid:/{print; exit}' "$_statf" 2>/dev/null)"
    [ -n "$_uline" ] || continue
    _ruid="$(printf '%s' "$_uline" | awk '{print $2}')"
    [ "$_ruid" = "$_cuid" ] && return 0
  done
  return 1
}

# TERM, wait briefly, confirm; if still present, KILL, wait, confirm again.
# Best-effort -- always returns 0; the caller only cares that this ran
# BEFORE anything that assumes the covert-uid is now unrestricted (fragment
# removal) or about to be freshly started.
_covert_reap_and_confirm() {
  amz_covert_reap TERM
  sleep "${AMZ_COVERT_REAP_WAIT:-1}" 2>/dev/null || :
  if _covert_uid_procs_present; then
    amz_covert_reap KILL
    sleep "${AMZ_COVERT_REAP_WAIT:-1}" 2>/dev/null || :
    _covert_uid_procs_present && amz_log "amnezia-covert-ctl: reap: covert-uid process(es) survived TERM+KILL"
  fi
  return 0
}

_covert_running() {
  "$AMNEZIA_COVERT_INIT" running >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# _covert_restore_or_leave  -- used only from cmd_apply's drift-restore
# paths (fw4 check/reload failure). Relies on cmd_apply's own $_had_prior /
# $_snapshot / $AMZ_COVERT_FRAGMENT still being set in the caller's shell
# (POSIX sh has no function-local variables, so this is safe as long as it
# is only ever called from inside cmd_apply).
#
# L: a snapshot `cp` failure is silent (stderr redirected, exit code never
# checked) -- if it left an empty/missing file, blindly `cp`-ing it back
# onto the live fragment on the restore path would clobber a real fragment
# with zero bytes (fail-OPEN egress: no skuid match at all). Require the
# snapshot be non-empty before trusting it; otherwise leave the newly
# written (possibly-untested) fragment in place rather than truncate a
# previously-working one to nothing, and log loudly so this is never a
# silent no-op.
# ---------------------------------------------------------------------------
_covert_restore_or_leave() {
  if [ "$_had_prior" -eq 1 ]; then
    if [ -s "$_snapshot" ]; then
      cp "$_snapshot" "$AMZ_COVERT_FRAGMENT" 2>/dev/null
    else
      amz_log "amnezia-covert-ctl: apply: snapshot missing/empty after $1 -- refusing to restore an empty fragment, leaving the newly-written fragment in place"
    fi
  else
    rm -f "$AMZ_COVERT_FRAGMENT"
  fi
}

# ---------------------------------------------------------------------------
# cmd_enable
# ---------------------------------------------------------------------------
cmd_enable() {
  # Preflight -- NO `uci set` before every one of these passes (staged UCI
  # is process-shared in /tmp/.uci/; an uncommitted set can be flushed by
  # another amnezia CLI's unrelated commit).
  if [ ! -x "$AMZ_COVERT_BIN" ]; then
    amz_log "amnezia-covert-ctl: enable: creator binary missing at $AMZ_COVERT_BIN (dev-deploy-only in P1 -- stage it via dev/deploy-openwrt-safe.sh)"
    return 1
  fi

  _uid="$(amz_covert_uid 2>/dev/null)" || _uid=""
  if [ -z "$_uid" ]; then
    amz_log "amnezia-covert-ctl: enable: amnezia-covert system user does not exist"
    return 1
  fi

  if ! _cookie_check "$AMZ_COVERT_COOKIES"; then
    amz_log "amnezia-covert-ctl: enable: cookie file failed structural validation"
    return 1
  fi

  if ! _mem_ok; then
    amz_log "amnezia-covert-ctl: enable: MemAvailable below the ${AMZ_COVERT_MIN_MEM_KB:-32768}kB preflight threshold"
    return 1
  fi

  # Install the fragment with numeric-uid + LAN-ifname substitution.
  _lan="$(uci -q get network.lan.device 2>/dev/null || echo br-lan)"
  _tpl="$(_covert_find_template)" || {
    amz_log "amnezia-covert-ctl: enable: egress template not found"
    return 1
  }
  _tmp="$(mktemp 2>/dev/null || echo "/tmp/amnezia-covert-enable.$$")"
  sed -e "s/@@COVERT_UID@@/$_uid/g" -e "s/@@LAN_IFNAME@@/$_lan/g" "$_tpl" > "$_tmp"
  mv "$_tmp" "$AMZ_COVERT_FRAGMENT"

  if ! fw4 check >/dev/null 2>&1; then
    rm -f "$AMZ_COVERT_FRAGMENT"
    amz_log "amnezia-covert-ctl: enable: fw4 check failed after installing the egress fragment; removed, firewall untouched"
    return 1
  fi

  # Preflight complete -- only now does UCI state change.
  uci set amnezia.config.covert_enabled=1
  uci commit amnezia

  # init `enable` MUST precede `restart` -- a bare restart on a not-yet-
  # enabled procd service is a silent no-op (the stubby/https-dns-proxy bug).
  "$AMNEZIA_COVERT_INIT" enable 2>/dev/null || true
  "$AMNEZIA_COVERT_INIT" restart 2>/dev/null || true

  # Interactive path: background the reload so an SSH session over the
  # in-progress fw4 reload survives.
  ( sleep 1 && fw4 reload ) &

  return 0
}

# ---------------------------------------------------------------------------
# cmd_disable
# ---------------------------------------------------------------------------
cmd_disable() {
  "$AMNEZIA_COVERT_INIT" stop 2>/dev/null || true
  "$AMNEZIA_COVERT_INIT" disable 2>/dev/null || true

  # Confirm no creator survives BEFORE the egress fragment is removed -- the
  # fragment must outlive the relay, never the reverse. Re-verify empty
  # AFTER the TERM+KILL reap (the reap itself is best-effort and always
  # returns 0): if a covert-uid process still exists, this is a fail-SAFE
  # teardown -- KEEP the restrictive fragment rather than fail open, log
  # loudly, and report non-zero. The feature is still disabled (UCI +
  # init already stopped above) so no NEW creator starts under the kept
  # fragment; only the fragment removal + reload are skipped.
  _covert_reap_and_confirm

  _rc=0
  if _covert_uid_procs_present; then
    amz_log "amnezia-covert-ctl: disable: covert-uid process(es) survived TERM+KILL -- keeping the egress fragment restrictive (fail-safe), refusing to remove it"
    _rc=1
  else
    rm -f "$AMZ_COVERT_FRAGMENT"
    ( sleep 1 && fw4 reload ) &
  fi

  rm -f "$AMZ_COVERT_RUN_DIR/state.json" "$AMZ_COVERT_RUN_DIR/covert-link" 2>/dev/null

  uci set amnezia.config.covert_enabled=0
  uci commit amnezia

  return "$_rc"
}

# ---------------------------------------------------------------------------
# cmd_apply  -- idempotent reconcile; called by boot init (start_service)
# and safe to call any time.
# ---------------------------------------------------------------------------
cmd_apply() {
  if ! amz_covert_enabled; then
    "$AMNEZIA_COVERT_INIT" stop 2>/dev/null || true
    _covert_reap_and_confirm
    return 0
  fi

  if [ ! -x "$AMZ_COVERT_BIN" ]; then
    amz_log "amnezia-covert-ctl: apply: creator binary missing at $AMZ_COVERT_BIN (dev-deploy-only in P1 -- stage it via dev/deploy-openwrt-safe.sh)"
    return 1
  fi

  _uid="$(amz_covert_uid 2>/dev/null)" || _uid=""
  if [ -z "$_uid" ]; then
    amz_log "amnezia-covert-ctl: apply: amnezia-covert uid unresolvable -- fail-closed"
    return 1
  fi

  if ! _cookie_check "$AMZ_COVERT_COOKIES"; then
    amz_log "amnezia-covert-ctl: apply: cookie file failed structural validation"
    return 1
  fi

  if ! _mem_ok; then
    amz_log "amnezia-covert-ctl: apply: MemAvailable below the ${AMZ_COVERT_MIN_MEM_KB:-32768}kB preflight threshold"
    return 1
  fi

  # rpcd's fs.write sets mode but leaves group ownership at root -- re-assert
  # both after every write so the unprivileged reader can still open it.
  chown root:amnezia-covert "$AMZ_COVERT_COOKIES" 2>/dev/null || true
  chmod 0640 "$AMZ_COVERT_COOKIES" 2>/dev/null || true

  # Fail-closed on a genuine uid mismatch against a CURRENTLY RUNNING
  # instance: never silently reload a mismatched-uid creator under a
  # corrected fragment -- stop it first.
  if _covert_running; then
    _active_uid=""
    if [ -f "$AMZ_COVERT_FRAGMENT" ]; then
      _active_uid="$(sed -n 's/.*meta skuid \([0-9][0-9]*\).*/\1/p' "$AMZ_COVERT_FRAGMENT" 2>/dev/null | head -n1)"
    fi
    if [ -n "$_active_uid" ] && [ "$_active_uid" != "$_uid" ]; then
      amz_log "amnezia-covert-ctl: apply: running instance uid ($_active_uid) != resolved uid ($_uid) -- fail-closed stop"
      "$AMNEZIA_COVERT_INIT" stop 2>/dev/null || true
      _covert_reap_and_confirm
      return 1
    fi
  fi

  _lan="$(uci -q get network.lan.device 2>/dev/null || echo br-lan)"
  _tpl="$(_covert_find_template)" || {
    amz_log "amnezia-covert-ctl: apply: egress template not found"
    return 1
  }
  _new="$(mktemp 2>/dev/null || echo "/tmp/amnezia-covert-apply.$$")"
  sed -e "s/@@COVERT_UID@@/$_uid/g" -e "s/@@LAN_IFNAME@@/$_lan/g" "$_tpl" > "$_new"

  if [ -f "$AMZ_COVERT_FRAGMENT" ] && cmp -s "$_new" "$AMZ_COVERT_FRAGMENT" 2>/dev/null; then
    # No drift -- the common case. No reload.
    rm -f "$_new"
  else
    # H-A: snapshot the current on-disk fragment BEFORE the mv, so a
    # fw4-check or fw4-reload failure can restore it -- never leave the file
    # showing the new (unloaded) uid while the kernel still enforces the
    # old one. No prior fragment -> restore means "remove", matching
    # enable's own "firewall untouched" semantics for the no-prior case.
    _snapshot=""
    _had_prior=0
    if [ -f "$AMZ_COVERT_FRAGMENT" ]; then
      _had_prior=1
      _snapshot="$(mktemp 2>/dev/null || echo "/tmp/amnezia-covert-apply-snapshot.$$")"
      cp "$AMZ_COVERT_FRAGMENT" "$_snapshot" 2>/dev/null
    fi

    mv "$_new" "$AMZ_COVERT_FRAGMENT"

    if ! fw4 check >/dev/null 2>&1; then
      _covert_restore_or_leave "fw4-check-failed"
      rm -f "$_snapshot"
      amz_log "amnezia-covert-ctl: apply: fw4 check failed after re-substituting the egress fragment -- restored the previously-loaded fragment"
      return 1
    fi
    # H-A: SYNCHRONOUS reload, never backgrounded -- the launcher's step-0.5
    # uid check reads this FILE as a proxy for the loaded kernel ruleset, and
    # that proxy is valid only if file==kernel BEFORE start_service opens the
    # instance. No interactive SSH session to protect on the boot/reconcile
    # path, unlike enable's backgrounded reload.
    if ! fw4 reload >/dev/null 2>&1; then
      _covert_restore_or_leave "fw4-reload-failed"
      rm -f "$_snapshot"
      amz_log "amnezia-covert-ctl: apply: synchronous fw4 reload failed after fragment drift -- restored the previously-loaded fragment"
      return 1
    fi
    rm -f "$_snapshot"
  fi

  # Reap only on the (re)start path -- procd reports the instance NOT
  # running. A healthy running creator is never touched by a benign reconcile.
  if ! _covert_running; then
    _covert_reap_and_confirm
  fi

  return 0
}

# ---------------------------------------------------------------------------
# cmd_status
# ---------------------------------------------------------------------------
cmd_status() {
  _enabled=false
  amz_covert_enabled && _enabled=true

  _running=false
  _covert_running && _running=true

  _state_file="$AMZ_COVERT_RUN_DIR/state.json"
  _disk_state=""; _disk_link=""; _disk_reason=""
  if [ -f "$_state_file" ]; then
    _disk_state="$(sed -n 's/.*"state":"\([^"]*\)".*/\1/p' "$_state_file" | head -n1)"
    _disk_link="$(sed -n 's/.*"link":"\([^"]*\)".*/\1/p' "$_state_file" | head -n1)"
    _disk_reason="$(sed -n 's/.*"reason":"\([^"]*\)".*/\1/p' "$_state_file" | head -n1)"
  fi

  _out_state=idle
  _out_link=""
  _out_reason=""

  if [ "$_enabled" = true ] && [ "$_running" = true ]; then
    if [ -n "$_disk_state" ]; then
      _out_state="$_disk_state"
      _out_link="$_disk_link"
      _out_reason="$_disk_reason"
      if [ "$_out_state" = connected ]; then
        _mtime="$(_covert_file_mtime "$_state_file")"
        _now="$(date +%s 2>/dev/null || echo 0)"
        _age=$(( _now - _mtime ))
        [ "$_age" -lt 0 ] && _age=0
        if [ "$_age" -ge "${AMZ_COVERT_STALE_S:-90}" ]; then
          _out_state=unknown
        fi
      fi
    else
      _out_state=starting
    fi
  elif [ "$_enabled" = true ] && [ "$_running" = false ]; then
    # Discriminated by the on-disk state + reason -- never collapsed to a
    # single "not-started" arm.
    if [ "$_disk_state" = auth-failed ]; then
      _out_state=auth-failed
      _out_reason="$_disk_reason"
    elif [ "$_disk_reason" = respawn-exhausted ]; then
      _out_state=crashed
      _out_reason="$_disk_reason"
    else
      _out_state=not-started
      _out_reason="$_disk_reason"
    fi
  else
    # enabled=false: idle regardless of the running bit -- a racing disable
    # (procd still reports the instance up) is reported idle; the
    # boot/reconcile apply is what actually stops it.
    _out_state=idle
  fi

  _link_json=null
  _age_json=null
  if [ -n "$_out_link" ]; then
    _link_json="\"$(_covert_json_escape "$_out_link")\""
    _mtime="$(_covert_file_mtime "$_state_file")"
    _now="$(date +%s 2>/dev/null || echo 0)"
    _age=$(( _now - _mtime ))
    [ "$_age" -lt 0 ] && _age=0
    _age_json="$_age"
  fi

  # build_sha/build_hash are ALWAYS read from the installed BUILD_MANIFEST --
  # never recomputed (never shasum the 11MB binary on a poll).
  _sha=""; _hash=""
  if [ -f "$AMZ_COVERT_MANIFEST" ]; then
    _usha="$(sed -n 's/^upstream_sha=//p' "$AMZ_COVERT_MANIFEST" | head -n1)"
    _asha="$(sed -n 's/^artifact_sha256=//p' "$AMZ_COVERT_MANIFEST" | head -n1)"
    _sha="$(printf '%s' "$_usha" | cut -c1-8)"
    _hash="$(printf '%s' "$_asha" | cut -c1-8)"
  fi

  printf '{"enabled":%s,"running":%s,"state":"%s","link":%s,"link_age_s":%s,"reason":"%s","build_sha":"%s","build_hash":"%s"}\n' \
    "$_enabled" "$_running" "$_out_state" "$_link_json" "$_age_json" \
    "$(_covert_json_escape "$_out_reason")" "$_sha" "$_hash"
  return 0
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
case "${1:-}" in
  enable)  cmd_enable ;;
  disable) cmd_disable ;;
  apply)   cmd_apply ;;
  status)  cmd_status ;;
  *) echo "usage: amnezia-covert-ctl {enable|disable|apply|status}" >&2; exit 2 ;;
esac
