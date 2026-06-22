#!/usr/bin/env bats
# Regression guard: the installer's tunnel-enumeration awk must restrict to
# awgN-named sections. Adding force_source (or any other) sections with
# option enabled='1' to /etc/config/amnezia must NOT pollute the tunnel list,
# or routing_firewall_apply gets called with non-interface "tunnels" and the
# vpn firewall zone / fw4 ruleset breaks (caught in the VM: all 3 scenarios
# failed D1, and first-install also lost the classifier chain).
load '../lib/harness.bash'
SRC="$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh"

@test "every enabled-based tunnel-enum awk is restricted to awgN sections" {
  # Find each awk line that selects on .enabled=1; each must also gate on
  # the section name beginning with awg<digit>.
  bad=0
  while IFS= read -r line; do
    case "$line" in
      *'awg[0-9]'*) : ;;                      # guarded — good
      *) echo "UNGUARDED enum awk: $line"; bad=1 ;;
    esac
  done <<EOF
$(grep -nE "awk -F'\[.=\]'.*\.enabled=" "$SRC")
EOF
  [ "$bad" -eq 0 ] || { echo "a tunnel-enum awk is not awgN-restricted (force_source pollution risk)"; false; }
}

@test "the corrected awk selects awgN but not force_source sections" {
  run awk -F'[.=]' '/\.enabled='"'"'?1/ && $2 ~ /^awg[0-9]/{print $2}' <<EOF
amnezia.awg1.enabled='1'
amnezia.itdoginfo_inside.enabled='1'
amnezia.itdoginfo_services.enabled='1'
amnezia.awg2.enabled='1'
amnezia.refilter_domains.enabled='0'
EOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^awg1$'
  echo "$output" | grep -q '^awg2$'
  run sh -c 'echo "'"$output"'" | grep -c itdoginfo'
  [ "$output" = "0" ] || { echo "force_source leaked into tunnel enum"; false; }
}
