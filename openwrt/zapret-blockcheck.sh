#!/bin/sh
# zapret-blockcheck: drive /opt/zapret/blockcheck.sh in the background and
# expose status/log/cancel to the LuCI Amnezia view.
#
# Subcommands:
#   start [domain]   begin a run (default domain: youtube.com); refuses if
#                    one is already running.
#   status           print JSON state (file path: /etc/awg/blockcheck.json).
#   log              tail the run log on stdout (last 200 lines).
#   cancel           SIGTERM the running blockcheck (grace 5s, then SIGKILL).
#
# blockcheck.sh modifies firewall rules and exercises NFQUEUE; only one run
# may be active. For most accurate results the user should turn zapret OFF
# in the LuCI view before clicking Run — this wrapper does NOT auto-stop it,
# to avoid surprising side effects.
set -u

PIDFILE=/var/run/zapret-blockcheck.pid
CANCELMARK=/var/run/zapret-blockcheck.cancel
LOGFILE=/tmp/zapret-blockcheck.log
STAMP=/etc/awg/blockcheck.json
LOCK=/var/lock/zapret-blockcheck.lock
SCRIPT=/opt/zapret/blockcheck.sh

mkdir -p /etc/awg /var/run /var/lock

is_running() {
	[ -f "$PIDFILE" ] || return 1
	_p=$(cat "$PIDFILE" 2>/dev/null)
	[ -n "$_p" ] && [ -d "/proc/$_p" ]
}

# Stamp is JSON written all at once via heredoc -- shell vars only, no log content.
write_stamp() {
	# args: status domain started_ts finished_ts message
	_log_size=0
	[ -f "$LOGFILE" ] && _log_size=$(wc -c < "$LOGFILE" 2>/dev/null || echo 0)
	cat > "$STAMP" <<JSON
{
	"status": "$1",
	"domain": "$2",
	"started_ts": $3,
	"finished_ts": $4,
	"log_size": $_log_size,
	"message": "$5"
}
JSON
}

stamp_string_field() {
	# args: field_name; emits the field value (string fields only, unquoted).
	grep -E "\"$1\"[[:space:]]*:" "$STAMP" 2>/dev/null \
		| head -n1 \
		| sed -E "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\\1/"
}

stamp_number_field() {
	# args: field_name; emits the numeric value (digits only).
	grep -E "\"$1\"[[:space:]]*:" "$STAMP" 2>/dev/null \
		| head -n1 \
		| sed -E "s/.*\"$1\"[[:space:]]*:[[:space:]]*([0-9]+).*/\\1/"
}

cmd=${1:-}
case "$cmd" in
	start)
		[ -x "$SCRIPT" ] || { echo "blockcheck.sh not found at $SCRIPT"; exit 2; }
		domain=${2:-youtube.com}
		# Refuse a second concurrent start (also serialises against a racing click).
		(
		flock -n 9 || { echo "blockcheck-start: another invocation is mid-launch"; exit 75; }
		if is_running; then
			echo "blockcheck is already running (pid $(cat "$PIDFILE"))"
			exit 1
		fi
		started=$(date +%s)
		: > "$LOGFILE"
		rm -f "$CANCELMARK"
		write_stamp "running" "$domain" "$started" 0 ""

		# Detached supervisor: forks blockcheck.sh, records its real pid, waits
		# for it, then writes a final stamp. Double-redirect so this subshell
		# doesn't keep the rpcd file descriptors open and hold up the response.
		(
			# Close inherited flock FD so the start lock is released as soon as
			# the outer subshell exits -- otherwise the lock is held for the
			# entire blockcheck run (10-30 min) and concurrent starts misreport
			# as flock contention instead of "already running".
			exec 9<&-
			DOMAINS="$domain" \
			IPVS=4 \
			ENABLE_HTTP=0 ENABLE_HTTPS_TLS12=1 ENABLE_HTTPS_TLS13=1 ENABLE_HTTP3=1 \
			REPEATS=1 PARALLEL=0 SCANLEVEL=standard \
			sh "$SCRIPT" >>"$LOGFILE" 2>&1 </dev/null &
			bc_pid=$!
			echo "$bc_pid" > "$PIDFILE"
			wait "$bc_pid"
			rc=$?
			finished=$(date +%s)
			rm -f "$PIDFILE"
			# A cancel sets CANCELMARK; trust that over the exit code, because
			# blockcheck.sh's SIGTERM trap may cleanly exit 0 after teardown
			# (and an rc 143/137 only fires if our SIGKILL fallback was needed).
			if [ -f "$CANCELMARK" ]; then
				rm -f "$CANCELMARK"
				write_stamp "cancelled" "$domain" "$started" "$finished" "user cancelled"
			else
				case "$rc" in
					0)        write_stamp "finished"  "$domain" "$started" "$finished" "exit 0" ;;
					143|137)  write_stamp "cancelled" "$domain" "$started" "$finished" "signal $rc" ;;
					*)        write_stamp "failed"    "$domain" "$started" "$finished" "exit $rc" ;;
				esac
			fi
		) </dev/null >/dev/null 2>&1 &

		# Wait briefly for the supervisor to publish the pid file before
		# releasing the start lock. Without this an immediate Cancel from the
		# UI could see no PIDFILE and report 'not running' while blockcheck.sh
		# is in fact about to start. We hold the lock while we spin, so
		# concurrent starts stay rejected.
		i=0
		while [ $i -lt 10 ]; do
			[ -f "$PIDFILE" ] && break
			i=$((i + 1))
			sleep 1
		done
		if [ -f "$PIDFILE" ]; then
			echo "blockcheck started for $domain (pid $(cat "$PIDFILE"))"
			exit 0
		else
			# Roll the stamp back so the UI doesn't sit on a phantom 'running'.
			write_stamp "failed" "$domain" "$started" "$(date +%s)" "supervisor did not publish pid within 10s"
			echo "blockcheck supervisor did not publish a pid within 10s"
			exit 1
		fi
		) 9>"$LOCK"
		exit $?
		;;
	status)
		if [ -f "$STAMP" ]; then
			# Reconcile: if the stamp claims 'running' but no supervisor exists
			# (e.g. /var/run was wiped by a reboot, or the supervisor was -9'd),
			# rewrite the stamp once as 'interrupted' so the UI doesn't get stuck.
			cur_status=$(stamp_string_field status)
			if [ "$cur_status" = "running" ] && ! is_running; then
				# Grace period: a concurrent `start` may have just written
				# the 'running' stamp before its supervisor created PIDFILE.
				# Only reconcile after the stamp is older than 5s -- that's
				# well past the start's spin-wait window.
				_st=$(stamp_number_field started_ts)
				_age=$(( $(date +%s) - ${_st:-0} ))
				if [ "$_age" -gt 5 ]; then
					_dom=$(stamp_string_field domain)
					write_stamp "interrupted" "${_dom:-}" "${_st:-0}" "$(date +%s)" "supervisor gone"
				fi
			fi
			# Recompute log_size on read so it reflects the current tail without
			# the supervisor having to rewrite the stamp on every byte.
			cur_size=0
			[ -f "$LOGFILE" ] && cur_size=$(wc -c < "$LOGFILE" 2>/dev/null || echo 0)
			sed -E "s/\"log_size\":[[:space:]]*[0-9]+/\"log_size\": $cur_size/" "$STAMP"
		else
			echo '{"status": "never_run", "domain": "", "started_ts": 0, "finished_ts": 0, "log_size": 0, "message": ""}'
		fi
		;;
	log)
		[ -f "$LOGFILE" ] && tail -n 200 "$LOGFILE" || echo "(no log yet)"
		;;
	cancel)
		if ! is_running; then
			echo "blockcheck is not running"
			exit 0
		fi
		p=$(cat "$PIDFILE" 2>/dev/null)
		[ -z "$p" ] && { echo "no pid"; exit 1; }
		# Mark intent so the supervisor classifies as 'cancelled' even if
		# blockcheck.sh's SIGTERM trap exits 0 after tearing down its nft table.
		touch "$CANCELMARK"
		echo "sending SIGTERM to pid $p"
		kill -TERM "$p" 2>/dev/null || true
		# Grace period for blockcheck's trap handlers to tear down nftables.
		for i in 1 2 3 4 5; do
			[ -d "/proc/$p" ] || break
			sleep 1
		done
		if [ -d "/proc/$p" ]; then
			echo "still alive after 5s, sending SIGKILL"
			kill -KILL "$p" 2>/dev/null || true
		fi
		# Supervisor subshell will pick up the wait result and rewrite the stamp.
		echo "cancel requested"
		;;
	*)
		echo "usage: zapret-blockcheck {start [domain]|status|log|cancel}"
		exit 2
		;;
esac
