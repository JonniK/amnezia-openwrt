#!/bin/sh
# Save any caller-provided overrides before the common lib sets its defaults.
_RU_SRC_OVERRIDE="${RU_SRC:-}"
_RU_CIDR_OVERRIDE="${RU_CIDR_PERSIST:-}"
if [ -f /usr/lib/amnezia/amnezia-common.sh ]; then
  # shellcheck disable=SC1091
  . /usr/lib/amnezia/amnezia-common.sh
else
  # shellcheck disable=SC1091
  . "$(dirname "$0")/lib/amnezia-common.sh"
fi
# Caller env vars take precedence over lib defaults.
RU_SRC="${_RU_SRC_OVERRIDE:-${RU_SRC:-https://www.ipdeny.com/ipblocks/data/countries/ru.zone}}"
RU_CIDR_PERSIST="${_RU_CIDR_OVERRIDE:-${RU_CIDR_PERSIST:-/etc/amnezia/ru.cidr}}"
TMP=$(mktemp 2>/dev/null || echo /tmp/ru.$$)

fetch() {
  case "$RU_SRC" in
    file://*) cp "${RU_SRC#file://}" "$TMP" 2>/dev/null ;;
    *) uclient-fetch -qO "$TMP" "$RU_SRC" 2>/dev/null || wget -qO "$TMP" "$RU_SRC" 2>/dev/null ;;
  esac
}

# Load CIDRs from $1 file into the nft set. Returns non-zero if any nft call fails.
_load_into_set() {
  _src_file=$1
  _any_fail=0
  nft flush set inet fw4 "$SET_RU4" 2>/dev/null || true
  _n=0; _buf=""
  while IFS= read -r _c; do
    # Validate IPv4-CIDR shape: x.x.x.x/n — skip lines that don't match.
    case "$_c" in */*) ;; *) continue ;; esac
    case "$_c" in
      *[!0-9./]*) continue ;;   # reject anything containing non-numeric/dot/slash chars
    esac
    # Require exactly one slash and dotted-quad prefix.
    _prefix="${_c%/*}"; _len="${_c##*/}"
    case "$_prefix" in *.*.*.*) ;; *) continue ;; esac
    case "$_len" in *[!0-9]*) continue ;; esac
    if [ -z "$_buf" ]; then _buf="$_c,"; else _buf="${_buf} ${_c},"; fi
    _n=$((_n+1))
    if [ "$_n" -ge 256 ]; then
      nft add element inet fw4 "$SET_RU4" "{ ${_buf%,} }" 2>/dev/null || _any_fail=1
      _buf=""; _n=0
    fi
  done < "$_src_file"
  if [ -n "$_buf" ]; then
    nft add element inet fw4 "$SET_RU4" "{ ${_buf%,} }" 2>/dev/null || _any_fail=1
  fi
  return "$_any_fail"
}

if ! fetch || [ ! -s "$TMP" ]; then
  amz_log "ru-cidr: fetch failed, keeping existing $RU_CIDR_PERSIST"
  rm -f "$TMP"
  # Persist-restore: repopulate from saved file if it exists (boot/fetch-failure path).
  if [ -f "$RU_CIDR_PERSIST" ] && [ -s "$RU_CIDR_PERSIST" ]; then
    _load_into_set "$RU_CIDR_PERSIST"
    amz_log "ru-cidr: repopulated $SET_RU4 from persist $RU_CIDR_PERSIST"
  fi
  exit 1
fi

# Flush + repopulate set from fresh download.
if _load_into_set "$TMP"; then
  # Only overwrite persist file when load succeeded.
  cp "$TMP" "$RU_CIDR_PERSIST"
  amz_log "ru-cidr: loaded into $SET_RU4"
else
  amz_log "ru-cidr: nft add element failed, persist file not updated"
  rm -f "$TMP"
  exit 1
fi
rm -f "$TMP"
exit 0
