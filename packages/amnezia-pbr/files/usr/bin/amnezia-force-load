#!/bin/sh
# amnezia-force-load: merge force.d/*.list + force-tunnel.list, classify,
# load IP/CIDR into amnezia_force4 nft set, write chunked nftset= directives
# into a dnsmasq conf-dir file (byte-bounded to avoid the 1KB line-buffer
# limit that breaks dnsmasq with large domain lists).
# Restart dnsmasq only when domain list changed.
# Usage: amnezia-force-load [save-manual <content>]
AMNEZIA_LIB=${AMNEZIA_LIB:-/usr/lib/amnezia}
if [ -f "$AMNEZIA_LIB/amnezia-common.sh" ]; then
  # shellcheck disable=SC1091
  . "$AMNEZIA_LIB/amnezia-common.sh"
else
  # shellcheck disable=SC1091
  . "$(dirname "$0")/lib/amnezia-common.sh"
fi

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

  # Merge all source lists and the manual list into a temp file, dedup.
  # Use the same filesystem as FORCE_DIR so mv is an atomic rename (M1).
  mkdir -p "$FORCE_DIR/force.d"
  _tmp_merged=$(mktemp "$FORCE_DIR/force.d/.amz-merged.XXXXXX" 2>/dev/null \
    || echo "$FORCE_DIR/force.d/amz-force-merged.$$")
  : > "$_tmp_merged"
  for _f in "$FORCE_DIR/force.d/"*.list; do
    [ -f "$_f" ] || continue
    cat "$_f" >> "$_tmp_merged"
  done
  if [ -f "$FORCE_DIR/force-tunnel.list" ]; then
    cat "$FORCE_DIR/force-tunnel.list" >> "$_tmp_merged"
  fi

  # Separate into IPs/CIDRs and domains, dedup each.
  _tmp_ips=$(mktemp "$FORCE_DIR/force.d/.amz-ips.XXXXXX" 2>/dev/null \
    || echo "$FORCE_DIR/force.d/amz-force-ips.$$")
  _tmp_domains=$(mktemp "$FORCE_DIR/force.d/.amz-domains.XXXXXX" 2>/dev/null \
    || echo "$FORCE_DIR/force.d/amz-force-domains.$$")
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
  # If the domain list is unchanged, skip the entire UCI rebuild + dnsmasq
  # restart.  This means fw4-reload hotplug calls (where only IPs change)
  # never touch dhcp config or restart dnsmasq.
  _new_hash=$(sort "$_tmp_domains" 2>/dev/null | md5sum 2>/dev/null | awk '{print $1}')
  _old_hash=""
  if [ -f "$FORCE_DIR/.force-domains.hash" ]; then
    _old_hash=$(cat "$FORCE_DIR/.force-domains.hash" 2>/dev/null || true)
  fi

  # Load IPs/CIDRs into amnezia_force4 (batch like amnezia-ru-cidr).
  nft flush set inet fw4 "$SET_FORCE4" 2>/dev/null || true
  _n=0; _buf=""
  while IFS= read -r _c; do
    [ -n "$_c" ] || continue
    if [ -z "$_buf" ]; then _buf="$_c,"; else _buf="${_buf} ${_c},"; fi
    _n=$((_n + 1))
    if [ "$_n" -ge 256 ]; then
      nft add element inet fw4 "$SET_FORCE4" "{ ${_buf%,} }" 2>/dev/null || true
      _buf=""; _n=0
    fi
  done < "$_tmp_ips"
  if [ -n "$_buf" ]; then
    nft add element inet fw4 "$SET_FORCE4" "{ ${_buf%,} }" 2>/dev/null || true
  fi
  rm -f "$_tmp_ips"

  # Only rebuild dnsmasq conf-dir nftset directives and restart dnsmasq when
  # the domain set has changed.
  if [ "$_new_hash" != "$_old_hash" ]; then
    # --- Wire the conf-dir into dnsmasq UCI (idempotent) ---
    # OpenWrt dnsmasq.init picks up all files in confdir via --conf-dir=<dir>.
    # We use this to deliver byte-bounded chunked nftset= lines instead of the
    # legacy config-ipset section which rendered a single nftset line that could
    # exceed dnsmasq's ~1024-byte line buffer for large domain lists.
    _confdir_changed=0
    _cur_confdir=$(uci -q get dhcp.@dnsmasq[0].confdir 2>/dev/null || true)
    if [ "$_cur_confdir" != "$AMZ_DNSMASQ_CONFDIR" ]; then
      uci set "dhcp.@dnsmasq[0].confdir=$AMZ_DNSMASQ_CONFDIR"
      uci commit dhcp
      _confdir_changed=1
    fi

    # --- Migration: remove legacy config-ipset section if present ---
    if uci -q get dhcp.amnezia_force >/dev/null 2>&1; then
      uci -q delete dhcp.amnezia_force 2>/dev/null || true
      uci commit dhcp
    fi

    # --- Write byte-bounded chunked nftset= directives ---
    # Each nftset= line is kept under 900 bytes to stay well clear of dnsmasq's
    # internal config-line buffer (empirically ~1024 bytes; 16KB+ lines from the
    # legacy config-ipset section caused "bad option" / dnsmasq startup failure).
    mkdir -p "$AMZ_DNSMASQ_CONFDIR"
    _tmp_conf=$(mktemp "$AMZ_DNSMASQ_CONFDIR/.amz-force-conf.XXXXXX" 2>/dev/null \
      || echo "$AMZ_DNSMASQ_CONFDIR/.amz-force-conf.$$")
    if [ -s "$_tmp_domains" ]; then
      awk -v set="$SET_FORCE4" '
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
    mv "$_tmp_conf" "$AMZ_DNSMASQ_CONFDIR/amnezia-force.conf"

    printf '%s\n' "$_new_hash" > "$FORCE_DIR/.force-domains.hash"
    # Restart dnsmasq to pick up changed nftset directives.
    # dnsmasq restart is SSH-safe (unlike fw4 reload); kept synchronous for
    # deterministic behaviour in tests and on-router.
    "$AMNEZIA_DNSMASQ_INIT" restart 2>/dev/null || true
  fi
  rm -f "$_tmp_domains"
)
