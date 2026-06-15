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
if ! fetch || [ ! -s "$TMP" ]; then
  amz_log "ru-cidr: fetch failed, keeping existing $RU_CIDR_PERSIST"
  rm -f "$TMP"; exit 1
fi
# Flush + repopulate set, then persist.
nft flush set inet fw4 "$SET_RU4" 2>/dev/null
# batch in chunks of 256 to avoid arg limits
_n=0; _buf=""
while IFS= read -r _c; do
  case "$_c" in */*) ;; *) continue ;; esac
  if [ -z "$_buf" ]; then _buf="$_c,"; else _buf="${_buf} ${_c},"; fi
  _n=$((_n+1))
  if [ "$_n" -ge 256 ]; then
    nft add element inet fw4 "$SET_RU4" "{ ${_buf%,} }" 2>/dev/null
    _buf=""; _n=0
  fi
done < "$TMP"
[ -n "$_buf" ] && nft add element inet fw4 "$SET_RU4" "{ ${_buf%,} }" 2>/dev/null
cp "$TMP" "$RU_CIDR_PERSIST"; rm -f "$TMP"
amz_log "ru-cidr: loaded into $SET_RU4"
exit 0
