#!/bin/sh
# ipdeny ru.zone -> pbr_wan_4_dst_ip_user (appended to pbr.nft; no flush/list)
TARGET_URL='https://www.ipdeny.com/ipblocks/data/countries/ru.zone'
TARGET_FILE='/var/pbr_ru.zone'
PERSIST_FILE='/etc/amnezia/ru.cidr'
TARGET_TABLE='inet fw4'
TARGET_INTERFACE='wan'
NFTSET="pbr_${TARGET_INTERFACE}_4_dst_ip_user"
BATCH=300
_ret=0

mkdir -p "${TARGET_FILE%/*}"
# Prefer the persistent copy maintained by /usr/bin/awg-ru-update.
# Fall back to a one-shot download only on first boot before any update has run.
if [ -s "$PERSIST_FILE" ]; then
	cp "$PERSIST_FILE" "$TARGET_FILE"
elif [ ! -s "$TARGET_FILE" ]; then
	wget -q -O "$TARGET_FILE" "$TARGET_URL" || return 1
fi
batch=""
count=0
while IFS= read -r cidr; do
	[ -z "$cidr" ] && continue
	case "$cidr" in \#*) continue ;; esac
	if [ -z "$batch" ]; then batch="$cidr"; else batch="$batch, $cidr"; fi
	count=$((count + 1))
	if [ "$count" -ge "$BATCH" ]; then
		nft "add element $TARGET_TABLE $NFTSET { $batch }" 2>/dev/null || _ret=1
		batch=""
		count=0
	fi
done < "$TARGET_FILE"
if [ -n "$batch" ]; then
	nft "add element $TARGET_TABLE $NFTSET { $batch }" 2>/dev/null || _ret=1
fi
return $_ret
