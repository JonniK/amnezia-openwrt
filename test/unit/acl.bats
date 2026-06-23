#!/usr/bin/env bats
load '../lib/harness.bash'
F="$HARNESS_DIR/../openwrt/luci-app-amnezia/acl/luci-app-amnezia.json"
@test "acl grants read of state json (in read/file section)" {
  node -e "
    const a = JSON.parse(require('fs').readFileSync('$F','utf8'));
    const rf = a['luci-app-amnezia'].read.file;
    if (!rf['/var/run/amnezia-failover.json']) throw new Error('state file missing from read/file');
  "
}
@test "acl keeps seed-must-tunnel.list in read/file (runtime path preserved)" {
  node -e "
    const a = JSON.parse(require('fs').readFileSync('$F','utf8'));
    const rf = a['luci-app-amnezia'].read.file;
    if (!rf['/etc/amnezia/seed-must-tunnel.list']) throw new Error('seed-must-tunnel.list missing');
  "
}
@test "acl grants exec of failover-ctl full path (in write/file)" {
  node -e "
    const a = JSON.parse(require('fs').readFileSync('$F','utf8'));
    const wf = a['luci-app-amnezia'].write.file;
    if (!wf['/usr/bin/amnezia-failover-ctl']) throw new Error('failover-ctl missing from write/file');
  "
}
@test "acl drops pbr-status and pbr-reload" {
  node -e "
    const a = JSON.parse(require('fs').readFileSync('$F','utf8'));
    const wf = a['luci-app-amnezia'].write.file;
    if (wf['/usr/bin/pbr-status'])  throw new Error('pbr-status still present');
    if (wf['/usr/bin/pbr-reload'])  throw new Error('pbr-reload still present');
  "
}
@test "acl is valid json" { node -e "JSON.parse(require('fs').readFileSync('$F','utf8'))"; }

@test "acl grants exec on amnezia-dns-ctl under write.file" {
  run node -e '
    const a = require("'"$HARNESS_DIR"'/../openwrt/luci-app-amnezia/acl/luci-app-amnezia.json");
    const wf = a["luci-app-amnezia"].write.file;
    if (!wf["/usr/bin/amnezia-dns-ctl"] || wf["/usr/bin/amnezia-dns-ctl"][0] !== "exec") throw new Error("missing");
    console.log("ok");'
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}
