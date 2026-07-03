#!/bin/sh
# amnezia-blackbox: append a one-line vitals sample to flash every run (cron 1/min).
# Survives spontaneous resets so the trend just before a hang is recoverable.
LOG=/etc/amnezia/blackbox.log
t=$(date +%Y-%m-%dT%H:%M:%S 2>/dev/null || echo "?")
up=$(cut -d. -f1 /proc/uptime 2>/dev/null)
temp=$(( $(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo 0) / 1000 ))
load=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null)
memav=$(awk '/MemAvailable/{print $2}' /proc/meminfo 2>/dev/null)
_pool=$(awk -F'"' '/"active_pool":/{print $4}' /var/run/amnezia-failover.json 2>/dev/null)
_pool=${_pool:-awg3}
xfer=$(awg show "$_pool" transfer 2>/dev/null | awk '{print "rx="$2" tx="$3}')
fo=$(uci -q get amnezia.config.dnsleak_failopen 2>/dev/null || echo 0)
printf '%s up=%s temp=%s load=%s memav=%s %s failopen=%s\n' "$t" "$up" "$temp" "$load" "$memav" "$xfer" "$fo" >> "$LOG"
# Trim only when large (avoid rewriting flash every minute).
if [ "$(wc -l < "$LOG" 2>/dev/null || echo 0)" -gt 3000 ]; then
  tail -n 2000 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
fi
