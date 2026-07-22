#!/bin/sh
# amnezia-force-load: merge force.d/*.list + force-tunnel.list, classify,
# load IP/CIDR into amnezia_force4 nft set, write chunked nftset= directives
# into a dnsmasq conf-dir file (byte-bounded to avoid the 1KB line-buffer
# limit that breaks dnsmasq with large domain lists).
#
# Also populates amnezia_direct4 from direct-tunnel.list: a direct-override
# set consulted FIRST in the classifier so listed domains always route direct
# (WAN) even when also matched by a broad force range (e.g. chat.google.com
# vs the whole-Google-AS force source). See
# docs/superpowers/specs/2026-07-22-direct-override-set-design.md.
#
# Restart dnsmasq only once, when either set's domain list changed.
# Usage: amnezia-force-load [--flush] [--flush-direct] [save-manual <content>]
AMNEZIA_LIB=${AMNEZIA_LIB:-/usr/lib/amnezia}
if [ -f "$AMNEZIA_LIB/amnezia-common.sh" ]; then
  # shellcheck disable=SC1091
  . "$AMNEZIA_LIB/amnezia-common.sh"
else
  # shellcheck disable=SC1091
  . "$(dirname "$0")/lib/amnezia-common.sh"
fi
# shellcheck disable=SC1091
if [ -f "$AMNEZIA_LIB/amnezia-dns-lib.sh" ]; then . "$AMNEZIA_LIB/amnezia-dns-lib.sh"
elif [ -f "$(dirname "$0")/lib/amnezia-dns-lib.sh" ]; then . "$(dirname "$0")/lib/amnezia-dns-lib.sh"; fi

FORCE_DIR="${FORCE_DIR:-/etc/amnezia}"
FORCE_LOCK="${FORCE_LOCK:-/var/lock/amnezia-force.lock}"
# Init-script path for dnsmasq restart.  Overridable so test stubs intercept it.
# dnsmasq restart is SSH-safe (unlike fw4 reload which drops the SSH session);
# no backgrounding needed — synchronous restart is deterministic and testable.
AMNEZIA_DNSMASQ_INIT="${AMNEZIA_DNSMASQ_INIT:-/etc/init.d/dnsmasq}"
# Conf-dir for chunked nftset= directives.  Overridable for tests.
# OpenWrt dnsmasq.init emits --conf-dir=<dir> when dhcp.@dnsmasq[0].confdir
# is set; all files in that dir are picked up automatically.
AMZ_DNSMASQ_CONFDIR="${AMZ_DNSMASQ_CONFDIR:-/etc/amnezia/dnsmasq.d}"
SET_FORCE4=amnezia_force4
SET_DIRECT4=amnezia_direct4

# Parse --flush / --flush-direct flags: each SET-SCOPED, and each must appear
# as a leading argument (in any order relative to each other) when specified.
# By default force-load is add-only: runtime dnsmasq-resolved entries (CDN IPs
# placed into amnezia_force4/amnezia_direct4 by nftset directives when domains
# are resolved) must survive reloads.  The classifier marks traffic per-packet
# with no conntrack restore, so flushing a set instantly strips the fwmark
# from ESTABLISHED flows to those IPs — causing a mid-flow route flip and
# killing TLS sessions.  Stale entries are acceptable; the volatile sets are
# cleared on the next fw4 reload or boot (fw4 re-declares them empty from the
# .nft classifier include).
#
# --flush        flush ONLY amnezia_force4 (existing callers: force-update,
#                 app-ctl, set-routing-mode — all intend the force set).
# --flush-direct  flush ONLY amnezia_direct4 (direct-remove).
#
# The two flags are independent: a caller flushing one set must NOT flush the
# other (H1: direct-remove --flush used to evict amnezia_force4 too).
_do_flush_force=0
_do_flush_direct=0
while [ "$1" = "--flush" ] || [ "$1" = "--flush-direct" ]; do
  case "$1" in
    --flush) _do_flush_force=1 ;;
    --flush-direct) _do_flush_direct=1 ;;
  esac
  shift
done

# Capture save-manual arguments before entering the subshell.
_save_manual=0
_save_manual_content=""
if [ "$1" = save-manual ]; then
  _save_manual=1
  _save_manual_content="$2"
fi

# Acquire advisory lock (BusyBox flock: flock <fd> <cmd> or exec with fd).
# Use a subshell with fd redirect so the lock is released on exit.
# Fallback lock path to FORCE_DIR if the canonical dir is not writable.
_lock_dir="$(dirname "$FORCE_LOCK")"
if ! mkdir -p "$_lock_dir" 2>/dev/null && [ ! -d "$_lock_dir" ]; then
  FORCE_LOCK="$FORCE_DIR/amnezia-force.lock"
fi

# _amz_populate_set <set_name> <conf_basename> <hash_basename> <flush_this_set> <source_file>...
#
# Merges the given source files (nonexistent paths are silently skipped, so
# callers can pass an unexpanded glob), classifies each entry into IP/CIDR vs
# domain, batch-loads IP/CIDR into the nft set (flushing first only when
# <flush_this_set>=1 — SET-SCOPED, passed in per call so --flush/--flush-direct
# never cross-affect the other set), and — only when the domain list's hash
# changed from the persisted <hash_basename> — writes byte-chunked nftset=
# directives for the domains into $AMZ_DNSMASQ_CONFDIR/<conf_basename> and sets
# _amz_set_changed=1 (never resets it to 0, so the caller can OR the result
# across multiple sets and fire a single shared dnsmasq restart).
_amz_populate_set() {
  _aps_set="$1"; _aps_conf="$2"; _aps_hash="$3"; _aps_flush="$4"; shift 4

  mkdir -p "$FORCE_DIR/force.d"
  _tmp_merged=$(mktemp "$FORCE_DIR/force.d/.amz-merged.XXXXXX" 2>/dev/null \
    || echo "$FORCE_DIR/force.d/amz-merged.$$.$_aps_set")
  : > "$_tmp_merged"
  for _f in "$@"; do
    [ -f "$_f" ] || continue
    cat "$_f" >> "$_tmp_merged"
  done

  # Separate into IPs/CIDRs and domains, dedup each.
  _tmp_ips=$(mktemp "$FORCE_DIR/force.d/.amz-ips.XXXXXX" 2>/dev/null \
    || echo "$FORCE_DIR/force.d/amz-ips.$$.$_aps_set")
  _tmp_domains=$(mktemp "$FORCE_DIR/force.d/.amz-domains.XXXXXX" 2>/dev/null \
    || echo "$FORCE_DIR/force.d/amz-domains.$$.$_aps_set")
  : > "$_tmp_ips"
  : > "$_tmp_domains"

  while IFS= read -r _line; do
    # Strip leading/trailing whitespace.
    _line=$(printf '%s' "$_line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    # Skip comments and blank lines.
    case "$_line" in ''|\#*) continue ;; esac
    # Classify: IP (x.x.x.x) or CIDR (x.x.x.x/n) -> IP set; else domain.
    case "$_line" in
      *[0-9].*[0-9].*[0-9].*[0-9]*)
        # Looks like IPv4 (with or without /prefix). Validate (H3).
        # Mirror amnezia-ru-cidr.sh:31-39: reject non-dotted-quad or garbage after prefix.
        _addr="${_line%%/*}"
        # Reject non-numeric/dot in the address part.
        case "$_addr" in
          *[!0-9.]*) printf '%s\n' "$_line" >> "$_tmp_domains"; continue ;;
        esac
        # Address must be dotted-quad: exactly three dots.
        case "$_addr" in
          *.*.*.*) ;;
          *) printf '%s\n' "$_line" >> "$_tmp_domains"; continue ;;
        esac
        # Validate each octet is in 0-255; reject if any octet is out-of-range.
        _o1="${_addr%%.*}"; _rest="${_addr#*.}"
        _o2="${_rest%%.*}"; _rest="${_rest#*.}"
        _o3="${_rest%%.*}"; _o4="${_rest#*.}"
        _octet_ok=1
        for _o in "$_o1" "$_o2" "$_o3" "$_o4"; do
          case "$_o" in
            ''|*[!0-9]*) _octet_ok=0; break ;;
          esac
          [ "$_o" -le 255 ] 2>/dev/null || { _octet_ok=0; break; }
        done
        [ "$_octet_ok" = 1 ] || continue
        # If a prefix length is present, validate it is purely numeric.
        case "$_line" in
          */*)
            _len="${_line##*/}"
            case "$_len" in
              *[!0-9]*) continue ;;  # malformed prefix length — skip entirely
            esac
            ;;
        esac
        printf '%s\n' "$_line" >> "$_tmp_ips"
        ;;
      *)
        printf '%s\n' "$_line" >> "$_tmp_domains"
        ;;
    esac
  done < "$_tmp_merged"
  rm -f "$_tmp_merged"

  # Dedup in-place.
  if command -v sort >/dev/null 2>&1; then
    _s=$(sort -u "$_tmp_ips"); printf '%s\n' "$_s" > "$_tmp_ips"
    _s=$(sort -u "$_tmp_domains"); printf '%s\n' "$_s" > "$_tmp_domains"
  fi

  # --- H2: compute domain hash BEFORE any dhcp/dnsmasq work ---
  # If the domain list is unchanged, skip the conf-dir rebuild (and let the
  # caller skip the dnsmasq restart).  This means fw4-reload hotplug calls
  # (where only IPs change) never touch dhcp config or restart dnsmasq.
  _new_hash=$(sort "$_tmp_domains" 2>/dev/null | md5sum 2>/dev/null | awk '{print $1}')
  _old_hash=""
  if [ -f "$FORCE_DIR/$_aps_hash" ]; then
    _old_hash=$(cat "$FORCE_DIR/$_aps_hash" 2>/dev/null || true)
  fi

  # Load IPs/CIDRs into the nft set (batch like amnezia-ru-cidr).
  # Flush only when THIS set's flush flag was requested (set-scoped; see
  # comment at top for rationale and the H1 cross-set flush bug this fixes).
  if [ "$_aps_flush" = 1 ]; then
    nft flush set inet fw4 "$_aps_set" 2>/dev/null || true
  fi
  _n=0; _buf=""
  while IFS= read -r _c; do
    [ -n "$_c" ] || continue
    if [ -z "$_buf" ]; then _buf="$_c,"; else _buf="${_buf} ${_c},"; fi
    _n=$((_n + 1))
    if [ "$_n" -ge 256 ]; then
      nft add element inet fw4 "$_aps_set" "{ ${_buf%,} }" 2>/dev/null || true
      _buf=""; _n=0
    fi
  done < "$_tmp_ips"
  if [ -n "$_buf" ]; then
    nft add element inet fw4 "$_aps_set" "{ ${_buf%,} }" 2>/dev/null || true
  fi
  rm -f "$_tmp_ips"

  # Only rebuild dnsmasq conf-dir nftset directives when this set's domain
  # list has changed.  The dnsmasq restart itself is fired once by the caller
  # after both sets have been populated.
  if [ "$_new_hash" != "$_old_hash" ]; then
    # --- Write byte-bounded chunked nftset= directives ---
    # Each nftset= line is kept under 900 bytes to stay well clear of dnsmasq's
    # internal config-line buffer (empirically ~1024 bytes; 16KB+ lines from the
    # legacy config-ipset section caused "bad option" / dnsmasq startup failure).
    mkdir -p "$AMZ_DNSMASQ_CONFDIR"
    _tmp_conf=$(mktemp "$AMZ_DNSMASQ_CONFDIR/.amz-conf.XXXXXX" 2>/dev/null \
      || echo "$AMZ_DNSMASQ_CONFDIR/.amz-conf.$$.$_aps_set")
    if [ -s "$_tmp_domains" ]; then
      awk -v set="$_aps_set" '
        function flush(){ if(buf!=""){ print "nftset=" buf "/4#inet#fw4#" set; buf="" } }
        { gsub(/[ \t\r]/,""); sub(/^\./,""); if($0=="") next;
          cand=buf "/" $0;
          if(length(cand) > 900){ flush(); buf="/" $0 } else { buf=cand } }
        END{ flush() }
      ' "$_tmp_domains" > "$_tmp_conf"
    else
      # Empty domain list: write an empty file so any previous nftset
      # directives are removed on the next dnsmasq restart.
      : > "$_tmp_conf"
    fi
    mv "$_tmp_conf" "$AMZ_DNSMASQ_CONFDIR/$_aps_conf"
    printf '%s\n' "$_new_hash" > "$FORCE_DIR/$_aps_hash"
    _amz_set_changed=1
  fi
  rm -f "$_tmp_domains"
}

(
  # Open fd 9 for the lock file and take an exclusive lock (BusyBox flock).
  # Gracefully skip locking if flock is not available (e.g. macOS dev/test env).
  # shellcheck disable=SC2094
  exec 9>"$FORCE_LOCK"
  flock -x 9 2>/dev/null || true

  # M2: save-manual: mkdir + write performed inside the flock so no other
  # invocation can race the manual-list write against the merge pass below.
  if [ "$_save_manual" = 1 ]; then
    mkdir -p "$FORCE_DIR"
    printf '%s\n' "$_save_manual_content" > "$FORCE_DIR/force-tunnel.list"
    chmod 644 "$FORCE_DIR/force-tunnel.list"
  fi

  _amz_set_changed=0

  # amnezia_force4: force.d/*.list sources + the manual force-tunnel.list.
  # Behaviour is byte-identical to before the direct-override refactor.
  # shellcheck disable=SC2086
  _amz_populate_set "$SET_FORCE4" amnezia-force.conf .force-domains.hash \
    "$_do_flush_force" \
    "$FORCE_DIR/force.d/"*.list "$FORCE_DIR/force-tunnel.list"

  # amnezia_direct4: direct-override list only (see design doc header comment).
  # Consulted FIRST in the classifier so listed domains always route direct
  # even when also matched by a broad force range.
  _amz_populate_set "$SET_DIRECT4" amnezia-direct.conf .direct-domains.hash \
    "$_do_flush_direct" \
    "$FORCE_DIR/direct-tunnel.list"

  # Fire a single dnsmasq restart if EITHER set's domain list changed.
  if [ "$_amz_set_changed" = 1 ]; then
    command -v dnsmasq_lock >/dev/null 2>&1 && dnsmasq_lock
    # --- Wire the conf-dir into dnsmasq UCI (idempotent) ---
    # OpenWrt dnsmasq.init picks up all files in confdir via --conf-dir=<dir>.
    # We use this to deliver byte-bounded chunked nftset= lines instead of the
    # legacy config-ipset section which rendered a single nftset line that could
    # exceed dnsmasq's ~1024-byte line buffer for large domain lists.
    _cur_confdir=$(uci -q get dhcp.@dnsmasq[0].confdir 2>/dev/null || true)
    if [ "$_cur_confdir" != "$AMZ_DNSMASQ_CONFDIR" ]; then
      uci set "dhcp.@dnsmasq[0].confdir=$AMZ_DNSMASQ_CONFDIR"
      uci commit dhcp
    fi

    # --- Migration: remove legacy config-ipset section if present ---
    if uci -q get dhcp.amnezia_force >/dev/null 2>&1; then
      uci -q delete dhcp.amnezia_force 2>/dev/null || true
      uci commit dhcp
    fi

    # Restart dnsmasq to pick up changed nftset directives.
    # dnsmasq restart is SSH-safe (unlike fw4 reload); kept synchronous for
    # deterministic behaviour in tests and on-router.
    "$AMNEZIA_DNSMASQ_INIT" restart 2>/dev/null || true
    command -v dnsmasq_unlock >/dev/null 2>&1 && dnsmasq_unlock
  fi
)
