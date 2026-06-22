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
AL_LOCK="${AL_LOCK:-/var/lock/amnezia-autolearn.lock}"
AUTO_LIST="$AL_DIR/force.d/auto.list"
CAND="$AL_DIR/autolearn/candidates.tsv"
DENY="$AL_DIR/autolearn/deny.list"
OFFSET_F="$AL_DIR/autolearn/.dnsmasq-log.offset"
AUTOLEARN_STATE_MAX_AGE="${AUTOLEARN_STATE_MAX_AGE:-120}"
AUTOLEARN_LOG_MAX_BYTES="${AUTOLEARN_LOG_MAX_BYTES:-2097152}"
AMNEZIA_FORCE_LOAD="${AMNEZIA_FORCE_LOAD:-amnezia-force-load}"
# `kill` is a shell builtin — a PATH stub is never reached. Route the signal
# through this indirection so tests can inject a logging shim via AL_KILL.
AL_KILL="${AL_KILL:-kill}"

_uci() { uci -q get "$1" 2>/dev/null; }
_now() { date +%s 2>/dev/null || echo 0; }

# --- Gate -------------------------------------------------------------------
[ "$(_uci amnezia.config.routing_mode)" = "direct-default" ] || exit 0
[ "$(_uci amnezia.config.autolearn_enabled)" = "1" ] || exit 0
# Tunnel health: state file must exist, be fresh, and report all_down:false.
[ -f "$AL_STATE" ] || exit 0
_mtime=$(date -r "$AL_STATE" +%s 2>/dev/null || stat -c %Y "$AL_STATE" 2>/dev/null || echo 0)
_age=$(( $(_now) - _mtime ))
[ "$_age" -le "$AUTOLEARN_STATE_MAX_AGE" ] 2>/dev/null || exit 0
_alldown=$(grep -o '"all_down":[a-z]*' "$AL_STATE" 2>/dev/null | head -n1 | sed 's/.*://')
[ "$_alldown" = "false" ] || exit 0

mkdir -p "$AL_DIR/force.d" "$AL_DIR/autolearn"

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
    _victim=$(awk -F'\t' 'NR==FNR{auto[$0]=1; next} ($1 in auto){print $6"\t"$1}' \
                "$AUTO_LIST" "$CAND" 2>/dev/null | sort -n | head -n1 | cut -f2)
    [ -n "$_victim" ] && { _t=$(mktemp 2>/dev/null || echo "$AUTO_LIST.$$"); grep -Fvx "$_victim" "$AUTO_LIST" > "$_t"; mv "$_t" "$AUTO_LIST"; }
  fi
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
  awk -F'\t' -v cut="$_cut" 'NR==FNR{auto[$0]=1; next}
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

# --- Lock (advisory; flock may be absent in dev/test) -----------------------
exec 9>"$AL_LOCK" 2>/dev/null || true
flock -n 9 2>/dev/null || true     # NEVER `|| exit` — matches force-load idiom

_changed=0                          # declared BEFORE revalidation so a drop counts
_al_revalidate && _changed=1        # drop stale recovered entries

# --- Harvest pairs since offset --------------------------------------------
_off=0; [ -f "$OFFSET_F" ] && _off=$(cat "$OFFSET_F" 2>/dev/null || echo 0)
case "$_off" in *[!0-9]*) _off=0 ;; esac
_size=$(wc -c < "$AL_QUERYLOG" 2>/dev/null || echo 0)
_size=$(printf '%s' "$_size" | tr -d ' \t')
_pairs=$(al_querylog_pairs "$AL_QUERYLOG" "$_off")
printf '%s\n' "$_size" > "$OFFSET_F"

# Tally (domain, client) pairs this pass. Skip RU/.ru and denied up front.
# NOTE: write to the tmp file inside the loop's OWN process (here-string, not a
# pipe) so it is not lost to a pipeline subshell.
_cand_tmp=$(mktemp 2>/dev/null || echo "/tmp/al-cand.$$"); : > "$_cand_tmp"
printf '%s\n' "$_pairs" > "${_cand_tmp}.raw"
while read -r _dom _ip; do
  [ -n "$_dom" ] || continue
  case "$_dom" in *.ru) continue ;; esac
  al_name_is_probeable "$_dom" || continue
  al_deny_match "$_dom" "$DENY" && continue
  grep -Fqx "$_dom" "$AUTO_LIST" 2>/dev/null && continue
  printf '%s\t%s\n' "$_dom" "$_ip" >> "$_cand_tmp"
done < "${_cand_tmp}.raw"
rm -f "${_cand_tmp}.raw"

# Per-client fairness cap + distinct-client (>=2) eligibility, in one awk.
# - drop pairs beyond autolearn_max_per_client for any single client IP
# - a domain is eligible iff >=2 DISTINCT client IPs resolved it
# Also emit, for each eligible domain, its distinct-client CSV for candidates.tsv.
_maxpc=$(_uci amnezia.config.autolearn_max_per_client); _maxpc=${_maxpc:-5}
_eligible=$(awk -F'\t' -v maxpc="$_maxpc" '
  { dom=$1; ip=$2
    if (++perclient[ip] > maxpc) next            # fairness cap per client IP
    if (!(dom SUBSEP ip in seenpair)) { seenpair[dom SUBSEP ip]=1; dcnt[dom]++ } }
  END { for (d in dcnt) if (dcnt[d] >= 2) print d }' "$_cand_tmp")
# clients CSV per domain (for the TSV record).
_clients_for() {
  awk -F'\t' -v d="$1" '$1==d{ if(!(d SUBSEP $2 in s)){s[d SUBSEP $2]=1; c=c (c?",":"") $2} } END{print c}' "$_cand_tmp"
}

_max_probes=$(_uci amnezia.config.autolearn_max_probes); _max_probes=${_max_probes:-20}
_n=0
for _dom in $_eligible; do
  [ "$_n" -lt "$_max_probes" ] || break
  _n=$((_n+1))
  _pin=$(al_resolve_public "$_dom"); [ -n "$_pin" ] || continue   # SSRF gate
  _verdict=$(zapret-probe "$_dom" "$_pin" | grep -o '"verdict":"[^"]*"' | sed 's/.*:"//;s/"//')
  if _al_record "$_dom" "$_verdict" "$(_clients_for "$_dom")"; then _changed=1; fi
done
rm -f "$_cand_tmp"

_al_rotate_log                                   # bound the tmpfs log
_al_prune_candidates                             # retention
[ "$_changed" = 1 ] && "$AMNEZIA_FORCE_LOAD" >/dev/null 2>&1
exit 0
