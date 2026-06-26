// Offline loader for LuCI 'require'-style modules. Stubs globals, records E() tree,
// executes each module + its render() to catch undefined-symbol ReferenceErrors and
// to expose the virtual DOM for structural (accordion) assertions.
const fs = require('fs'), path = require('path');
const ROOT = path.resolve(__dirname, '../../openwrt/luci-app-amnezia');
function E(tag, attrs, children){ if (attrs && (Array.isArray(attrs)||typeof attrs!=='object')){children=attrs;attrs={};}
  var node = { tag, attrs: attrs||{}, children: [].concat(children||[]).filter(x=>x!=null) };
  node.appendChild = function(c){ if(c) this.children.push(c); return c; };
  node.createTextNode = function(t){ return {tag:'#text',text:t}; };
  node.__defineGetter__('innerHTML',function(){return '';});
  node.__defineSetter__('innerHTML',function(){this.children=[];});
  node.querySelectorAll = function(){ return []; };
  node.contains = function(){ return false; };
  node.scrollTop = 0;
  node.__defineGetter__('scrollHeight',function(){return 0;});
  return node; }
const _ = s => s;
const L = { bind:(fn,ctx)=>fn.bind(ctx), resolveDefault:(p,d)=>Promise.resolve(p).then(v=>v!=null?v:d, ()=>d) };
const ui = { createHandlerFn:()=>function(){return Promise.resolve();}, addNotification:()=>{}, showModal:()=>E('div'), hideModal:()=>{} };
const fsApi = { read:()=>Promise.resolve(''), exec:()=>Promise.resolve({stdout:'',stderr:'',code:0}), stat:()=>Promise.resolve(null) };
const poll = { add:()=>{}, remove:()=>{} };
const baseclass = { extend:o=>o }, view = { extend:o=>o };
const documentStub = { getElementById:()=>null, activeElement:null, querySelectorAll:()=>[], createElement:()=>E('div') };
// DATA: 12 elements — indices 10 (DoT status) and 11 (master_enabled) added for Phase 4.
const DATA = ['', {stdout:''}, '', {stdout:''}, {stdout:''}, {stdout:''}, '', '', '', '', {stdout:'{}'}, {stdout:'1'}];

// Load a module with a given fs stub and dependency map.
function loadWith(rel, deps, fsStub){ const file = path.join(ROOT, rel); if(!fs.existsSync(file)) return null;
  const src = fs.readFileSync(file,'utf8');
  const names = ['baseclass','ui','fs','poll','view','E','_','L','document','util','failover','routing','zapret','dns','autolearn'];
  const fn = new Function(...names, src);
  return fn(baseclass, ui, fsStub, poll, view, E, _, L, documentStub,
           deps.util, deps.failover, deps.routing, deps.zapret, deps.dns, deps.autolearn); }

// Default loader (succeeding fs stubs).
function load(rel, deps){ return loadWith(rel, deps, fsApi); }

const d = {};
d.util      = load('amnezia/util.js', d);
d.routing   = load('amnezia/section/routing.js', d);
d.zapret    = load('amnezia/section/zapret.js', d);
d.dns       = load('amnezia/section/dns.js', d);
d.autolearn = load('amnezia/section/autolearn.js', d);
d.failover  = load('amnezia/section/failover.js', d);
const main  = load('view/main.js', d);
// FIX: use call(main, DATA) so this=main and data=DATA (LuCI single-arg render signature).
if (main && typeof main.render === 'function') { try { main.render.call(main, DATA); } catch(e){ console.error('main.render threw: '+e.message); process.exit(1);} }
// Execute every render() that exists → throws on undefined-symbol refs.
const panels = [];
for (const k of ['failover','routing','zapret','dns','autolearn']) {
  if (d[k] && typeof d[k].render === 'function') { const node = d[k].render({}, DATA); panels.push([k,node]); } }
function walk(n, fn){ if(!n||typeof n!=='object')return; fn(n); (n.children||[]).forEach(c=>walk(c,fn)); }

// Lint: LuCI does NOT auto-bind a dotted/namespaced require. `'require a.b.c'` WITHOUT
// ` as <alias>` leaves the local variable undefined → ReferenceError at runtime (blank
// panel). The module-execution path cannot catch this (we bind deps by name here), so
// assert it textually across every shipped JS file. (Convention proven on-device: every
// dotted require — tools.firewall as fwtool, tools.widgets as widgets — carries ` as `.)
function lintRequires(){
  const files = ['view/main.js','amnezia/util.js','amnezia/section/failover.js','amnezia/section/routing.js','amnezia/section/zapret.js','amnezia/section/dns.js','amnezia/section/autolearn.js'];
  const bad = [];
  files.forEach(function(rel){
    const file = path.join(ROOT, rel); if(!fs.existsSync(file)) return;
    fs.readFileSync(file,'utf8').split('\n').forEach(function(line, i){
      const m = line.match(/^\s*['"]require\s+([^'"]+)['"]\s*;?\s*$/);
      if(!m) return;
      const spec = m[1].trim();
      if(spec.indexOf('.')>=0 && !/\sas\s/.test(spec)) bad.push(rel+':'+(i+1)+'  '+spec);
    });
  });
  return bad;
}

module.exports = { d, main, panels, walk, DATA, lintRequires };
if (require.main === module) {
  // Require-alias lint FIRST (cheapest, catches the blank-panel footgun).
  const reqBad = lintRequires();
  if (reqBad.length) { console.error('FAIL: dotted require without ` as <alias>` (LuCI will not bind it → ReferenceError):\n  '+reqBad.join('\n  ')); process.exit(1); }
  // Self-test mode: assert accordion invariants when all section modules exist.
  let details=[], badOpen=[];
  panels.forEach(([k,node])=>walk(node,n=>{ if(n.tag==='details'){ details.push(n);
    const cls=(n.attrs.class||''); const open=Object.prototype.hasOwnProperty.call(n.attrs,'open') && n.attrs.open!=null;
    if(cls.indexOf('amnezia-action')>=0 && open) badOpen.push(k); }}));
  if (badOpen.length) { console.error('FAIL: action panel open by default in '+badOpen.join(',')); process.exit(1); }
  console.log('harness ok: modules='+Object.keys(d).filter(k=>d[k]).length+' panels='+panels.length+' details='+details.length);

  // Rejection-mode self-test: every module.refresh() must RESOLVE (not reject) when fs fails.
  // This specifically validates the L.resolveDefault guard in dns.refresh().
  const fsRej = { read:()=>Promise.reject(new Error('reject')), exec:()=>Promise.reject(new Error('reject')), stat:()=>Promise.reject(new Error('reject')) };
  const dr = {};
  dr.util      = loadWith('amnezia/util.js', dr, fsRej);
  dr.routing   = loadWith('amnezia/section/routing.js', dr, fsRej);
  dr.zapret    = loadWith('amnezia/section/zapret.js', dr, fsRej);
  dr.dns       = loadWith('amnezia/section/dns.js', dr, fsRej);
  dr.autolearn = loadWith('amnezia/section/autolearn.js', dr, fsRej);
  dr.failover  = loadWith('amnezia/section/failover.js', dr, fsRej);
  const viewStub = {};
  const refreshPromises = [];
  for (const k of ['failover','routing','zapret','dns','autolearn']) {
    if (dr[k] && typeof dr[k].refresh === 'function') {
      // Wrap in Promise.resolve().then() so synchronous throws are also captured as rejections.
      refreshPromises.push([k, Promise.resolve().then(function(){ return dr[k].refresh(viewStub); })]);
    }
  }
  Promise.all(refreshPromises.map(function(pair){ return pair[1]; }))
    .then(function(){
      console.log('refresh-reject-safe ok');
    })
    .catch(function(e){
      console.error('FAIL: a module.refresh() rejected under failing fs: '+e.message);
      process.exit(1);
    })
    .then(function() {
      // ── Handler-execution pass ────────────────────────────────────────────────
      // Build the assembled view the same way main.js does (Object.assign of all handlers).
      // Test every named change handler under BOTH succeeding and rejecting fs loads.
      // Each handler must: (a) not synchronously throw, and (b) resolve (not reject).
      // This is the regression guard the original Item-3 inline-closure bug would have tripped.
      const CHANGE_HANDLERS = [
        'handleSetMode', 'handleSetSticky',
        'handleMakeDefault', 'handleTunnelRestart',
        'handleForcePin', 'handleForceUnpin',
        'handleDotToggle', 'handleDotProvider',
        'handleMasterToggle'
      ];
      const fakeEv = { target: { checked: true, value: 'awg1' }, preventDefault: function(){} };

      function buildView(fsStub) {
        const dv = {};
        dv.util      = loadWith('amnezia/util.js', dv, fsStub);
        dv.routing   = loadWith('amnezia/section/routing.js', dv, fsStub);
        dv.zapret    = loadWith('amnezia/section/zapret.js', dv, fsStub);
        dv.dns       = loadWith('amnezia/section/dns.js', dv, fsStub);
        dv.autolearn = loadWith('amnezia/section/autolearn.js', dv, fsStub);
        dv.failover  = loadWith('amnezia/section/failover.js', dv, fsStub);
        const mv = loadWith('view/main.js', dv, fsStub);
        // Assemble exactly as LuCI does via view.extend(Object.assign(...)).
        const assembled = Object.assign({}, mv,
          (dv.failover && dv.failover.handlers) || {},
          (dv.routing  && dv.routing.handlers)  || {},
          (dv.zapret   && dv.zapret.handlers)   || {},
          (dv.dns      && dv.dns.handlers)       || {},
          (dv.autolearn && dv.autolearn.handlers) || {}
        );
        // Bind util for handlers that call util.uiConfirm.
        assembled.__util = dv.util;
        // Provide a minimal util stub that always confirms so handlers don't deadlock.
        if (assembled.__util) {
          assembled.__util.uiConfirm = function() { return Promise.resolve(false); };
        }
        return assembled;
      }

      const handlerTests = [];
      for (const fsStub of [fsApi, fsRej]) {
        const assembled = buildView(fsStub);
        for (const name of CHANGE_HANDLERS) {
          if (typeof assembled[name] !== 'function') {
            // Handler missing — treat as an error.
            handlerTests.push(Promise.reject(new Error('handler ' + name + ' not found on assembled view')));
            continue;
          }
          handlerTests.push(
            Promise.resolve().then(function(n, a) {
              return a[n].call(a, fakeEv, 'awg1');
            }.bind(null, name, assembled))
            .then(undefined, function(e) {
              throw new Error('handler ' + name + ' rejected: ' + e.message);
            })
          );
        }
      }

      return Promise.all(handlerTests)
        .then(function() {
          console.log('handler-exec-safe ok');
        })
        .catch(function(e) {
          console.error('FAIL: ' + e.message);
          process.exit(1);
        });
    });
}
