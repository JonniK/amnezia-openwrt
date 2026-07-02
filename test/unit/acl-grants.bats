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

@test "every fs.exec string-literal path in shipped JS has an exec grant in the ACL" {
  # Extracts every fs.exec('<absolute-path>' or fs.exec("<absolute-path>" literal
  # from view/*.js and amnezia/**/*.js and asserts it appears in write.file[path]
  # with an 'exec' grant.  Fails if a new fs.exec is added without an ACL entry.
  node -e "
    var fs = require('fs'), path = require('path');
    var ACL = JSON.parse(fs.readFileSync('$F','utf8'));
    var wf = ACL['luci-app-amnezia'].write.file;
    var ROOT = path.resolve('$HARNESS_DIR/../openwrt/luci-app-amnezia');
    function collectJs(dir) {
      var out = [];
      if (!fs.existsSync(dir)) return out;
      fs.readdirSync(dir, { withFileTypes: true }).forEach(function(e) {
        var full = path.join(dir, e.name);
        if (e.isDirectory()) { collectJs(full).forEach(function(f){ out.push(f); }); }
        else if (e.name.endsWith('.js')) { out.push(full); }
      });
      return out;
    }
    var re = /fs\\.exec\\s*\\(\\s*['\"](\\/[^'\"]+)['\"]/;
    var missing = [];
    collectJs(ROOT).forEach(function(file) {
      fs.readFileSync(file,'utf8').split('\n').forEach(function(line, i) {
        var m = line.match(re);
        if (!m) return;
        var p = m[1];
        if (!wf[p] || wf[p].indexOf('exec') === -1)
          missing.push(file.replace(ROOT+'/','') + ':' + (i+1) + ' -> ' + p);
      });
    });
    if (missing.length) { console.error('Missing exec grant:\n  ' + missing.join('\n  ')); process.exit(1); }
  "
}

@test "acl has uci read grant for amnezia package" {
  node -e "
    const a = JSON.parse(require('fs').readFileSync('$F','utf8'));
    const ru = a['luci-app-amnezia'].read.uci;
    if (!ru || ru.indexOf('amnezia') === -1)
      throw new Error('missing read.uci grant for amnezia package');
  "
}
