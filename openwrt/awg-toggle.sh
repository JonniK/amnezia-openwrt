#!/bin/sh
# Toggle AmneziaWG (awg1) + PBR together.
# Installed as /usr/bin/awg-toggle; invoked from LuCI Custom Commands.
set -u
IFACE=awg1

is_up() {
	ifstatus "$IFACE" 2>/dev/null | jsonfilter -e '@.up' 2>/dev/null | grep -q true
}

if is_up; then
	/etc/init.d/pbr stop 2>/dev/null || true
	ifdown "$IFACE" 2>/dev/null || true
	echo "AmneziaWG: OFF"
else
	ifup "$IFACE" 2>/dev/null || true
	_i=0
	while [ "$_i" -lt 8 ]; do
		is_up && break
		_i=$((_i + 1))
		sleep 1
	done
	if is_up; then
		/etc/init.d/pbr start 2>/dev/null || true
		echo "AmneziaWG: ON"
	else
		# Tunnel failed to come up: ensure PBR is stopped so LAN falls back to direct WAN
		# (otherwise stale pbr rules targeting dead awg1 would blackhole traffic).
		/etc/init.d/pbr stop 2>/dev/null || true
		echo "AmneziaWG: FAILED to come up (peer unreachable? check /etc/config/network)"
		echo "PBR stopped; traffic falls back to direct WAN."
	fi
fi

echo "---"
_up="$(ifstatus "$IFACE" 2>/dev/null | jsonfilter -e '@.up' 2>/dev/null || true)"
echo "awg1 up: ${_up:-n/a}"
_pbr="$(/etc/init.d/pbr status 2>/dev/null | head -1 || true)"
echo "pbr: ${_pbr:-n/a}"
