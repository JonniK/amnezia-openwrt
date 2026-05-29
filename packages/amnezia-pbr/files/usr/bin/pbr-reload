#!/bin/sh
# pbr-reload: kick the pbr service back into a healthy state.
#
# `pbr reload` re-runs the include scripts (/etc/pbr.d/*) against the live
# nft state -- this is how a stuck-empty ipdeny_count typically recovers
# (it's also what awg-ru-update calls implicitly after refreshing the
# CIDR file). If reload fails or pbr isn't running, fall back to a full
# restart. Both branches are non-fatal so the user gets a single button
# that "just works".
set -u

if ! [ -x /etc/init.d/pbr ]; then
	echo "pbr is not installed"
	exit 2
fi

if /etc/init.d/pbr reload >/dev/null 2>&1; then
	echo "pbr: reload OK"
	exit 0
fi

echo "pbr: reload failed, trying restart"
if /etc/init.d/pbr restart >/dev/null 2>&1; then
	# Give the new instance a beat before the LuCI view re-polls.
	sleep 2
	echo "pbr: restart OK"
	exit 0
fi

echo "pbr: restart also failed -- check logread"
exit 1
