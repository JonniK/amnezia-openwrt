#!/bin/sh
# Toggle AmneziaWG (awg1). Installed as /usr/bin/awg-toggle, invoked from
# the LuCI Amnezia view.
#
# We deliberately do NOT touch /etc/init.d/pbr here. pbr 1.2.2 monitors awg1
# via interface triggers and reconfigures routes on its own when the iface
# goes up/down. Calling `pbr stop`+`pbr start` around ifup/ifdown leaves fw4
# in a half-built state -- the next `pbr start` then fails with
# "Installing fw4 nft file [✗]" and the ipdeny set stays empty until a
# manual `pbr reload`. If pbr is somehow already broken, the LuCI Tunnel
# panel exposes a separate "Reload PBR" button.
set -u
IFACE=awg1

is_up() {
	ifstatus "$IFACE" 2>/dev/null | jsonfilter -e '@.up' 2>/dev/null | grep -q true
}

if is_up; then
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
		echo "AmneziaWG: ON"
	else
		echo "AmneziaWG: FAILED to come up (peer unreachable? check /etc/config/network)"
	fi
fi

echo "---"
_up="$(ifstatus "$IFACE" 2>/dev/null | jsonfilter -e '@.up' 2>/dev/null || true)"
echo "awg1 up: ${_up:-n/a}"
_pbr="$(/etc/init.d/pbr status 2>/dev/null | head -1 || true)"
echo "pbr: ${_pbr:-n/a}"
