#!/bin/sh
# amnezia-covert-logwrap.sh -> /usr/lib/amnezia/amnezia-covert-logwrap.sh
#
# Reads the covert creator's combined stdout+stderr on stdin (piped in by the
# launcher via /var/run/amnezia-covert/covert.fifo). Jobs:
#
#   1. Maintain /var/run/amnezia-covert/state.json (atomic tmp+mv, same dir)
#      from a small set of marker lines the binary logs unconditionally.
#   2. Append every line to the flash covert.log, GENERICALLY redacting any
#      ", response:" tail -- the binary dumps a raw VK auth-response body
#      (access_token / session_key) at nine call sites, including the
#      self-healing rejoin path, and enumerating fixed shapes would miss
#      some of them. Never drop the whole line -- that loses the state
#      signal that lives in the kept prefix.
#   3. Periodically cap covert.log to its last 2000 lines, truncating the
#      file IN PLACE. The wrapper runs as the unprivileged amnezia-covert
#      user: it can only APPEND/truncate covert.log (file-write, granted by
#      its 0640 amnezia-covert:amnezia-covert mode) -- it has no write on
#      the 0750 root:amnezia-covert parent dir, so a blackbox-style
#      `tail ... > $LOG.tmp && mv $LOG.tmp $LOG` cap (which needs dir-write
#      to create/rename the tmp file) would EACCES. The cap therefore
#      stages the trimmed copy in the writable service-owned run dir and
#      truncates covert.log via a plain `>` redirect onto the existing file.
#
# Never creates covert.log -- the installer pre-creates it 0640. Never
# downgrades a terminal state.json ("not-started"/"crashed"): a buffered
# marker line this same process is still draining after the launcher (or a
# future generation) declared a terminal outcome must not flip it back.
set -eu

LOG="${AMZ_COVERT_LOG:-/etc/amnezia/covert/covert.log}"
RUN_DIR="${AMZ_COVERT_RUN_DIR:-/var/run/amnezia-covert}"
STATE="$RUN_DIR/state.json"

CAP_LINES=2000
# Cap check cadence: every N processed lines -- bounded cost, never a
# per-line stat+rewrite (the design's "cap runs periodically, not per-line").
CAP_EVERY=200

_cap_log() {
  # logcap is a full copy of covert.log (join-link-bearing) staged in the
  # run dir for the truncate-in-place below. Create it group-only via a
  # subshell umask (0027 -> 0640) so there is never even a momentary
  # world/other-readable window; chmod is belt-and-braces. cat back onto
  # $LOG ONLY on tail success -- a transient run-dir write failure must
  # never truncate the live log to an empty logcap.
  ( umask 0027; tail -n "$CAP_LINES" "$LOG" > "$RUN_DIR/logcap" ) \
    && { chmod 0640 "$RUN_DIR/logcap" 2>/dev/null || :; } \
    && cat "$RUN_DIR/logcap" > "$LOG"
}

# --cap-once: run a single cap pass and exit. The launcher never invokes
# this -- it exists so the truncate-in-place mechanism can be exercised
# directly (no live FIFO needed).
if [ "${1:-}" = "--cap-once" ]; then
  _cap_log
  exit 0
fi

# ---- generic redaction --------------------------------------------------
# On ANY line containing ", response:" keep everything up to and including
# "response:" and replace the remainder with ***. Prefix-agnostic: it does
# not matter which "empty X" produced it, nor which wrapper surfaced it
# ("Failed to create call:", "Failed to join existing call:", or
# "[rejoin] Failed:") -- covers all nine upstream body-dump sites and any
# future one, without enumerating fixed shapes.
_redact() {
  printf '%s\n' "$1" | sed 's/\(, response:\).*/\1***/'
}

# ---- multi-line body suppression ------------------------------------------
# The upstream `r` dumped after ", response:" is a raw HTTP body and CAN
# contain embedded newlines (JSON/HTML) -- the creator's stdout+stderr is
# read line-by-line, so a multi-line body would otherwise defeat the
# single-line _redact above on every continuation line. Once a
# ", response:" line is seen, every SUBSEQUENT line is masked wholesale
# until one is unmistakably a fresh log line.
#
# The boundary markers MUST be line-ANCHORED, never unanchored substrings:
# an unanchored `*"Cannot"*`/`*"Failed"*`/`*"[vk-ws]"*` matches a body line
# that merely CONTAINS one of those words (e.g. a VK JSON error body like
# `{ "error_msg": "Cannot refresh session", ... "access_token": "SECRET" }`)
# and ends suppression BEFORE the token line -- leaking it. Verified against
# upstream headless/vk/main.go: the only line-initial markers a fresh log
# line can legitimately start with are (1) the Go `log` package's default
# timestamp prefix (present because the upstream code never calls
# log.SetFlags -- every `[vk-ws]`/`Failed`/`Cannot` line is ALSO emitted via
# `log.*` and so is timestamp-prefixed at line start already), or (2) the
# creator's own two un-prefixed `fmt.Println` markers, which likewise only
# ever appear at the START of a line ("  CALL CREATED" / "  join_link: ").
# Neither pattern can occur mid-body inside a VK response's JSON/HTML text.
# Erring toward over-suppression is correct -- never leak a body line.
_is_fresh_log_line() {
  case "$1" in
    [0-9][0-9][0-9][0-9]/[0-9][0-9]/[0-9][0-9]\ *) return 0 ;;
    "  CALL CREATED"*|"  join_link: "*) return 0 ;;
    *) return 1 ;;
  esac
}

# ---- state classification ------------------------------------------------
# Classifies off the ORIGINAL (unredacted) line's surfacing prefix -- the
# auth-failed/rejoin signal lives there and is unaffected by redaction, but
# classifying before masking keeps the two concerns explicitly ordered per
# the design ("classify off the wrapper prefix first, then mask the tail").
# Sets _NEW_STATE/_NEW_REASON directly (called un-substituted, so it mutates
# the caller's shell -- no subshell, no need to thread two return values
# through a subshell's single stdout). Reason is always a fixed short label,
# never the raw line -- the raw line before its ", response:" marker never
# carries a secret, but keeping state.json free of any dynamic auth text is
# the simpler invariant to hold.
_classify() {
  _l="$1"
  _NEW_STATE=""
  _NEW_REASON=""
  case "$_l" in
    *"  CALL CREATED"*) _NEW_STATE=starting ;;
    *"[vk-ws] Connected"*) _NEW_STATE=connected ;;
    *"Failed to create call:"*) _NEW_STATE=auth-failed; _NEW_REASON=failed-to-create-call ;;
    *"Failed to join existing call:"*) _NEW_STATE=auth-failed; _NEW_REASON=failed-to-join-call ;;
    *"[rejoin] Failed:"*) _NEW_STATE=auth-failed; _NEW_REASON=rejoin-failed ;;
    *"Cannot read cookies:"*) _NEW_STATE=auth-failed; _NEW_REASON=cannot-read-cookies ;;
    *"Cannot parse cookies:"*) _NEW_STATE=auth-failed; _NEW_REASON=cannot-parse-cookies ;;
  esac
}

_is_join_link() {
  case "$1" in
    *"  join_link: "*) return 0 ;;
    *) return 1 ;;
  esac
}

_join_link_value() {
  printf '%s' "${1##*"  join_link: "}" | tr -d '\n'
}

_json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

_is_terminal() {
  case "$1" in
    not-started|crashed) return 0 ;;
    *) return 1 ;;
  esac
}

_disk_state() {
  [ -f "$STATE" ] || { printf 'idle'; return 0; }
  sed -n 's/.*"state":"\([^"]*\)".*/\1/p' "$STATE" | head -n1
}

# ---- in-memory snapshot, flushed to state.json (throttled) --------------
CUR_STATE=idle
CUR_LINK=""
CUR_REASON=""
DIRTY=1     # force the very first flush, unconditionally (establishes "idle").

_flush_state() {
  _on_disk="$(_disk_state)"
  if _is_terminal "$_on_disk"; then
    # Refuse to downgrade a terminal state -- even from a buffered marker
    # this same process is still draining after a terminal write landed.
    DIRTY=0
    return 0
  fi
  _tmp="$RUN_DIR/state.json.tmp.$$"
  if [ -n "$CUR_LINK" ]; then
    _link_json="\"$(_json_escape "$CUR_LINK")\""
  else
    _link_json=null
  fi
  printf '{"state":"%s","link":%s,"reason":"%s"}\n' \
    "$(_json_escape "$CUR_STATE")" "$_link_json" "$(_json_escape "$CUR_REASON")" > "$_tmp"
  # chmod the TMP file before the mv -- mv preserves mode, so there is never
  # a window where state.json (carrying the secret join link) sits at the
  # umask-default 0644.
  chmod 0640 "$_tmp" 2>/dev/null || :
  mv "$_tmp" "$STATE"
  DIRTY=0
}

# Flush every PENDING change immediately -- never behind a wall-clock
# throttle. The creator emits its whole startup burst ("CALL CREATED", the
# join_link, "[vk-ws] Connected" and the post-connect notifications) inside
# a SINGLE wall-clock second and then goes SILENT waiting for a joiner. A
# <=1/sec throttle therefore does not merely delay the "connected" write, it
# strands it forever: a deferred flush is only ever retried when another
# input line arrives, and no further line arrives. amnezia-covert-run.sh
# then polls a state.json still reading "starting", times out at
# AMZ_COVERT_READY_TIMEOUT, kills a perfectly healthy creator, and procd
# respawns until it gives up -- surfacing as state "not-started" / reason
# "readiness-timeout" in the LuCI panel (live router, 2026-09-04).
#
# The rewrite rate the throttle was reaching for is instead bounded at the
# SOURCE: DIRTY is set only when a marker actually CHANGES state/reason/link
# (see the classify/join-link blocks below), so a repeated -- or
# body-echoed -- marker line costs nothing at all. A genuine alternation
# writes one small tmpfs file, strictly cheaper than the per-line _redact
# fork the log path already pays for that same line.
_maybe_flush_state() {
  [ "$DIRTY" -eq 1 ] || return 0
  _flush_state
}

mkdir -p "$RUN_DIR" 2>/dev/null || :
chmod 0750 "$RUN_DIR" 2>/dev/null || :
_flush_state

_line_n=0
IN_BODY=0
while IFS= read -r line || [ -n "$line" ]; do
  _line_n=$((_line_n + 1))

  if [ "$IN_BODY" -eq 1 ]; then
    if _is_fresh_log_line "$line"; then
      IN_BODY=0
      # Fall through -- process this line normally below.
    else
      # Still inside a suppressed multi-line body: never write the raw
      # line, whole-line mask it instead.
      printf '***\n' >> "$LOG"
      _maybe_flush_state
      if [ $((_line_n % CAP_EVERY)) -eq 0 ]; then
        _cap_log 2>/dev/null || :
      fi
      continue
    fi
  fi

  # Only an ACTUAL change marks the snapshot dirty -- that is what bounds
  # the state.json rewrite rate now that _maybe_flush_state no longer
  # throttles on the clock. A marker line repeating the state already held
  # (the creator re-logs "[vk-ws] Connected" on every rejoin, and a response
  # body can echo a marker verbatim) is a no-op, not a rewrite.
  _classify "$line"
  if [ -n "$_NEW_STATE" ]; then
    if [ "$_NEW_STATE" != "$CUR_STATE" ] || [ "$_NEW_REASON" != "$CUR_REASON" ]; then
      CUR_STATE="$_NEW_STATE"
      CUR_REASON="$_NEW_REASON"
      DIRTY=1
    fi
  fi
  if _is_join_link "$line"; then
    _new_link="$(_join_link_value "$line")"
    if [ "$_new_link" != "$CUR_LINK" ]; then
      CUR_LINK="$_new_link"
      DIRTY=1
    fi
  fi

  case "$line" in
    *", response:"*) IN_BODY=1 ;;
  esac

  printf '%s\n' "$(_redact "$line")" >> "$LOG"

  _maybe_flush_state

  if [ $((_line_n % CAP_EVERY)) -eq 0 ]; then
    _cap_log 2>/dev/null || :
  fi
done

# Final flush on EOF (creator exited / pipe closed) so nothing pending is lost.
if [ "$DIRTY" -eq 1 ]; then
  _flush_state
fi
