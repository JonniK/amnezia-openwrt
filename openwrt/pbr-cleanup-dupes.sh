#!/bin/sh
# One-shot cleanup of duplicate PBR prerouting rules (run outside pbr.d includes).
set -eu
_pbr_trim_comment() {
	_c="$1"
	while :; do
		_n=$(nft -a list chain inet fw4 pbr_prerouting 2>/dev/null | grep -c "comment \"$_c\"" || true)
		_n=${_n:-0}
		[ "$_n" -le 1 ] && break
		_h=$(nft -a list chain inet fw4 pbr_prerouting 2>/dev/null | grep "comment \"$_c\"" | awk '{print $NF}' | tail -1)
		[ -n "$_h" ] || break
		nft delete rule inet fw4 pbr_prerouting handle "$_h" 2>/dev/null || break
	done
}
_pbr_trim_comment "ru_tld_dns_skip"
_pbr_trim_comment "ru_direct_skip"
_pbr_trim_comment "lan_via_vpn"
