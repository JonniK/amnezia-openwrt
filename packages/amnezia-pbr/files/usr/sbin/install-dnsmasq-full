#!/bin/sh
# Safe dnsmasq-full install: never remove dnsmasq until full package is installed.
set -eu
if opkg list-installed | grep -q '^dnsmasq-full '; then
	exit 0
fi
opkg update >/dev/null 2>&1 || opkg update || exit 1
opkg list | grep -q '^dnsmasq-full ' || {
	echo "NOTE: dnsmasq-full not in opkg lists — .ru nftset skipped." >&2
	exit 0
}
if opkg list-installed | grep -q '^dnsmasq '; then
	opkg install dnsmasq-full || exit 1
	opkg list-installed | grep -q '^dnsmasq-full ' && opkg remove dnsmasq 2>/dev/null || true
else
	opkg install dnsmasq-full || exit 1
fi
