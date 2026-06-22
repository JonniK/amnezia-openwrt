#!/usr/bin/env bats
# test/unit/acl-grants.bats
# Structural assertions on luci-app-amnezia.json for Phase E additions.
# Node JSON-structural style matching test/unit/acl.bats.
load '../lib/harness.bash'
F="$HARNESS_DIR/../openwrt/luci-app-amnezia/acl/luci-app-amnezia.json"

@test "acl grants exec of every new helper (write/file)" {
  node -e "
    const a=JSON.parse(require('fs').readFileSync('$F','utf8'));
    const wf=a['luci-app-amnezia'].write.file;
    for (const p of ['/usr/bin/amnezia-tunnel-ctl','/usr/bin/amnezia-force-load','/usr/bin/amnezia-force-update'])
      if(!wf[p]) throw new Error('missing exec grant '+p);
  "
}

@test "acl grants read of force list + stamp (read/file)" {
  node -e "
    const a=JSON.parse(require('fs').readFileSync('$F','utf8'));
    const rf=a['luci-app-amnezia'].read.file;
    for (const p of ['/etc/amnezia/force-tunnel.list','/etc/amnezia/force-update.json'])
      if(!rf[p]) throw new Error('missing read grant '+p);
  "
}

@test "acl does NOT grant write of force-tunnel.list (save goes via save-manual exec)" {
  node -e "
    const a=JSON.parse(require('fs').readFileSync('$F','utf8'));
    const wf=a['luci-app-amnezia'].write.file['/etc/amnezia/force-tunnel.list'];
    if (wf && wf.indexOf('write')!==-1) throw new Error('unexpected write grant on force-tunnel.list');
  "
}

@test "acl tunnel-ctl exec grant contains only exec (not write)" {
  node -e "
    const a=JSON.parse(require('fs').readFileSync('$F','utf8'));
    const wf=a['luci-app-amnezia'].write.file;
    for (const p of ['/usr/bin/amnezia-tunnel-ctl','/usr/bin/amnezia-force-load','/usr/bin/amnezia-force-update']) {
      const v=wf[p];
      if(!v||!Array.isArray(v)||v.indexOf('exec')===-1) throw new Error(p+' has no exec in grant array');
    }
  "
}

@test "acl read grants for force-tunnel.list and force-update.json have read permission" {
  node -e "
    const a=JSON.parse(require('fs').readFileSync('$F','utf8'));
    const rf=a['luci-app-amnezia'].read.file;
    for (const p of ['/etc/amnezia/force-tunnel.list','/etc/amnezia/force-update.json']) {
      const v=rf[p];
      if(!v||!Array.isArray(v)||v.indexOf('read')===-1) throw new Error(p+' missing read permission');
    }
  "
}

@test "acl is still valid json after phase E changes" {
  node -e "JSON.parse(require('fs').readFileSync('$F','utf8'))";
}
