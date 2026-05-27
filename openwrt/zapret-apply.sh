#!/bin/sh
# zapret-apply: parse blockcheck log, apply a chosen strategy to UCI
# NFQWS_OPT, manage backups, and revert when needed.
#
# Subcommands:
#   parse                  emit one JSON object per line for every "working
#                          strategy" line found in the current blockcheck log
#                          (deduplicated).
#   apply <strategy>       back up the current NFQWS_OPT, write <strategy>,
#                          uci commit, restart zapret if enabled. The argument
#                          is the FULL nfqws option string (the right-hand
#                          side of the "found ... :" portion of a log line).
#   revert                 restore NFQWS_OPT from the latest backup.
#   state                  emit JSON with has_backup, backup_ts (filename ts),
#                          candidates count, current NFQWS_OPT (single-line).
set -u

LOGFILE=/tmp/zapret-blockcheck.log
BACKUP_DIR=/etc/awg/zapret-backups
LATEST="$BACKUP_DIR/NFQWS_OPT.latest"
UCI_KEY=zapret.config.NFQWS_OPT

mkdir -p "$BACKUP_DIR"

json_escape() {
	# Escape for JSON string body.
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\n\r\t'
}

# Squeeze multi-line / multi-space NFQWS_OPT into a single-line readable form.
flatten_opt() {
	printf '%s' "$1" | tr '\n\t' '  ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
}

reload_if_enabled() {
	if [ -x /etc/init.d/zapret ] && /etc/init.d/zapret enabled 2>/dev/null; then
		/etc/init.d/zapret restart >/dev/null 2>&1 || return 1
	fi
	return 0
}

cmd=${1:-}
case "$cmd" in
	parse)
		[ -f "$LOGFILE" ] || { exit 0; }
		# Upstream log format (blockcheck.sh L1243):
		#   !!!!! <TEST>: working strategy found for ipv<N> <DOMAIN> : <TOOL> <STRATEGY> !!!!!
		# Example:
		#   !!!!! curl_test_https_tls13: working strategy found for ipv4 youtube.com : nfqws --dpi-desync=multidisorder --dpi-desync-split-pos=2 !!!!!
		#
		# After the run completes, blockcheck also emits a clean SUMMARY block:
		#   <TEST> ipv<N> <DOMAIN> : <TOOL> <STRATEGY>
		# We harvest both -- the live !!!!! markers give early visibility AND
		# log-emit order, the SUMMARY catches anything that didn't make it to
		# a marker. The merge is dedup'd by content.
		#
		# Recommended-flag heuristic: blockcheck tests strategies in a built-in
		# priority order (simpler/more reliable first) and emits a !!!!! marker
		# the first time something in a given (scope, ipv, domain) class works.
		# So the FIRST !!!!! marker for each class is the candidate blockcheck
		# itself considered best; we mark it recommended=true. Later working
		# strategies for the same class get recommended=false. SUMMARY-only
		# entries (no !!!!! marker, shouldn't happen but defend) get false.
		#
		# Filter to tool=nfqws -- tpws strategies use a different flag set and
		# would corrupt NFQWS_OPT. Strategy text in practice is ASCII without
		# quotes or backslashes, but we json-escape defensively.
		{
			sed -nE 's/^!!!!! ([^:]+): working strategy found for ipv([0-9]+) ([^ ]+) : nfqws (.*) !!!!!$/M\t\1\t\2\t\3\t\4/p' "$LOGFILE"
			awk '/^\* SUMMARY/,/^Please note this SUMMARY/' "$LOGFILE" 2>/dev/null \
				| sed -nE 's/^([^ ]+) ipv([0-9]+) ([^ ]+) : nfqws (.*)$/S\t\1\t\2\t\3\t\4/p'
		} | awk -F'\t' '
			{
				# $1=M|S (marker or summary), $2=scope, $3=ipv, $4=domain, $5=strategy
				key = $2 "|" $3 "|" $4 "|" $5
				if (seen[key]) next
				seen[key] = 1
				class_key = $2 "|" $3 "|" $4
				if ($1 == "M" && !seen_class[class_key]) {
					rec = "true"; seen_class[class_key] = 1
				} else {
					rec = "false"
				}
				# JSON-escape every string field defensively (backslash + ").
				# In practice blockcheck emits ASCII test names and DNS names,
				# but a future log format change could leak a quote and quietly
				# drop the line on the front-end (parseCandidates skips bad JSON).
				strat = $5
				scope = $2
				domain = $4
				gsub(/\\/, "\\\\", strat); gsub(/"/, "\\\"", strat)
				gsub(/\\/, "\\\\", scope); gsub(/"/, "\\\"", scope)
				gsub(/\\/, "\\\\", domain); gsub(/"/, "\\\"", domain)
				printf "{\"tool\":\"nfqws\",\"ipv\":%s,\"scope\":\"%s\",\"domain\":\"%s\",\"strategy\":\"%s\",\"recommended\":%s}\n", \
					$3, scope, domain, strat, rec
			}
		'
		;;

	apply)
		newopt=${2:-}
		[ -n "$newopt" ] || { echo "usage: zapret-apply apply <strategy>"; exit 2; }
		if ! command -v uci >/dev/null 2>&1; then
			echo "uci not available"; exit 1
		fi
		current=$(uci -q get "$UCI_KEY" 2>/dev/null || echo "")
		# No-op if the value is already what the user is trying to apply --
		# saves a jffs2 write cycle and avoids a needless zapret restart.
		if [ "$newopt" = "$current" ]; then
			echo "already applied (no change)"
			exit 0
		fi
		ts=$(date +%Y%m%d-%H%M%S)
		bak="$BACKUP_DIR/NFQWS_OPT.$ts.bak"
		# Atomic backup write: tmp + mv.
		printf '%s\n' "$current" > "$bak.tmp" && mv "$bak.tmp" "$bak"
		ln -sf "$bak" "$LATEST"
		# Trim backup history to the last 10 entries so the dir doesn't grow
		# unbounded on jffs2. The .latest symlink (revert target) is preserved
		# by name -- we only delete plain .bak / .bak.reverted older than 10.
		ls -1t "$BACKUP_DIR"/NFQWS_OPT.*.bak "$BACKUP_DIR"/NFQWS_OPT.*.bak.reverted 2>/dev/null \
			| tail -n +11 | while read -r _f; do rm -f "$_f"; done

		# Commit new value.
		uci set "$UCI_KEY=$newopt" || { echo "uci set failed"; exit 1; }
		uci commit zapret || { echo "uci commit failed"; exit 1; }

		if reload_if_enabled; then
			echo "applied; backup: $bak; zapret restarted"
		else
			echo "applied; backup: $bak; service not enabled (no restart)"
		fi
		;;

	revert)
		[ -L "$LATEST" ] || { echo "no backup to revert"; exit 1; }
		bak=$(readlink "$LATEST")
		# readlink may emit a relative path on some busybox builds.
		case "$bak" in
			/*) ;;
			*)  bak="$BACKUP_DIR/$bak" ;;
		esac
		[ -f "$bak" ] || { echo "backup file missing: $bak"; exit 1; }
		old=$(cat "$bak")
		uci set "$UCI_KEY=$old" || { echo "uci set failed"; exit 1; }
		uci commit zapret || { echo "uci commit failed"; exit 1; }
		# After a successful revert, the backup no longer represents "previous";
		# rename it so a second click of Revert is a no-op rather than a loop.
		mv "$bak" "$bak.reverted" 2>/dev/null || true
		rm -f "$LATEST"
		if reload_if_enabled; then
			echo "reverted from $bak; zapret restarted"
		else
			echo "reverted from $bak; service not enabled (no restart)"
		fi
		;;

	state)
		has_backup=false
		backup_ts=""
		if [ -L "$LATEST" ]; then
			target=$(readlink "$LATEST")
			base=$(basename "$target")
			# Filename pattern: NFQWS_OPT.<ts>.bak
			ts_str=${base#NFQWS_OPT.}
			ts_str=${ts_str%.bak}
			has_backup=true
			backup_ts=$ts_str
		fi
		# Reuse the parse subcommand so the displayed candidate count matches
		# the dropdown contents exactly (deduplication is across BOTH formats,
		# not just within each).
		candidates=0
		if [ -f "$LOGFILE" ]; then
			candidates=$("$0" parse 2>/dev/null | wc -l)
		fi
		candidates=$(printf '%s' "$candidates" | tr -d ' ')
		current=$(uci -q get "$UCI_KEY" 2>/dev/null || echo "")
		current=$(flatten_opt "$current")
		if [ ${#current} -gt 400 ]; then
			current=$(printf '%s' "$current" | cut -c1-397)...
		fi
		cat <<JSON
{
	"has_backup": $has_backup,
	"backup_ts": "$(json_escape "$backup_ts")",
	"candidates": $candidates,
	"current": "$(json_escape "$current")"
}
JSON
		;;

	*)
		echo "usage: zapret-apply {parse|apply <strategy>|revert|state}"
		exit 2
		;;
esac
