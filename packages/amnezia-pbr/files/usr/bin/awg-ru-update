#!/bin/sh
# awg-ru-update: refresh the RU IPv4 CIDR list used by PBR's ru-direct rule.
#
# Source priority:
#   1. https://raw.githubusercontent.com/herrbischoff/country-ip-blocks/master/ipv4/ru.cidr
#   2. https://www.ipdeny.com/ipblocks/data/countries/ru.zone
#   3. http://www.ipdeny.com/ipblocks/data/countries/ru.zone   (fallback)
#
# Writes:
#   /etc/amnezia/ru.cidr           - persistent canonical copy (survives reboot)
#   /var/pbr_ru.zone           - working copy read by /etc/pbr.d/ru-direct.sh
#   /etc/amnezia/ru-update.json    - stamp: {ts, count, source, status, message}
#
# If the new list differs from the previous, triggers `pbr reload` so the
# nft set is repopulated from the fresh file. Otherwise leaves PBR alone.
set -u

STAMP=/etc/amnezia/ru-update.json
PERSIST=/etc/amnezia/ru.cidr
WORK=/var/pbr_ru.zone
TMP=/tmp/awg-ru.new.$$
MIN_LINES=1000   # sanity: RU has ~6500 CIDRs; anything under 1000 is suspicious

SRC_GITHUB='https://raw.githubusercontent.com/herrbischoff/country-ip-blocks/master/ipv4/ru.cidr'
SRC_IPDENY_HTTPS='https://www.ipdeny.com/ipblocks/data/countries/ru.zone'
SRC_IPDENY_HTTP='http://www.ipdeny.com/ipblocks/data/countries/ru.zone'

mkdir -p /etc/awg /var/lock

now_ts() { date +%s; }

write_stamp() {
	# args: status source count message
	cat > "$STAMP" <<JSON
{
	"ts": $(now_ts),
	"iso": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
	"status": "$1",
	"source": "$2",
	"count": $3,
	"message": "$4"
}
JSON
}

# fetch URL -> $TMP. Returns 0 on plausible success (file exists, non-empty,
# enough lines, all lines look like CIDR).
fetch() {
	_url="$1"
	rm -f "$TMP"
	# wget on OpenWrt with libustream-mbedtls handles HTTPS; -T 20 = 20s timeout.
	wget -q -T 20 -O "$TMP" "$_url" || return 1
	[ -s "$TMP" ] || return 1
	_lines=$(grep -c '^[0-9]' "$TMP" 2>/dev/null || echo 0)
	[ "$_lines" -ge "$MIN_LINES" ] || return 1
	# Reject if any non-blank, non-comment line doesn't look like CIDR.
	awk 'NF && $1 !~ /^#/ && $1 !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+$/ { exit 1 }' "$TMP" || return 1
	return 0
}

# Serialize cron and user-triggered runs so they don't race on the final
# mv/cp/pbr-reload sequence. Held via FD 9 in the subshell below; lockfile
# stays around but the lock is released when this process exits.
LOCK=/var/lock/awg-ru-update.lock

(
flock -n 9 || {
	echo "awg-ru-update: another run is already in progress"
	exit 0
}

SOURCE=""
for _try in "github:$SRC_GITHUB" "ipdeny-https:$SRC_IPDENY_HTTPS" "ipdeny-http:$SRC_IPDENY_HTTP"; do
	_name="${_try%%:*}"
	_url="${_try#*:}"
	if fetch "$_url"; then
		SOURCE="$_name"
		break
	fi
done

if [ -z "$SOURCE" ]; then
	write_stamp "failed" "none" 0 "all sources unreachable or invalid"
	rm -f "$TMP"
	echo "awg-ru-update: FAILED (all sources unreachable)"
	exit 1
fi

NEW_COUNT=$(grep -c '^[0-9]' "$TMP" 2>/dev/null || echo 0)
NEW_MD5=$(md5sum "$TMP" | awk '{print $1}')
OLD_MD5=""
[ -f "$PERSIST" ] && OLD_MD5=$(md5sum "$PERSIST" | awk '{print $1}')

if [ "$NEW_MD5" = "$OLD_MD5" ] && [ -n "$OLD_MD5" ]; then
	write_stamp "unchanged" "$SOURCE" "$NEW_COUNT" "list unchanged (md5 match)"
	rm -f "$TMP"
	echo "awg-ru-update: unchanged ($NEW_COUNT CIDRs from $SOURCE)"
	exit 0
fi

# Install: persistent first (atomic via mv on same fs), then working copy.
mv "$TMP" "$PERSIST"
cp "$PERSIST" "$WORK"

# Trigger pbr to repopulate the nft set from the updated file.
# `reload` is lighter than `restart`; falls back if reload isn't supported.
if /etc/init.d/pbr reload >/dev/null 2>&1; then
	_msg="updated and pbr reloaded"
elif /etc/init.d/pbr restart >/dev/null 2>&1; then
	_msg="updated and pbr restarted (reload failed)"
else
	_msg="updated but pbr reload/restart failed"
fi

write_stamp "updated" "$SOURCE" "$NEW_COUNT" "$_msg"
echo "awg-ru-update: $_msg ($NEW_COUNT CIDRs from $SOURCE)"

) 9>"$LOCK"
exit $?
