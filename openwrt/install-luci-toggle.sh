#!/bin/sh
# Install LuCI Custom Commands buttons for AmneziaWG toggle/status.
# Idempotent: re-running updates the script and re-registers commands cleanly.
#
# Expects /tmp/awg-toggle.sh to be uploaded by the deploy script.
set -eu

SRC="${SRC:-/tmp/awg-toggle.sh}"
DST=/usr/bin/awg-toggle
STATUS=/usr/bin/awg-status

[ -f "$SRC" ] || { echo "missing $SRC"; exit 1; }
cp "$SRC" "$DST"
chmod 0755 "$DST"

cat > "$STATUS" <<'STATUS_EOF'
#!/bin/sh
echo "=== awg1 ==="
ifstatus awg1 2>/dev/null | grep -E '"up"|l3_device|"uptime"' || echo "interface missing"
echo
echo "=== pbr ==="
/etc/init.d/pbr status 2>/dev/null | head -5
echo
echo "=== pbr.nft ==="
[ -f /var/run/pbr.nft ] && nft -c -f /var/run/pbr.nft 2>/dev/null && echo "OK" || echo "missing/bad"
STATUS_EOF
chmod 0755 "$STATUS"

if ! opkg list-installed | grep -q '^luci-app-commands '; then
	opkg update >/dev/null 2>&1 || opkg update || exit 1
	opkg install luci-app-commands || exit 1
fi

# Drop any prior Amnezia commands so re-runs don't accumulate duplicates.
# Collect matching indices first, then delete from highest to lowest so earlier
# indices stay valid during deletion (avoids any reindexing-order assumptions).
_to_delete=""
idx=0
while uci -q get "luci.@command[$idx]" >/dev/null 2>&1; do
	name="$(uci -q get "luci.@command[$idx].name" || true)"
	case "$name" in
		"Amnezia: Toggle"|"Amnezia: Status")
			_to_delete="$idx $_to_delete"
			;;
	esac
	idx=$((idx + 1))
done
for i in $_to_delete; do
	uci -q delete "luci.@command[$i]"
done

uci add luci command >/dev/null
uci set luci.@command[-1].name='Amnezia: Toggle'
uci set luci.@command[-1].command="$DST"
uci set luci.@command[-1].public='0'

uci add luci command >/dev/null
uci set luci.@command[-1].name='Amnezia: Status'
uci set luci.@command[-1].command="$STATUS"
uci set luci.@command[-1].public='0'

uci commit luci

echo "luci-toggle: installed (System -> Custom Commands)"
