#!/bin/sh
# amnezia-autolearn: one cron pass. Harvest visited domains, probe blocked
# ones (pinned), confirm/age, write auto.list, force-load on net change.
# Direct-default-only, opt-in, tunnel-health gated. POSIX sh.
set -u
AMNEZIA_LIB="${AMNEZIA_LIB:-/usr/lib/amnezia}"
# shellcheck disable=SC1091
. "$AMNEZIA_LIB/amnezia-autolearn-lib.sh"

AL_DIR="${AL_DIR:-/etc/amnezia}"
AL_STATE="${AL_STATE:-/var/run/amnezia-failover.json}"
AL_QUERYLOG="${AL_QUERYLOG:-/tmp/dnsmasq-queries.log}"
# AL_LOCK is no longer used (replaced by the mkdir-based AL_LOCKDIR below).
AL_LOCKDIR="${AL_LOCKDIR:-$AL_DIR/autolearn/.pass.lock}"
AUTO_LIST="$AL_DIR/force.d/auto.list"
CAND="$AL_DIR/autolearn/candidates.tsv"
DENY="$AL_DIR/autolearn/deny.list"
OFFSET_F="$AL_DIR/autolearn/.dnsmasq-log.offset"
AUTOLEARN_STATE_MAX_AGE="${AUTOLEARN_STATE_MAX_AGE:-120}"
AUTOLEARN_LOG_MAX_BYTES="${AUTOLEARN_LOG_MAX_BYTES:-2097152}"
# Hard cap on how many bytes of NEW query-log data one pass harvests. Under the
# DNS-leak block dnsmasq logs every client query, so the log can balloon to
# hundreds of KB; reading + tallying the whole thing is what pegged the CPU and
# tripped the hardware watchdog (-> hard reset). Bound the slice so the harvest
# cost is constant regardless of how big the log grew between passes.
AUTOLEARN_HARVEST_MAX_BYTES="${AUTOLEARN_HARVEST_MAX_BYTES:-262144}"
AMNEZIA_FORCE_LOAD="${AMNEZIA_FORCE_LOAD:-amnezia-force-load}"
# `kill` is a shell builtin — a PATH stub is never reached. Route the signal
# through this indirection so tests can inject a logging shim via AL_KILL.
AL_KILL="${AL_KILL:-kill}"

_uci() { uci -q get "$1" 2>/dev/null; }
_now() { date +%s 2>/dev/null || echo 0; }
_dbg() { [ "${AL_DEBUG:-0}" = 1 ] && echo "[autolearn-dbg] $*" >&2 || true; }

# --- CPU/IO yield -----------------------------------------------------------
# Re-exec the whole pass ONCE at the lowest scheduling + IO priority. A pass
# that can't preempt the kernel's watchdog thread can never trip the hardware
# watchdog into a hard reset, no matter how busy it gets. This is the primary
# guard; the input bound + the fork-storm removal below keep the busy window
# small as well. Tests set AL_NICE=0 to skip the re-exec (deterministic).
if [ "${AL_NICE:-1}" = 1 ] && [ "${AL_RENICED:-0}" != 1 ]; then
  AL_RENICED=1; export AL_RENICED
  if command -v ionice >/dev/null 2>&1; then
    exec nice -n 19 ionice -c3 sh "$0" "$@"
  elif command -v nice >/dev/null 2>&1; then
    exec nice -n 19 sh "$0" "$@"
  fi
  # No nice/ionice available: fall through and run at normal priority.
fi

# --- Gate -------------------------------------------------------------------
[ "$(_uci amnezia.config.routing_mode)" = "direct-default" ] || exit 0
_dbg "gate: mode ok"
[ "$(_uci amnezia.config.autolearn_enabled)" = "1" ] || exit 0
_dbg "gate: enabled ok"
# Tunnel health: state file must exist, be fresh, and report all_down:false.
[ -f "$AL_STATE" ] || exit 0
_dbg "gate: state file present"
_mtime=$(stat -c %Y "$AL_STATE" 2>/dev/null || date -r "$AL_STATE" +%s 2>/dev/null || echo 0)
_mtime=$(printf '%s' "$_mtime" | tr -dc '0-9'); _mtime=${_mtime:-0}
_age=$(( $(_now) - _mtime ))
_dbg "gate: mtime=$_mtime age=$_age (max $AUTOLEARN_STATE_MAX_AGE)"
[ "$_age" -le "$AUTOLEARN_STATE_MAX_AGE" ] 2>/dev/null || exit 0
_alldown=$(grep -o '"all_down":[a-z]*' "$AL_STATE" 2>/dev/null | head -n1 | sed 's/.*://')
_dbg "gate: all_down=$_alldown"
[ "$_alldown" = "false" ] || exit 0
_dbg "gate: PASSED"

mkdir -p "$AL_DIR/force.d" "$AL_DIR/autolearn"
# BusyBox awk aborts on a missing input file (BSD awk tolerates it). The prune
# and LRU steps read auto.list + candidates.tsv via awk before either may exist,
# which silently wiped candidates.tsv each pass on the router. Guarantee both
# exist (empty) up front.
[ -e "$AUTO_LIST" ] || : > "$AUTO_LIST"
[ -e "$CAND" ] || : > "$CAND"

# --- Lock (portable mkdir mutex; BusyBox flock fd-form is unreliable) ---------
# Self-heal a stale lock left by a crashed pass (> 30 min old; one pass is
# bounded by autolearn_max_probes * curl max-time, well under that).
if [ -d "$AL_LOCKDIR" ]; then
  _lk_m=$(stat -c %Y "$AL_LOCKDIR" 2>/dev/null || date -r "$AL_LOCKDIR" +%s 2>/dev/null || echo 0)
  _lk_m=$(printf '%s' "$_lk_m" | tr -dc '0-9'); _lk_m=${_lk_m:-0}
  [ $(( $(_now) - _lk_m )) -gt 1800 ] 2>/dev/null && rmdir "$AL_LOCKDIR" 2>/dev/null || true
fi
if mkdir "$AL_LOCKDIR" 2>/dev/null; then
  trap 'rmdir "$AL_LOCKDIR" 2>/dev/null' EXIT INT TERM
else
  _dbg "lock held by another pass/purge; skipping"
  exit 0
fi
_dbg "lock acquired"

# _al_record <domain> <verdict> <clients_csv>: update candidates.tsv; on
# threshold, append to auto.list (with LRU eviction at the cap). Returns 0 iff
# a domain was newly appended to auto.list; 1 otherwise.
_al_record() {
  _d="$1"; _v="$2"; _clients="$3"; _ts=$(_now)
  case "$_v" in
    direct_geoblocked) _reason=geoblock; _thresh=2 ;;
    direct_dpi_blocked) _reason=dpi; _thresh=3 ;;
    *) return 1 ;;                      # ok/blocked/unreachable/error -> no add
  esac
  _prev=$(awk -F'\t' -v d="$_d" '$1==d{print; exit}' "$CAND" 2>/dev/null)
  if [ -n "$_prev" ]; then
    _cnt=$(printf '%s' "$_prev" | cut -f3); _first=$(printf '%s' "$_prev" | cut -f5)
  else
    _cnt=0; _first=$_ts
  fi
  case "$_cnt" in *[!0-9]*|'') _cnt=0 ;; esac
  _cnt=$((_cnt+1))
  _dbg "record $_d verdict=$_v count=$_cnt thresh=$_thresh"
  _tmp=$(mktemp 2>/dev/null || echo "$CAND.$$")
  awk -F'\t' -v d="$_d" '$1!=d' "$CAND" 2>/dev/null > "$_tmp"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$_d" "$_v" "$_cnt" "$_clients" "$_first" "$_ts" "$_reason" >> "$_tmp"
  mv "$_tmp" "$CAND"
  [ "$_cnt" -ge "$_thresh" ] || return 1
  grep -Fqx "$_d" "$AUTO_LIST" 2>/dev/null && return 1   # already present
  # Size cap with LRU eviction (never evicts force-tunnel.list/manual entries).
  _cap=$(_uci amnezia.config.autolearn_max_entries); _cap=${_cap:-500}
  _count=$(awk 'END{print NR}' "$AUTO_LIST" 2>/dev/null); _count=${_count:-0}
  if [ "$_count" -ge "$_cap" ] 2>/dev/null; then
    _victim=$(awk -F'\t' -v al="$AUTO_LIST" 'FILENAME==al{auto[$0]=1; next} ($1 in auto){print $6"\t"$1}' \
                "$AUTO_LIST" "$CAND" 2>/dev/null | sort -n | head -n1 | cut -f2)
    [ -n "$_victim" ] && { _t=$(mktemp 2>/dev/null || echo "$AUTO_LIST.$$"); grep -Fvx "$_victim" "$AUTO_LIST" > "$_t"; mv "$_t" "$AUTO_LIST"; }
  fi
  _dbg "ADDED $_d to auto.list"
  printf '%s\n' "$_d" >> "$AUTO_LIST"
  return 0
}

# Revalidation: re-probe stale auto entries; drop those that now pass direct.
_al_revalidate() {
  _days=$(_uci amnezia.config.autolearn_revalidate_days); _days=${_days:-14}
  _cut=$(( $(_now) - _days*86400 ))
  [ -s "$AUTO_LIST" ] || return 1
  _changed_local=0
  while IFS= read -r _d; do
    [ -n "$_d" ] || continue
    _lp=$(awk -F'\t' -v d="$_d" '$1==d{print $6; exit}' "$CAND" 2>/dev/null); _lp=${_lp:-0}
    [ "$_lp" -lt "$_cut" ] 2>/dev/null || continue
    _pin=$(al_resolve_public "$_d") || true
    [ -n "$_pin" ] || continue
    _v=$(zapret-probe "$_d" "$_pin" | grep -o '"verdict":"[^"]*"' | sed 's/.*:"//;s/"//')
    if [ "$_v" = direct_ok ]; then
      _t=$(mktemp 2>/dev/null || echo "$AUTO_LIST.$$"); grep -Fvx "$_d" "$AUTO_LIST" > "$_t"; mv "$_t" "$AUTO_LIST"
      _changed_local=1
    else
      # refresh last_probe so we don't re-probe every pass
      _t=$(mktemp 2>/dev/null || echo "$CAND.$$")
      awk -F'\t' -v d="$_d" -v ts="$(_now)" 'BEGIN{OFS="\t"} $1==d{$6=ts} {print}' "$CAND" > "$_t" && mv "$_t" "$CAND"
    fi
  done < "$AUTO_LIST"
  [ "$_changed_local" = 1 ] && return 0 || return 1
}

# _al_prune_candidates: drop candidates.tsv rows whose last_probe is older than
# autolearn_candidate_retention_days AND that are not currently in auto.list.
# Bounds the flash-resident, client-IP-bearing privacy artifact.
_al_prune_candidates() {
  [ -s "$CAND" ] || return 0
  _days=$(_uci amnezia.config.autolearn_candidate_retention_days); _days=${_days:-30}
  _cut=$(( $(_now) - _days*86400 ))
  _t=$(mktemp 2>/dev/null || echo "$CAND.$$")
  awk -F'\t' -v al="$AUTO_LIST" -v cut="$_cut" 'FILENAME==al{auto[$0]=1; next}
    ($1 in auto) || ($6+0 >= cut) {print}' "$AUTO_LIST" "$CAND" > "$_t" && mv "$_t" "$CAND"
}

# Resolve dnsmasq pid: procd pidfile first, then pgrep -f (NOT -x). Empty -> "".
_al_dnsmasq_pid() {
  _pf="${DNSMASQ_PID_FILE:-}"
  if [ -z "$_pf" ]; then for _p in /var/run/dnsmasq/dnsmasq.*.pid; do [ -f "$_p" ] && { _pf="$_p"; break; }; done; fi
  if [ -n "$_pf" ] && [ -f "$_pf" ]; then cat "$_pf" 2>/dev/null; return; fi
  pgrep -f dnsmasq 2>/dev/null | head -n1
}

# Rotate the tmpfs log iff oversize. mv-then-USR2 so dnsmasq reopens at a fresh
# inode/offset 0 with no NUL-hole data loss. Skip entirely (do NOT truncate) if
# no pid resolves — safe: the file keeps growing until a later pass succeeds.
_al_rotate_log() {
  _sz=$(wc -c < "$AL_QUERYLOG" 2>/dev/null || echo 0)
  _sz=$(printf '%s' "$_sz" | tr -d ' \t')
  [ "$_sz" -gt "$AUTOLEARN_LOG_MAX_BYTES" ] 2>/dev/null || return 0
  _pid=$(_al_dnsmasq_pid); [ -n "$_pid" ] || return 0
  mv "$AL_QUERYLOG" "$AL_QUERYLOG.1" 2>/dev/null || return 0
  "$AL_KILL" -USR2 "$_pid" 2>/dev/null || true   # dnsmasq reopens AL_QUERYLOG at 0
  rm -f "$AL_QUERYLOG.1"
  printf '0\n' > "$OFFSET_F"
  # Accepted minor loss: query lines dnsmasq wrote to .1 between this pass's
  # harvest and the mv (a few KB, only when the log crossed 2 MiB) are dropped.
  # Harmless — the candidate pool is recurring popularity, not a one-shot signal;
  # any dropped domain reappears in a later pass's harvest.
}

_changed=0                          # declared BEFORE revalidation so a drop counts
_al_revalidate && _changed=1        # drop stale recovered entries

# --- Harvest pairs since offset (bounded) ----------------------------------
_off=0; [ -f "$OFFSET_F" ] && _off=$(cat "$OFFSET_F" 2>/dev/null || echo 0)
case "$_off" in *[!0-9]*) _off=0 ;; esac
_size=$(wc -c < "$AL_QUERYLOG" 2>/dev/null || echo 0)
_size=$(printf '%s' "$_size" | tr -d ' \t')
case "$_size" in *[!0-9]*|'') _size=0 ;; esac
[ "$_off" -gt "$_size" ] 2>/dev/null && _off=0          # log shrank/rotated
# Bound the slice: if more than AUTOLEARN_HARVEST_MAX_BYTES of new data piled up
# since the last pass (DNS-leak block logs every query), skip the older bytes
# and harvest only the most recent window. A partial first line is simply not
# matched by al_querylog_pairs' query[ regex.
if [ $(( _size - _off )) -gt "$AUTOLEARN_HARVEST_MAX_BYTES" ] 2>/dev/null; then
  _off=$(( _size - AUTOLEARN_HARVEST_MAX_BYTES ))
fi
_pairs=$(al_querylog_pairs "$AL_QUERYLOG" "$_off")
_dbg "harvest: offset=$_off size=$_size pairs=$(printf '%s' "$_pairs" | grep -c .)"
printf '%s\n' "$_size" > "$OFFSET_F"

# --- Candidate selection (ONE awk; replaces a per-line grep/awk fork storm) --
# The former shell loop forked a grep + an awk PER query-log line; under the
# DNS-leak block's huge log that meant tens of thousands of short-lived
# processes per pass -> CPU pegged -> hardware watchdog reset. This single awk
# loads auto.list + deny.list once and does ALL of it inline: probeability,
# RU-skip, suffix-aware deny, per-client fairness cap, >=2-distinct-client
# eligibility, and query-frequency tally. It emits "freq<TAB>domain<TAB>csv"
# per eligible domain; we rank by frequency and keep the top
# autolearn_max_candidates so the probe phase walks a small, bounded set.
_maxpc=$(_uci amnezia.config.autolearn_max_per_client); _maxpc=${_maxpc:-5}
_maxcand=$(_uci amnezia.config.autolearn_max_candidates); _maxcand=${_maxcand:-40}
case "$_maxcand" in *[!0-9]*|'') _maxcand=40 ;; esac
_sel_tmp=$(mktemp 2>/dev/null || echo "/tmp/al-sel.$$")
printf '%s\n' "$_pairs" | awk -v autof="$AUTO_LIST" -v denyf="$DENY" -v maxpc="$_maxpc" '
  BEGIN {
    while ((getline l < autof) > 0) { sub(/[ \t\r]+$/,"",l); if (l!="") auto[l]=1 }
    while ((getline l < denyf) > 0) { gsub(/[ \t\r]/,"",l); if (l!="") deny[l]=1 }
  }
  function probeable(d) {
    if (length(d) < 2 || length(d) > 253) return 0
    if (d ~ /[^A-Za-z0-9._-]/) return 0           # charset (mirror zapret-probe)
    if (d !~ /\./) return 0                        # must have a dot
    if (d !~ /[A-Za-z]/) return 0                  # IP-literal has no letter
    if (d ~ /\.(lan|local|internal|localdomain|home\.arpa|arpa)$/) return 0
    if (d ~ /\.ru$/) return 0                      # RU/.ru -> direct, never probe
    return 1
  }
  function denied(d,   s,i) {                       # suffix-aware (mirror dnsmasq nftset)
    if (d in deny) return 1
    s=d
    while ((i=index(s,".")) > 0) { s=substr(s,i+1); if (s in deny) return 1 }
    return 0
  }
  { dom=$1; ip=$2
    if (dom=="" || ip=="") next
    if (dom in auto) next                           # already pinned
    if (!probeable(dom)) next
    if (denied(dom)) next
    if (++perclient[ip] > maxpc) next               # per-client fairness cap
    freq[dom]++
    if (!(dom SUBSEP ip in seenpair)) {
      seenpair[dom SUBSEP ip]=1
      dcnt[dom]++
      csv[dom] = csv[dom] (csv[dom] ? "," : "") ip
    } }
  END { for (d in dcnt) if (dcnt[d] >= 2) print freq[d] "\t" d "\t" csv[d] }
' | sort -rn | head -n "$_maxcand" > "$_sel_tmp"

_dbg "eligible domains: $(awk 'END{print NR+0}' "$_sel_tmp" 2>/dev/null)"
_max_probes=$(_uci amnezia.config.autolearn_max_probes); _max_probes=${_max_probes:-20}
_n=0
# while-read via REDIRECT (not a pipe) so _changed/_n survive in this shell.
while IFS="$(printf '\t')" read -r _freq _dom _clients; do
  [ -n "$_dom" ] || continue
  [ "$_n" -lt "$_max_probes" ] || break
  _n=$((_n+1))
  _pin=$(al_resolve_public "$_dom"); [ -n "$_pin" ] || { _dbg "probe $_dom pin=EMPTY (SSRF gate)"; continue; }   # SSRF gate
  _verdict=$(zapret-probe "$_dom" "$_pin" | grep -o '"verdict":"[^"]*"' | sed 's/.*:"//;s/"//')
  _dbg "probe $_dom pin=$_pin -> $_verdict"
  if _al_record "$_dom" "$_verdict" "$_clients"; then _changed=1; fi
done < "$_sel_tmp"
rm -f "$_sel_tmp"

_al_rotate_log                                   # bound the tmpfs log
_al_prune_candidates                             # retention
[ "$_changed" = 1 ] && "$AMNEZIA_FORCE_LOAD" >/dev/null 2>&1
exit 0
