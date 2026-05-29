#!/bin/sh
# pbr-status: emit JSON describing the health of the pbr service for the
# LuCI Amnezia view. Health is a single boolean derived from three signals.
#
# Fields:
#   running          /etc/init.d/pbr running exit 0
#   nft_ok           nft -c -f /var/run/pbr.nft exit 0 (set/rule syntax is sane)
#   ipdeny_count     entries in pbr_wan_4_dst_ip_user (should be 3000-7000 if
#                    the RU list has been populated)
#   recent_failure   "pbr ... FAILED TO START" present in last 200 logread lines.
#                    Purely informational -- it tracks the log, not live state,
#                    and will linger until the line rolls off the ring buffer.
#   healthy          true iff running && nft_ok. recent_failure is reported
#                    separately so the UI can surface it without flipping the
#                    health colour; the actual rule-installation outcome is
#                    captured by nft_ok, which is what really matters.
#                    (ipdeny_count is reported but not part of healthy: a clean
#                    first boot before the first awg-ru-update legitimately
#                    has 0 entries.)

NFTFILE=/var/run/pbr.nft
SETNAME=pbr_wan_4_dst_ip_user

running=false
if [ -x /etc/init.d/pbr ] && /etc/init.d/pbr running 2>/dev/null; then
	running=true
fi

nft_ok=false
nft_error=""
if [ -f "$NFTFILE" ]; then
	# Single-pass check so nft_error always matches the captured nft_ok status
	# (running nft twice can race against pbr rewriting /var/run/pbr.nft).
	_nft_out=$(nft -c -f "$NFTFILE" 2>&1)
	if [ $? -eq 0 ]; then
		nft_ok=true
	else
		nft_error=$(printf '%s' "$_nft_out" | head -n1 | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\n\r\t')
	fi
fi

ipdeny_count=0
if nft list set inet fw4 "$SETNAME" >/dev/null 2>&1; then
	# Count actual IPv4 CIDR elements. `grep -c /` would count wrapped output
	# lines (nft renders large sets across many lines with several elements
	# each), giving a misleading number that's neither the element count nor
	# proportional to it.
	ipdeny_count=$(nft list set inet fw4 "$SETNAME" 2>/dev/null \
		| grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' \
		| wc -l)
	ipdeny_count=$(printf '%s' "$ipdeny_count" | tr -d ' ')
fi

recent_failure=false
if logread 2>/dev/null | tail -n 200 | grep -q "pbr.*FAILED TO START"; then
	recent_failure=true
fi

healthy=false
if [ "$running" = true ] && [ "$nft_ok" = true ]; then
	healthy=true
fi

cat <<JSON
{
	"healthy": $healthy,
	"running": $running,
	"nft_ok": $nft_ok,
	"nft_error": "$nft_error",
	"ipdeny_count": $ipdeny_count,
	"recent_failure": $recent_failure
}
JSON
