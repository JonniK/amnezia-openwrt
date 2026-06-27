#!/usr/bin/env bats
load '../lib/harness.bash'
A="$HARNESS_DIR/../packages/amnezia-pbr/Makefile"
@test "amnezia-pbr drops pbr/luci-app-pbr, adds conntrack-tools, ip-full optional" {
  ! grep -Eq "DEPENDS.*\+pbr( |$)" "$A"
  ! grep -q "luci-app-pbr" "$A"
  grep -q "conntrack-tools" "$A"
  grep -q "PKG_RELEASE:=4" "$A"
}
@test "autolearn files are staged into the package tree" {
  ROOT="$HARNESS_DIR/.."
  for f in usr/sbin/amnezia-autolearn usr/bin/amnezia-autolearn-ctl \
           etc/init.d/amnezia-autolearn usr/lib/amnezia/amnezia-autolearn-lib.sh; do
    run find "$ROOT/packages" -path "*/$f"
    [ "$status" -eq 0 ]
    [ -n "$output" ] || { echo "missing $f"; return 1; }
  done
}
