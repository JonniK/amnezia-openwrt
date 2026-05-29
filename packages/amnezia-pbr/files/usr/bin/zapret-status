#!/bin/sh
# zapret-status: print current zapret state as JSON for the LuCI Amnezia view.
#
# Fields:
#   installed - 1 if zapret package present, else 0
#   enabled   - /etc/init.d/zapret enabled exit code == 0
#   running   - nfqws OR tpws process exists (MODE may use either or both)
#   pid       - first matching pid (0 if none)
#   mode      - MODE from /opt/zapret/config (e.g. nfqws / tpws / nfqws-tpws)
#   filter    - MODE_FILTER (none / hostlist / autohostlist / ipset)
#   strategy  - NFQWS_OPT, truncated for UI
#   version   - installed package version

CONFIG=/opt/zapret/config

# Treat the config as untrusted text -- never source it; grep + sed only.
get_var() {
	# args: VARNAME
	# Extract last assignment of the form: VAR=value or VAR="value with spaces".
	grep -E "^[[:space:]]*$1[[:space:]]*=" "$CONFIG" 2>/dev/null \
		| tail -n1 \
		| sed -E "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//; s/^\"(.*)\"$/\\1/; s/^'(.*)'$/\\1/"
}

json_escape() {
	# Escape for JSON string body: backslash, quote, control chars to space.
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\n\r\t'
}

# Single opkg list-installed call -- the LuCI poller hits this every 5s.
inst_line=$(opkg list-installed 2>/dev/null | awk '/^zapret /{print; exit}')
if [ -n "$inst_line" ]; then
	installed=1
	version=$(printf '%s' "$inst_line" | awk '{print $3}')
else
	installed=0
	version=""
fi

enabled=false
if [ "$installed" = "1" ] && /etc/init.d/zapret enabled 2>/dev/null; then
	enabled=true
fi

# Authoritative running check: ask procd via the init script. BusyBox `pgrep -x`
# matches the full cmdline (not comm), so `pgrep -x nfqws` won't match
# `/opt/zapret/nfq/nfqws ...`. We pgrep with -f as a sanity cross-check and to
# expose the actual pid.
running=false
if [ "$installed" = "1" ] && /etc/init.d/zapret running 2>/dev/null; then
	running=true
fi
pid=$(pgrep -f '/opt/zapret/nfq/nfqws ' 2>/dev/null | head -n1)
[ -z "$pid" ] && pid=$(pgrep -f '/opt/zapret/tpws/tpws ' 2>/dev/null | head -n1)
[ -z "$pid" ] && pid=0

# The remittor/zapret-openwrt packaging stores tunables in UCI
# (/etc/config/zapret) rather than as shell vars in /opt/zapret/config. We read
# UCI when present and fall back to the shell config so this works for both
# upstream-style and packaged installs.
mode=""
nfqws_enabled=$(uci -q get zapret.config.NFQWS_ENABLE 2>/dev/null || echo "")
tpws_enabled=$(uci -q get zapret.config.TPWS_ENABLE  2>/dev/null || echo "")
[ "$nfqws_enabled" = "1" ] && mode="nfqws"
[ "$tpws_enabled"  = "1" ] && mode="${mode:+$mode+}tpws"
if [ -z "$mode" ] && [ -r "$CONFIG" ]; then
	mode=$(get_var MODE)
fi

filter=$(uci -q get zapret.config.MODE_FILTER 2>/dev/null || echo "")
if [ -z "$filter" ] && [ -r "$CONFIG" ]; then
	filter=$(get_var MODE_FILTER)
fi

strategy=$(uci -q get zapret.config.NFQWS_OPT 2>/dev/null | tr '\n\t' '  ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')
if [ -z "$strategy" ] && [ -r "$CONFIG" ]; then
	strategy=$(get_var NFQWS_OPT)
fi
if [ ${#strategy} -gt 160 ]; then
	strategy=$(printf '%s' "$strategy" | cut -c1-157)...
fi

cat <<JSON
{
	"installed": $installed,
	"enabled": $enabled,
	"running": $running,
	"pid": $pid,
	"mode": "$(json_escape "$mode")",
	"filter": "$(json_escape "$filter")",
	"strategy": "$(json_escape "$strategy")",
	"version": "$(json_escape "$version")"
}
JSON
