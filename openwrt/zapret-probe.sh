#!/bin/sh
# zapret-probe: ask "if I went direct via WAN (no tunnel) to this domain, what
# would happen?". The LuCI Amnezia view uses this to tell the user whether a
# given site needs the AWG tunnel or can be handled directly (optionally with
# zapret DPI-desync).
#
# We don't probe via AWG because the router itself doesn't route through awg1
# (PBR only handles forwarded LAN traffic; local-origin curls always egress
# via WAN regardless of --interface). The interesting question anyway is
# "does direct work?" -- if yes, you have a choice; if no, the tunnel is the
# answer.
#
# Verdict:
#   direct_ok            HTTP 200 (or other 2xx/3xx), no geoblock signal.
#   direct_geoblocked    Got an answer but the server refused us by country.
#                        Signal: HTTP 451, or 403 with cf-mitigated, or body
#                        matching common "not available in your region" text.
#   direct_dpi_blocked   No TCP/TLS handshake completed and the failure was
#                        FAST (well under 10s) -- classic TSPU RST pattern.
#   direct_unreachable   Timed out or connection refused with no quick reset
#                        -- site might be down or our route to it broken.
#   error                Probe could not run (bad args, no curl, etc.).
set -u

domain=${1:-}
[ -n "$domain" ] || { echo '{"verdict":"error","reason":"no domain given"}'; exit 2; }
# Defensive validation: hostname chars only, length 2..253 (mirrors the JS-
# side regex so a CLI invocation can't slip through with a 1-char or all-dot
# input and produce a bogus https://./ request).
case "$domain" in
	*[!A-Za-z0-9._-]*) echo '{"verdict":"error","reason":"invalid domain"}'; exit 2 ;;
esac
if [ ${#domain} -lt 2 ] || [ ${#domain} -gt 253 ]; then
	echo '{"verdict":"error","reason":"domain length out of range"}'
	exit 2
fi
# Reject pathological inputs that pass the charset check but aren't real
# hostnames (only dots/underscores/hyphens, no letter or digit anywhere).
case "$domain" in
	*[A-Za-z0-9]*) : ;;
	*) echo '{"verdict":"error","reason":"domain has no letter/digit"}'; exit 2 ;;
esac

URL="https://$domain/"
CT=5     # connect timeout (seconds)
MAX=10   # total timeout

json_escape() {
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\n\r\t'
}

# First request: get status, timings, and headers. Body discarded.
# We bind to the wan interface explicitly so PBR can't redirect us via AWG
# even if local-origin routing rules ever change.
HDR_FILE=/tmp/zapret-probe-hdr.$$
out=$(curl --interface wan \
	--connect-timeout "$CT" --max-time "$MAX" \
	-sL -D "$HDR_FILE" -o /dev/null \
	-w '%{http_code}\t%{time_total}\t%{num_redirects}\n' \
	"$URL" 2>&1)
status=$(printf '%s' "$out" | awk -F'\t' '{print $1}')
time_total=$(printf '%s' "$out" | awk -F'\t' '{print $2}')
redirects=$(printf '%s' "$out" | awk -F'\t' '{print $3}')

# Defaults so the JSON heredoc never emits empty numerics. curl can exit
# before the writeout stage on bind failures, signals, OOM kills, etc., and
# the awk extraction then yields empty strings -- without these guards the
# emitted JSON would look like `"time_total": ,` and parseProbe() would
# silently fail with no clue why.
time_total=${time_total:-0}
redirects=${redirects:-0}
case "$time_total" in
	*[!0-9.]*) time_total=0 ;;
esac
case "$redirects" in
	*[!0-9]*) redirects=0 ;;
esac

# Numeric guards: curl emits "000" (three zeros) on connect failure. Normalise
# to a real integer so the verdict case below can match `0)` literally.
case "$status" in
	*[!0-9]*) status=0 ;;
	"")       status=0 ;;
	*)        status=$((status + 0)) ;;
esac

# Look for explicit geoblock signals in headers.
hdr_signal=""
if [ -f "$HDR_FILE" ]; then
	# Cloudflare geographic/legal mitigation marker.
	if grep -iq '^cf-mitigated:' "$HDR_FILE" 2>/dev/null; then
		hdr_signal="cf-mitigated header"
	fi
fi

# For 403/451 statuses, peek at the body for common "region not allowed" or
# "VPN detected" markers. We err on the side of false-positive geoblock --
# 403 from a top-level GET usually means "we don't serve you", whether
# country-based or VPN-detect-based; in both cases the practical fix is the
# same (route through a different exit).
body_signal=""
case "$status" in
	403|451|418|429|503)
		body=$(curl --interface wan \
			--connect-timeout "$CT" --max-time "$MAX" \
			-sL "$URL" 2>/dev/null | head -c 16384 | tr '[:upper:]' '[:lower:]')
		# Common phrases used by CDN / region-block / VPN-detect pages.
		# CF "Access denied", OpenAI "Country/region not supported", "VPN".
		# Tight phrases only -- a bare "vpn" substring would false-positive
		# on any privacy-policy or support page that mentions VPNs.
		if printf '%s' "$body" | grep -qE \
				'not available in your (region|country)|geographic|geo-?block|region-?block|unavailable for legal|451 unavailable|access denied|access is blocked|country.{0,12}not (supported|allowed)|using a vpn|vpn (or proxy|detected|service)|sorry, you have been blocked|cloudflare ray id'; then
			body_signal="body matches block phrase"
		fi
		;;
esac

# Compose verdict.
reason=""
case "$status" in
	2*|3*)
		verdict="direct_ok"
		reason="HTTP $status"
		;;
	451)
		verdict="direct_geoblocked"
		reason="HTTP 451 (Unavailable For Legal Reasons)"
		;;
	403)
		# Treat any 403 as "we got refused" -- it's almost never a useful
		# state for a top-level browser-style GET. If we found a header or
		# body marker the diagnosis is firmer; otherwise we still flag it
		# as blocked (probably geo or anti-VPN), just with weaker reason.
		verdict="direct_geoblocked"
		if [ -n "$hdr_signal" ] || [ -n "$body_signal" ]; then
			reason="HTTP 403 + ${hdr_signal:-$body_signal}"
		else
			reason="HTTP 403 (server refused us -- likely geo or anti-VPN; no explicit signal in headers/body)"
		fi
		;;
	418|429|503)
		# These often mean "you're being challenged/rate-limited as a bot",
		# which on a top-level GET is again practically a block from this IP.
		verdict="direct_geoblocked"
		reason="HTTP $status${hdr_signal:+ + $hdr_signal}${body_signal:+ + $body_signal}"
		;;
	0)
		# curl never got a status line. Use timing to tell DPI from outage.
		# TSPU/DPI typically RSTs in ~the round-trip; sub-2s with no answer
		# is the classic signature. A long timeout (>= connect-timeout)
		# means the SYN got eaten or the host is really unreachable.
		if printf '%s' "$time_total" | awk '{exit !($1 < 2.0)}'; then
			verdict="direct_dpi_blocked"
			reason="connection failed in ${time_total}s (likely DPI RST)"
		else
			verdict="direct_unreachable"
			reason="connect/handshake timed out after ${time_total}s"
		fi
		;;
	4*|5*)
		verdict="direct_blocked"
		reason="HTTP $status"
		;;
	*)
		verdict="direct_unreachable"
		reason="unexpected HTTP $status"
		;;
esac

# Recommendation derived from verdict.
case "$verdict" in
	direct_ok)           rec="Direct WAN works. Safe to leave off-tunnel; turning zapret on is optional." ;;
	direct_geoblocked)   rec="Server refused us (geo / anti-VPN). Route via AWG so the exit IP isn't ours -- zapret alone won't help." ;;
	direct_dpi_blocked)  rec="DPI/TSPU on the path. Try zapret first (cheap, no tunnel); if it still fails, route via AWG." ;;
	direct_blocked)      rec="Server returned an error response. Check the reason; tunnel may or may not help." ;;
	direct_unreachable)  rec="No response at all. May be a transient outage; try again later, or try via AWG to confirm." ;;
	*)                   rec="" ;;
esac

rm -f "$HDR_FILE"

cat <<JSON
{
	"domain": "$(json_escape "$domain")",
	"status": $status,
	"time_total": $time_total,
	"redirects": $redirects,
	"header_signal": "$(json_escape "$hdr_signal")",
	"body_signal": "$(json_escape "$body_signal")",
	"verdict": "$verdict",
	"reason": "$(json_escape "$reason")",
	"recommendation": "$(json_escape "$rec")"
}
JSON
