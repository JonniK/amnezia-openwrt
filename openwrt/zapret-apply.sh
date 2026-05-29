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
# Canonical source for NFQWS_OPT. The remittor zapret-openwrt init.d
# `source`s this file at start; the UCI `option NFQWS_OPT` in
# /etc/config/zapret is read by the LuCI app for display but is NOT what
# nfqws actually runs with. Earlier versions of this script wrote only to
# UCI -- visible in `uci show zapret`, invisible in `ps`. Fixed by writing
# the canonical text file here and leaving UCI untouched.
ZAPRET_CONFIG=/opt/zapret/config

mkdir -p "$BACKUP_DIR"

json_escape() {
	# Escape for JSON string body.
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\n\r\t'
}

# Squeeze multi-line / multi-space NFQWS_OPT into a single-line readable form.
flatten_opt() {
	printf '%s' "$1" | tr '\n\t' '  ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
}

# Read current NFQWS_OPT value (un-quoted) from /opt/zapret/config. Returns
# empty string if the file or line is missing -- the caller decides whether
# that's a fresh-install no-op or a real error.
read_current_opt() {
	[ -f "$ZAPRET_CONFIG" ] || return 0
	# Match the canonical `NFQWS_OPT="..."` form. We stop at the first match;
	# the file may legitimately contain commented examples (`# NFQWS_OPT=...`)
	# above the active line.
	awk '
		/^NFQWS_OPT[[:space:]]*=/ {
			line = $0
			sub(/^NFQWS_OPT[[:space:]]*=[[:space:]]*"/, "", line)
			sub(/"[[:space:]]*$/, "", line)
			print line
			exit
		}
	' "$ZAPRET_CONFIG"
}

# Atomically replace the active NFQWS_OPT="..." line in /opt/zapret/config.
# Writes to a sibling tmp file then mv-renames so a crash mid-write can't
# corrupt the config (the source file is `source`d by init.d -- a partial
# write would break service start on next boot).
write_opt() {
	new=$1
	[ -f "$ZAPRET_CONFIG" ] || { echo "missing $ZAPRET_CONFIG"; return 1; }
	# Escape every metacharacter that would be re-interpreted when init.d
	# `source`s /opt/zapret/config: backslash, double-quote, dollar (param
	# expansion), backtick (command substitution). blockcheck strategies in
	# practice are ASCII flag soup, but an unescaped $X in a hypothetical
	# future strategy would silently zero out part of NFQWS_OPT on next
	# service start, and a backtick would execute. Order matters: backslash
	# first so subsequent escapes don't get re-doubled.
	escaped=$(printf '%s' "$new" | sed \
		-e 's/\\/\\\\/g' \
		-e 's/"/\\"/g' \
		-e 's/\$/\\$/g' \
		-e 's/`/\\`/g')
	tmp="$ZAPRET_CONFIG.tmp.$$"
	# `repl` is passed in env so awk doesn't have to escape \\ / quotes from
	# argv (-v form would require yet another escape pass).
	NEW_OPT="$escaped" awk '
		BEGIN { repl = ENVIRON["NEW_OPT"]; done = 0 }
		/^NFQWS_OPT[[:space:]]*=/ && !done {
			printf "NFQWS_OPT=\"%s\"\n", repl
			done = 1
			next
		}
		{ print }
		END {
			# If the file never had an NFQWS_OPT= line (corrupted /
			# stripped install), append one so the next service start
			# can pick it up.
			if (!done) printf "NFQWS_OPT=\"%s\"\n", repl
		}
	' "$ZAPRET_CONFIG" > "$tmp" || { rm -f "$tmp"; return 1; }
	# Match the perms upstream zapret ships the config with (0644 root:root).
	# Busybox chmod has no --reference, so hard-code the canonical value.
	chmod 0644 "$tmp"
	mv "$tmp" "$ZAPRET_CONFIG" || { rm -f "$tmp"; return 1; }
	return 0
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
		current=$(read_current_opt)
		# No-op if the value is already what the user is trying to apply --
		# saves a jffs2 write cycle and avoids a needless zapret restart.
		if [ "$newopt" = "$current" ]; then
			echo "already applied (no change)"
			exit 0
		fi
		ts=$(date +%Y%m%d-%H%M%S)
		bak="$BACKUP_DIR/NFQWS_OPT.$ts.bak"
		# Atomic backup write: tmp + mv. Backup body is the raw OPT value
		# (no NFQWS_OPT= prefix, no quotes) -- revert wraps it back in.
		printf '%s\n' "$current" > "$bak.tmp" && mv "$bak.tmp" "$bak"
		ln -sf "$bak" "$LATEST"
		# Trim backup history to the last 10 entries so the dir doesn't grow
		# unbounded on jffs2. The .latest symlink (revert target) is preserved
		# by name -- we only delete plain .bak / .bak.reverted older than 10.
		ls -1t "$BACKUP_DIR"/NFQWS_OPT.*.bak "$BACKUP_DIR"/NFQWS_OPT.*.bak.reverted 2>/dev/null \
			| tail -n +11 | while read -r _f; do rm -f "$_f"; done

		# Write into /opt/zapret/config -- the canonical source the init.d
		# scripts read. Earlier versions wrote into UCI only; that left the
		# running nfqws on whatever value /opt/zapret/config had (typically
		# the package's bundled StressOzz example) instead of our new OPT.
		if ! write_opt "$newopt"; then
			echo "failed to write $ZAPRET_CONFIG"; exit 1
		fi

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
		if ! write_opt "$old"; then
			echo "failed to write $ZAPRET_CONFIG"; exit 1
		fi
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
		current=$(read_current_opt)
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
