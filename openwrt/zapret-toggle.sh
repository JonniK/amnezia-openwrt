#!/bin/sh
# zapret-toggle: flip the zapret service on/off.
#
# Behaviour:
#   - if enabled  -> /etc/init.d/zapret stop && disable
#   - if disabled -> /etc/init.d/zapret enable && start
# Reports a short human line on stdout and the new state (running yes/no).
# Serialised via flock so concurrent web clicks don't race.
set -u

LOCK=/var/lock/zapret-toggle.lock
mkdir -p /var/lock

if ! command -v /etc/init.d/zapret >/dev/null 2>&1 && [ ! -x /etc/init.d/zapret ]; then
	echo "zapret is not installed"
	exit 2
fi

(
flock -n 9 || {
	echo "zapret-toggle: another toggle is already in progress"
	exit 75
}

if /etc/init.d/zapret enabled 2>/dev/null; then
	echo "zapret: stopping and disabling"
	/etc/init.d/zapret stop    >/dev/null 2>&1
	/etc/init.d/zapret disable >/dev/null 2>&1
	new_state="disabled"
else
	echo "zapret: enabling and starting"
	/etc/init.d/zapret enable  >/dev/null 2>&1
	/etc/init.d/zapret start   >/dev/null 2>&1
	new_state="enabled"
fi

# Worker may take a couple seconds to fork+exec via procd. Poll the init script
# (authoritative -- BusyBox pgrep -x mis-matches absolute-path daemons).
i=0
while [ $i -lt 4 ]; do
	if /etc/init.d/zapret running >/dev/null 2>&1; then
		break
	fi
	i=$((i + 1))
	sleep 1
done
if /etc/init.d/zapret running >/dev/null 2>&1; then
	echo "zapret: $new_state (worker running)"
else
	echo "zapret: $new_state (worker $( [ "$new_state" = "enabled" ] && echo "did not start" || echo "not running" ))"
fi

) 9>"$LOCK"
exit $?
