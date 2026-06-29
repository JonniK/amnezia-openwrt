#!/bin/sh
# amnezia-app-ctl: manage per-app CIDR lists (force_source sections).
# Verbs: list, add, remove, enable, disable
# shellcheck source=lib/amnezia-common.sh
AMNEZIA_LIB=${AMNEZIA_LIB:-/usr/lib/amnezia}
if [ -f "$AMNEZIA_LIB/amnezia-common.sh" ]; then
  # shellcheck disable=SC1091
  . "$AMNEZIA_LIB/amnezia-common.sh"
else
  # shellcheck disable=SC1091
  . "$(dirname "$0")/lib/amnezia-common.sh"
fi

FORCE_DIR="${FORCE_DIR:-/etc/amnezia}"

# ---------------------------------------------------------------------------
# Preset definitions
# ---------------------------------------------------------------------------
PRESET_IDS="telegram meta x discord tiktok viber linkedin netflix"

_preset_expand() {
  _pid="$1"
  case "$_pid" in
    telegram)
      # Hardcoded Telegram IPv4 ranges (stable ASN-independent list).
      PRESET_METHOD="static"
      PRESET_TITLE="Telegram"
      PRESET_DATA="91.108.4.0/22 91.108.8.0/22 91.108.12.0/22 91.108.16.0/22 91.108.20.0/22 91.108.56.0/22 91.105.192.0/23 149.154.160.0/20 185.76.151.0/24"
      ;;
    meta)
      # Meta (WhatsApp / Instagram / Facebook) — AS32934.
      PRESET_METHOD="as"
      PRESET_TITLE="Meta (WhatsApp/Instagram/FB)"
      PRESET_DATA="32934"
      ;;
    x)
      # X (Twitter) — AS13414.
      PRESET_METHOD="as"
      PRESET_TITLE="X (Twitter)"
      PRESET_DATA="13414"
      ;;
    discord)
      # Discord — AS49544.
      PRESET_METHOD="as"
      PRESET_TITLE="Discord"
      PRESET_DATA="49544"
      ;;
    tiktok)
      # TikTok — AS396986.
      PRESET_METHOD="as"
      PRESET_TITLE="TikTok"
      PRESET_DATA="396986"
      ;;
    viber)
      # Viber — AS30873.
      PRESET_METHOD="as"
      PRESET_TITLE="Viber"
      PRESET_DATA="30873"
      ;;
    linkedin)
      # LinkedIn — AS14413.
      PRESET_METHOD="as"
      PRESET_TITLE="LinkedIn"
      PRESET_DATA="14413"
      ;;
    netflix)
      # Netflix — AS2906.
      PRESET_METHOD="as"
      PRESET_TITLE="Netflix"
      PRESET_DATA="2906"
      ;;
    *)
      echo "app-ctl: unknown preset '$_pid'" >&2
      return 1
      ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# Validate that name matches ^[a-z0-9_]+$
# ---------------------------------------------------------------------------
_validate_name() {
  _n="$1"
  # Reject empty string.
  [ -z "$_n" ] && { echo "app-ctl: name must match ^[a-z0-9_]+\$" >&2; return 1; }
  # Use grep for portable character-class matching (avoids locale hazards in case patterns).
  printf '%s' "$_n" | grep -qE '^[a-z0-9_]+$' \
    || { echo "app-ctl: name must match ^[a-z0-9_]+\$" >&2; return 1; }
  return 0
}

# ---------------------------------------------------------------------------
# Validate an IPv4/CIDR token
# ---------------------------------------------------------------------------
_validate_cidr_token() {
  _tok="$1"
  case "$_tok" in
    [0-9]*.[0-9]*.[0-9]*.[0-9]*/[0-9]*) return 0 ;;
    [0-9]*.[0-9]*.[0-9]*.[0-9]*)        return 0 ;;
  esac
  echo "app-ctl: invalid CIDR '$_tok' (expected dotted-quad[/len])" >&2
  return 1
}

# ---------------------------------------------------------------------------
# _cmd_list — emit JSON array of all force_source sections
# ---------------------------------------------------------------------------
_cmd_list() {
  mkdir -p "$FORCE_DIR/force.d"
  # Enumerate force_source sections from UCI; TYPE line is unquoted in uci show.
  _sources=$(uci show amnezia 2>/dev/null | grep '=force_source$' | \
    sed 's/amnezia\.\([^=]*\)=force_source/\1/')
  printf '['
  _first=1
  for _n in $_sources; do
    _enabled=$(uci -q get "amnezia.${_n}.enabled" 2>/dev/null || echo "0")
    _kind=$(uci -q get "amnezia.${_n}.kind"    2>/dev/null || echo "cidr")
    _title=$(uci -q get "amnezia.${_n}.title"   2>/dev/null || echo "$_n")
    _url=$(uci -q get "amnezia.${_n}.url"      2>/dev/null || echo "")
    _asn=$(uci -q get "amnezia.${_n}.asn"      2>/dev/null || echo "")

    _list="$FORCE_DIR/force.d/${_n}.list"
    _count=$(awk 'END{print NR}' "$_list" 2>/dev/null || echo 0)

    # Build detail string.
    case "$_kind" in
      static) _detail="inline" ;;
      as)     _detail="AS${_asn}" ;;
      *)      _detail="$_url" ;;
    esac

    if [ "$_first" = 1 ]; then _first=0; else printf ','; fi
    # JSON-encode title and detail (minimal: escape backslash and double-quote).
    _jtitle=$(printf '%s' "$_title"  | sed 's/\\/\\\\/g; s/"/\\"/g')
    _jdetail=$(printf '%s' "$_detail" | sed 's/\\/\\\\/g; s/"/\\"/g')
    printf '{"name":"%s","title":"%s","kind":"%s","enabled":%s,"count":%s,"detail":"%s"}' \
      "$_n" "$_jtitle" "$_kind" "$_enabled" "$_count" "$_jdetail"
  done
  printf ']\n'
}

# ---------------------------------------------------------------------------
# _cmd_add <name> <title> <method> <data>
# ---------------------------------------------------------------------------
_cmd_add() {
  _name="$1"; _title="$2"; _method="$3"; _data="$4"

  _validate_name "$_name" || return 1

  # Reject if section already exists.
  _existing=$(uci -q get "amnezia.${_name}" 2>/dev/null || echo "")
  if [ -n "$_existing" ]; then
    echo "app-ctl: section '${_name}' already exists" >&2
    return 1
  fi

  case "$_method" in
    # -----------------------------------------------------------------
    static)
      # Validate every token is IPv4/CIDR.
      # Accept whitespace, comma, newline as separators.
      _norm=$(printf '%s' "$_data" | tr ',' ' ' | tr '\n' ' ')
      for _tok in $_norm; do
        _validate_cidr_token "$_tok" || return 1
      done
      uci set "amnezia.${_name}=force_source"
      uci set "amnezia.${_name}.kind=static"
      uci set "amnezia.${_name}.title=${_title}"
      uci set "amnezia.${_name}.enabled=1"
      for _tok in $_norm; do
        uci add_list "amnezia.${_name}.cidr=${_tok}"
      done
      uci commit amnezia
      ;;
    # -----------------------------------------------------------------
    as)
      # Strip optional "AS" prefix; validate digits only.
      _asn=$(printf '%s' "$_data" | sed 's/^[Aa][Ss]//')
      case "$_asn" in
        ''|*[!0-9]*) echo "app-ctl: invalid ASN '${_data}'" >&2; return 1 ;;
      esac
      uci set "amnezia.${_name}=force_source"
      uci set "amnezia.${_name}.kind=as"
      uci set "amnezia.${_name}.asn=${_asn}"
      uci set "amnezia.${_name}.title=${_title}"
      uci set "amnezia.${_name}.enabled=1"
      uci commit amnezia
      ;;
    # -----------------------------------------------------------------
    url)
      case "$_data" in
        http://*|https://*) ;;
        *) echo "app-ctl: data must be http(s) URL for method=url" >&2; return 1 ;;
      esac
      uci set "amnezia.${_name}=force_source"
      uci set "amnezia.${_name}.kind=cidr"
      uci set "amnezia.${_name}.url=${_data}"
      uci set "amnezia.${_name}.title=${_title}"
      uci set "amnezia.${_name}.enabled=1"
      uci commit amnezia
      ;;
    # -----------------------------------------------------------------
    preset)
      if ! _preset_expand "$_data"; then
        return 1
      fi
      # Recurse with expanded method — but keep the caller-supplied name/title.
      # Use the preset title only if caller passed no title (empty string).
      _use_title="$_title"
      [ -z "$_use_title" ] && _use_title="$PRESET_TITLE"
      _cmd_add "$_name" "$_use_title" "$PRESET_METHOD" "$PRESET_DATA" || return 1
      # Return early — the recursive call already committed + ran force-update.
      return 0
      ;;
    # -----------------------------------------------------------------
    *)
      echo "app-ctl: unknown method '$_method' (use static|as|url|preset)" >&2
      return 1
      ;;
  esac

  # Materialize list + reload force4.
  ${AMNEZIA_FORCE_UPDATE:-amnezia-force-update}
}

# ---------------------------------------------------------------------------
# _cmd_remove <name>
# ---------------------------------------------------------------------------
_cmd_remove() {
  _name="$1"
  _validate_name "$_name" || return 1
  _existing=$(uci -q get "amnezia.${_name}" 2>/dev/null || echo "")
  if [ -z "$_existing" ]; then
    echo "app-ctl: section '${_name}' does not exist" >&2
    return 1
  fi
  uci -q delete "amnezia.${_name}" || true
  uci commit amnezia
  rm -f "$FORCE_DIR/force.d/${_name}.list"
  ${AMNEZIA_FORCE_LOAD:-amnezia-force-load}
}

# ---------------------------------------------------------------------------
# _cmd_enable / _cmd_disable <name>
# ---------------------------------------------------------------------------
_cmd_enable() {
  _name="$1"
  _validate_name "$_name" || return 1
  _existing=$(uci -q get "amnezia.${_name}" 2>/dev/null || echo "")
  if [ -z "$_existing" ]; then
    echo "app-ctl: section '${_name}' does not exist" >&2
    return 1
  fi
  uci set "amnezia.${_name}.enabled=1"
  uci commit amnezia
  # Run force-update to materialize a never-fetched list (as/url kinds).
  ${AMNEZIA_FORCE_UPDATE:-amnezia-force-update}
}

_cmd_disable() {
  _name="$1"
  _validate_name "$_name" || return 1
  _existing=$(uci -q get "amnezia.${_name}" 2>/dev/null || echo "")
  if [ -z "$_existing" ]; then
    echo "app-ctl: section '${_name}' does not exist" >&2
    return 1
  fi
  uci set "amnezia.${_name}.enabled=0"
  uci commit amnezia
  ${AMNEZIA_FORCE_LOAD:-amnezia-force-load}
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
case "${1:-}" in
  list)
    _cmd_list
    ;;
  add)
    [ $# -ge 5 ] || { echo "Usage: $0 add <name> <title> <method> <data>" >&2; exit 1; }
    _cmd_add "$2" "$3" "$4" "$5" || exit 1
    ;;
  remove)
    [ $# -ge 2 ] || { echo "Usage: $0 remove <name>" >&2; exit 1; }
    _cmd_remove "$2" || exit 1
    ;;
  enable)
    [ $# -ge 2 ] || { echo "Usage: $0 enable <name>" >&2; exit 1; }
    _cmd_enable "$2" || exit 1
    ;;
  disable)
    [ $# -ge 2 ] || { echo "Usage: $0 disable <name>" >&2; exit 1; }
    _cmd_disable "$2" || exit 1
    ;;
  preset)
    case "${2:-}" in
      list) echo "$PRESET_IDS" ;;
      *) echo "Usage: $0 preset list" >&2; exit 1 ;;
    esac
    ;;
  *)
    echo "Usage: $0 {list|add <name> <title> <method> <data>|remove <name>|enable <name>|disable <name>|preset list}" >&2
    exit 1
    ;;
esac
