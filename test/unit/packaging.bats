#!/usr/bin/env bats
load '../lib/harness.bash'
A="$HARNESS_DIR/../packages/amnezia-pbr/Makefile"
@test "amnezia-pbr drops pbr/luci-app-pbr, adds conntrack-tools, ip-full optional" {
  ! grep -Eq "DEPENDS.*\+pbr( |$)" "$A"
  ! grep -q "luci-app-pbr" "$A"
  grep -q "conntrack-tools" "$A"
  grep -q "PKG_RELEASE:=3" "$A"
}
