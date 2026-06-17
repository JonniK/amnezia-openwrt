#!/bin/sh
# amnezia-force-load: merge force.d/*.list + force-tunnel.list, classify,
# load IP/CIDR into amnezia_force4 nft set, rebuild dhcp.amnezia_force
# ipset domain entries. Restart dnsmasq only when domain list changed.
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
SET_FORCE4=amnezia_force4

# save-manual: write content to force-tunnel.list, then fall through to load.
if [ "$1" = save-manual ]; then
  printf '%s\n' "$2" > "$FORCE_DIR/force-tunnel.list"
  chmod 644 "$FORCE_DIR/force-tunnel.list"
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

  # Merge all source lists and the manual list into a temp file, dedup.
  _tmp_merged=$(mktemp 2>/dev/null || echo "/tmp/amz-force-merged.$$")
  : > "$_tmp_merged"
  for _f in "$FORCE_DIR/force.d/"*.list; do
    [ -f "$_f" ] || continue
    cat "$_f" >> "$_tmp_merged"
  done
  if [ -f "$FORCE_DIR/force-tunnel.list" ]; then
    cat "$FORCE_DIR/force-tunnel.list" >> "$_tmp_merged"
  fi

  # Separate into IPs/CIDRs and domains, dedup each.
  _tmp_ips=$(mktemp 2>/dev/null || echo "/tmp/amz-force-ips.$$")
  _tmp_domains=$(mktemp 2>/dev/null || echo "/tmp/amz-force-domains.$$")
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
        # Looks like IPv4 (with or without /prefix). Validate.
        _addr="${_line%%/*}"
        case "$_addr" in
          *[!0-9.]*) printf '%s\n' "$_line" >> "$_tmp_domains"; continue ;;
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

  # Rebuild dhcp.amnezia_force config ipset domain entries.
  uci -q delete dhcp.amnezia_force 2>/dev/null || true
  uci set dhcp.amnezia_force='ipset'
  uci add_list dhcp.amnezia_force.name="$SET_FORCE4"
  uci set dhcp.amnezia_force.table='fw4'
  uci set dhcp.amnezia_force.table_family='inet'
  while IFS= read -r _dom; do
    [ -n "$_dom" ] || continue
    uci add_list "dhcp.amnezia_force.domain=$_dom"
  done < "$_tmp_domains"
  uci commit dhcp

  # Compare domain hash to decide if dnsmasq restart is needed.
  _new_hash=$(sort "$_tmp_domains" 2>/dev/null | md5sum 2>/dev/null | awk '{print $1}')
  _old_hash=""
  if [ -f "$FORCE_DIR/.force-domains.hash" ]; then
    _old_hash=$(cat "$FORCE_DIR/.force-domains.hash" 2>/dev/null || true)
  fi
  rm -f "$_tmp_domains"

  if [ "$_new_hash" != "$_old_hash" ]; then
    printf '%s\n' "$_new_hash" > "$FORCE_DIR/.force-domains.hash"
    # Restart dnsmasq to pick up changed ipset domains.
    # Called via PATH so the test stub intercepts it.
    dnsmasq restart 2>/dev/null || true
  fi
)
