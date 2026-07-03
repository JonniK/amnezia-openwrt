#!/usr/bin/env bats
load '../lib/harness.bash'
A="$HARNESS_DIR/../packages/amnezia-pbr/Makefile"
@test "amnezia-pbr drops pbr/luci-app-pbr, adds conntrack-tools, ip-full optional" {
  ! grep -Eq "DEPENDS.*\+pbr( |$)" "$A"
  ! grep -q "luci-app-pbr" "$A"
  grep -q "conntrack-tools" "$A"
  grep -q "PKG_RELEASE:=4" "$A"
}
@test "deploy-openwrt-safe.sh uploads section/*.js by glob (not a hand list)" {
  root="$HARNESS_DIR/.."
  # Ensure the script uses a glob pattern rather than hardcoded section file names;
  # this test fails if someone reverts to a static enumeration and omits a new module.
  grep -q 'section/\*.js' "$root/dev/deploy-openwrt-safe.sh"
}

@test "install-luci-app-amnezia.sh checks section/*.js by glob (not a hand list)" {
  root="$HARNESS_DIR/.."
  grep -q 'section/\*\.js' "$root/openwrt/install-luci-app-amnezia.sh"
}

@test "every openwrt/luci-app-amnezia/amnezia/section/*.js is a real file (source tree complete)" {
  root="$HARNESS_DIR/.."
  _found=0
  for _f in "$root/openwrt/luci-app-amnezia/amnezia/section/"*.js; do
    [ -f "$_f" ] || { echo "glob returned non-file: $_f"; return 1; }
    _found=$(( _found + 1 ))
  done
  [ "$_found" -gt 0 ] || { echo "no section/*.js files found in source tree"; return 1; }
}

@test "autolearn files are NOT staged into the package tree (feature removed)" {
  ROOT="$HARNESS_DIR/.."
  for f in usr/sbin/amnezia-autolearn usr/bin/amnezia-autolearn-ctl \
           etc/init.d/amnezia-autolearn usr/lib/amnezia/amnezia-autolearn-lib.sh; do
    run find "$ROOT/packages" -path "*/$f"
    [ "$status" -eq 0 ]
    [ -z "$output" ] || { echo "unexpected file still present: $f"; return 1; }
  done
}
