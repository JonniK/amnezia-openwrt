#!/bin/sh
# ipdeny ru.zone -> pbr_wan_4_dst_ip_user (appended to pbr.nft; no flush/list)
TARGET_URL='https://www.ipdeny.com/ipblocks/data/countries/ru.zone'
TARGET_FILE='/var/pbr_ru.zone'
TARGET_TABLE='inet fw4'
TARGET_INTERFACE='wan'
NFTSET="pbr_${TARGET_INTERFACE}_4_dst_ip_user"
BATCH=300
_ret=0

mkdir -p "${TARGET_FILE%/*}"
[ -s "$TARGET_FILE" ] || wget -q -O "$TARGET_FILE" "$TARGET_URL" || return 1
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
[ -n "$batch" ] && nft "add element $TARGET_TABLE $NFTSET { $batch }" 2>/dev/null || _ret=1
return $_ret
