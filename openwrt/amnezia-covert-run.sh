#!/bin/sh
# amnezia-covert-run.sh -> /usr/lib/amnezia/amnezia-covert-run.sh
#
# procd INSTANCE command for the amnezia-covert service (see the design doc,
# "Run wrapper, state file, and why not logread"). procd re-execs THIS
# script directly on every respawn -- it does NOT re-run the init's
# start_service -- so every guard that must survive a crash-respawn lives
# here, not in the init or the CLI.
#
# Ordered steps (do not reorder -- each fixes a specific cycle finding):
#   0.   amz_covert_enabled || exit 0. Respawn-safe: a disable() race (UCI
#        already flipped to 0, init-disable not yet applied, respawn timer
#        fires) must not mint a fresh VK call.
#   0.5. uid-match fail-closed. The persisted egress fragment restricts a
#        SPECIFIC numeric uid. Re-resolve amz_covert_uid and compare it
#        against the fragment's substituted "meta skuid" operand BEFORE
#        ever launching the creator -- on mismatch, an unresolvable uid, or
#        a missing fragment, write not-started/uid-mismatch and refuse to
#        start. This is the only respawn-safe checkpoint for a uid
#        reallocation (e.g. across --migrate): apply()'s preflight runs on
#        start_service, which respawn bypasses.
#   1.   Truncate state.json + the -write-file link target here (not in
#        start_service, which respawn never re-runs -- a stale "connected"
#        + old link would otherwise survive a crash). last-call.ts is
#        deliberately NOT touched -- see step 2.
#   2.   Enforce the 120s call-creation gap from a DEDICATED last-call.ts
#        (never state.json, which step 1 just truncated -- that would
#        defeat the gap on every crash-respawn).
#   3.   Launch creator+logwrap via a FIFO so BOTH pids are captured. A
#        plain `creator | logwrap &` is unusable: `$!` would be logwrap
#        (the last pipeline element), non-interactive ash has no job
#        control so there is no process-group to signal, and procd's
#        SIGTERM would then reach only this launcher -- orphaning the
#        creator, unrestricted, right as disable() removes the egress
#        fragment. $PIPE lives in the writable /var/run service dir, never
#        the 0750 flash dir (mkfifo there would EACCES for the
#        unprivileged amnezia-covert user exactly like covert.log).
#   4.   Poll state.json concurrently with the backgrounded creator for the
#        starting->connected transition. On success, wait on the creator
#        (so procd sees the service alive for its whole life, and the trap
#        still fires on eventual stop). On timeout: kill the creator, then
#        the log wrapper, confirm both dead, THEN write not-started -- so a
#        logwrap still draining a buffered "CALL CREATED" cannot flap the
#        terminal state back to "starting" after the monitor's write.
set -u

# amnezia-common.sh EXPORTS AMZ_COVERT_RUN_DIR and AMZ_COVERT_COOKIES
# unconditionally (fixed paths, not an `${VAR:-default}` seam) -- capture
# any caller-supplied override BEFORE sourcing it, or a test override is
# silently clobbered back to the real /var/run or /etc/amnezia path.
_run_dir_override="${AMZ_COVERT_RUN_DIR:-}"
_cookies_override="${AMZ_COVERT_COOKIES:-}"
_log_override="${AMZ_COVERT_LOG:-}"

AMNEZIA_LIB="${AMNEZIA_LIB:-/usr/lib/amnezia}"
# shellcheck source=lib/amnezia-common.sh
if [ -f "$AMNEZIA_LIB/amnezia-common.sh" ]; then
  . "$AMNEZIA_LIB/amnezia-common.sh"
else
  . "$(dirname "$0")/lib/amnezia-common.sh"
fi

# Re-export: common.sh's own unconditional export just clobbered the
# caller's override in the process environment, and the log wrapper (a
# CHILD process off the FIFO) reads AMZ_COVERT_RUN_DIR itself -- it must
# see the same directory this launcher resolved to, not the real default.
RUN_DIR="${_run_dir_override:-${AMZ_COVERT_RUN_DIR:-/var/run/amnezia-covert}}"
AMZ_COVERT_RUN_DIR="$RUN_DIR"
export AMZ_COVERT_RUN_DIR
STATE="$RUN_DIR/state.json"
LASTCALL="$RUN_DIR/last-call.ts"
LINK_FILE="$RUN_DIR/covert-link"
PIPE="$RUN_DIR/covert.fifo"

# Test/override seams -- all default to the real fixed router paths/values.
AMZ_COVERT_FRAGMENT="${AMZ_COVERT_FRAGMENT:-/etc/nftables.d/40-amnezia-covert-egress.nft}"
AMZ_COVERT_CALL_GAP="${AMZ_COVERT_CALL_GAP:-120}"
AMZ_COVERT_READY_TIMEOUT="${AMZ_COVERT_READY_TIMEOUT:-30}"
AMZ_COVERT_CREATOR_BIN="${AMZ_COVERT_CREATOR_BIN:-${AMZ_COVERT_BIN:-/usr/bin/amnezia-covert-creator}}"
# Bare-name default so a test can PATH-shadow it (mirrors the existing
# AMNEZIA_DNSLEAK_INIT convention: default is an absolute path, tests
# override to a bare command name resolved off a scratch PATH entry).
AMZ_COVERT_LOGWRAP="${AMZ_COVERT_LOGWRAP:-/usr/lib/amnezia/amnezia-covert-logwrap.sh}"
AMZ_COVERT_COOKIES="${_cookies_override:-${AMZ_COVERT_COOKIES:-/etc/amnezia/covert/vk-cookies.json}}"
# Same re-export as AMZ_COVERT_RUN_DIR above: common.sh's unconditional
# export just clobbered a caller override, and the log wrapper (spawned
# below as a child off the FIFO) inherits AMZ_COVERT_LOG from THIS
# process's environment, not from the caller's shell.
AMZ_COVERT_LOG="${_log_override:-${AMZ_COVERT_LOG:-/etc/amnezia/covert/covert.log}}"
export AMZ_COVERT_LOG

mkdir -p "$RUN_DIR" 2>/dev/null || :

_json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# Atomic tmp+mv write, mirroring the log wrapper's own state.json writer.
# chmod the tmp file BEFORE the mv (mv preserves mode) so there is never a
# 0644 window on state.json, which carries the secret join link.
_write_state() {
  _st="$1"; _rs="${2:-}"
  _tmp="$RUN_DIR/state.json.tmp.$$"
  printf '{"state":"%s","link":null,"reason":"%s"}\n' \
    "$(_json_escape "$_st")" "$(_json_escape "$_rs")" > "$_tmp" 2>/dev/null \
    && { chmod 0640 "$_tmp" 2>/dev/null || :; } \
    && mv "$_tmp" "$STATE" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Step 0 -- respawn-safe enabled guard, first act.
# ---------------------------------------------------------------------------
amz_covert_enabled || exit 0

# ---------------------------------------------------------------------------
# Step 0.5 -- uid-match fail-closed (SECURITY, C1 respawn backstop).
# ---------------------------------------------------------------------------
_cur_uid="$(amz_covert_uid 2>/dev/null)" || _cur_uid=""
_frag_uid=""
if [ -n "$_cur_uid" ] && [ -f "$AMZ_COVERT_FRAGMENT" ]; then
  _frag_uid="$(sed -n 's/.*meta skuid \([0-9][0-9]*\).*/\1/p' "$AMZ_COVERT_FRAGMENT" 2>/dev/null | head -n1)"
fi

if [ -z "$_cur_uid" ] || [ -z "$_frag_uid" ] || [ "$_cur_uid" != "$_frag_uid" ]; then
  _write_state not-started uid-mismatch
  exit 1
fi

# ---------------------------------------------------------------------------
# Step 1 -- truncate state.json + the -write-file link target. Never touch
# last-call.ts here.
# ---------------------------------------------------------------------------
: > "$STATE" 2>/dev/null
chmod 0640 "$STATE" 2>/dev/null || :
: > "$LINK_FILE" 2>/dev/null
chmod 0640 "$LINK_FILE" 2>/dev/null || :

# ---------------------------------------------------------------------------
# Step 2 -- enforce the 120s (AMZ_COVERT_CALL_GAP) call-creation gap from a
# dedicated timestamp file that step 1 never touches.
# ---------------------------------------------------------------------------
_now="$(date +%s 2>/dev/null || echo 0)"
_last=0
if [ -f "$LASTCALL" ]; then
  _last="$(cat "$LASTCALL" 2>/dev/null)"
  case "$_last" in ''|*[!0-9]*) _last=0 ;; esac
fi
if [ "$_last" -gt 0 ]; then
  _elapsed=$((_now - _last))
  [ "$_elapsed" -lt 0 ] && _elapsed=0
  if [ "$_elapsed" -lt "$AMZ_COVERT_CALL_GAP" ]; then
    sleep $((AMZ_COVERT_CALL_GAP - _elapsed))
  fi
fi
date +%s > "$LASTCALL" 2>/dev/null || echo 0 > "$LASTCALL"

# ---------------------------------------------------------------------------
# Step 3 -- launch creator+logwrap via a FIFO, both pids captured.
# ---------------------------------------------------------------------------
mkfifo "$PIPE" 2>/dev/null || :

"$AMZ_COVERT_LOGWRAP" < "$PIPE" &
LW=$!

"$AMZ_COVERT_CREATOR_BIN" -resources moderate -cookies "$AMZ_COVERT_COOKIES" \
  -write-file "$LINK_FILE" > "$PIPE" 2>&1 &
CR=$!

_teardown() {
  kill "$CR" "$LW" 2>/dev/null
  wait "$CR" 2>/dev/null
  wait "$LW" 2>/dev/null
}
# TERM/INT must actually stop this launcher (a trap alone does not
# terminate the shell -- without the explicit exit, ash would resume the
# interrupted readiness loop and never tear down promptly). EXIT covers
# every other return path (normal exit, step-4 timeout return) with the
# same teardown, belt-and-braces against a path that forgot to kill.
trap '_teardown; exit 143' TERM
trap '_teardown; exit 130' INT
trap '_teardown' EXIT

# ---------------------------------------------------------------------------
# Step 4 -- readiness monitor, concurrent with the backgrounded creator.
# ---------------------------------------------------------------------------
_ready=0
_ticks=0
while [ "$_ticks" -lt "$AMZ_COVERT_READY_TIMEOUT" ]; do
  if [ -f "$STATE" ] && grep -q '"state":"connected"' "$STATE" 2>/dev/null; then
    _ready=1
    break
  fi
  # The creator died on its own (e.g. auth-failed) -- no point polling out
  # the full timeout window.
  kill -0 "$CR" 2>/dev/null || break
  _ticks=$((_ticks + 1))
  sleep 1
done

if [ "$_ready" -eq 1 ]; then
  wait "$CR"
  _rc=$?
  exit "$_rc"
fi

# Timeout (or the creator exited before connecting): kill the creator, then
# the log wrapper, confirm both dead, THEN write the terminal state -- a
# logwrap still draining a buffered "CALL CREATED" must never flap this
# back to "starting" after we declare not-started.
kill "$CR" 2>/dev/null
wait "$CR" 2>/dev/null
kill "$LW" 2>/dev/null
wait "$LW" 2>/dev/null

_write_state not-started readiness-timeout
exit 1
