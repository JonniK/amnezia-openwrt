#!/bin/sh
# zapret-verify: run zapret-probe across a comma-separated list of domains and
# emit a single JSON `{results: [...]}` so the LuCI Amnezia view can render a
# table with one round-trip.
#
# Use case: after Apply ★ recommended, click "Verify" -- confirm the chosen
# nfqws strategy actually covers the user's common targets. Verdicts:
#   direct_ok          -> strategy works for this site (or site isn't blocked).
#   direct_dpi_blocked -> strategy didn't cover this domain; re-tune blockcheck.
#   direct_geoblocked  -> server refuses our IP; must-tunnel candidate, no DPI
#                         tweak will help.
#
# Sequential by design: parallel curls under DPI/QoS on a small router can mask
# strategy effectiveness (one stream's pacing affects another's RST timing).
# Correctness over speed -- ~5-10s per domain.
set -u

raw=${1:-}
[ -n "$raw" ] || { echo '{"error":"no domains given"}'; exit 2; }

# Split on commas (and surrounding whitespace).
list=$(printf '%s' "$raw" | tr ',' ' ')

json_escape() {
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\n\r\t'
}

# Hand-write an error record so consumers always get {domain, verdict, reason}
# whether validation rejected the input or the probe crashed.
emit_error() {
	# args: domain reason
	printf '{"domain":"%s","verdict":"error","reason":"%s"}' \
		"$(json_escape "$1")" "$(json_escape "$2")"
}

started=0
printf '{"results":['
# Shell word-split on the space-delimited list collapses empty tokens from
# `a,,b` input automatically -- no need to guard for [ -z "$d" ] inside.
for d in $list; do
	# Mirror zapret-probe's validation so the UI gets one consistent error
	# vocabulary, regardless of whether we filtered or the probe did.
	bad=""
	case "$d" in *[!A-Za-z0-9._-]*) bad="invalid charset" ;; esac
	if [ -z "$bad" ]; then
		if [ ${#d} -lt 2 ] || [ ${#d} -gt 253 ]; then
			bad="length out of range"
		fi
	fi
	if [ -z "$bad" ]; then
		case "$d" in
			*[A-Za-z0-9]*) : ;;
			*) bad="no letter/digit" ;;
		esac
	fi

	[ "$started" -eq 0 ] || printf ','
	started=1

	if [ -n "$bad" ]; then
		emit_error "$d" "$bad"
		continue
	fi

	out=$(/usr/bin/zapret-probe "$d" 2>/dev/null)
	if [ -z "$out" ]; then
		emit_error "$d" "probe returned empty"
	else
		printf '%s' "$out"
	fi
done
printf ']}\n'
