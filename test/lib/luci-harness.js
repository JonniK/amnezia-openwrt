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
// Realistic createHandlerFn: throws TypeError if ctx is null/undefined (mirrors LuCI's real
// `ctx[fn]` deref failing with undefined context), so the this===undefined bug in
// paintMasterStrip is observable. Does NOT check method existence — section modules legitimately
// create handlers for methods that live on the assembled view, not on `this` in their own scope.
// Mirror LuCI's REAL createHandlerFn: binds extra args FIRST, passes the DOM event LAST
// (handler is called as fn(...args, event), NOT fn(event, ...args)). Returns null when the
// method is missing (→ no listener → inert button), exactly like LuCI. This is what makes
// the param-order bug observable: a handler defined function(ev, name) wired with an extra
// arg receives (name, event) and would mis-send the event as the backend argument.
const ui = { createHandlerFn:function(ctx, fn){
		if(ctx==null) throw new TypeError('handler '+fn+' not found on ctx (ctx is null/undefined)');
		var args = Array.prototype.slice.call(arguments, 2);
		var f = (typeof fn === 'string') ? ctx[fn] : fn;
		if(typeof f !== 'function') return null;
		// LuCI returns L.bind(wrapper, ctx, ...args): the bound fn has the extra args
		// PREPENDED, and the DOM appends the event → handler is called f(...args, event).
		return function(){ var callArgs = Array.prototype.slice.call(arguments); return Promise.resolve(f.apply(ctx, args.concat(callArgs))); };
	}, addNotification:()=>{}, showModal:()=>E('div'), hideModal:()=>{} };
const fsApi = { read:()=>Promise.resolve(''), exec:()=>Promise.resolve({stdout:'',stderr:'',code:0}), stat:()=>Promise.resolve(null) };
const poll = { add:()=>{}, remove:()=>{} };
const baseclass = { extend:o=>o }, view = { extend:o=>o };
// Return recording nodes for known element IDs so paintMasterStrip can mutate them.
function makeRecordingNode(id){
  var n=E('div',{'id':id});
  n.classList={add:function(){},remove:function(){},contains:function(){return false;}};
  n.style={};
  n.disabled=false;
  n.value='';
  n.textContent='';
  n.dataset={};
  n.removeAttribute=function(){};
  n.setAttribute=function(){};
  n.getAttribute=function(){return null;};
  return n;
}
// querySelector returns a stub element with value:'as' so handleAppAdd reads a valid method.
function makeQuerySelectorResult(selector) {
  var n = makeRecordingNode('qs-result');
  // For method radio querySelector, return value 'as' so handleAppAdd takes the 'as' branch.
  if (selector && selector.indexOf('app-add-method') >= 0) { n.value = 'as'; }
  return n;
}
const documentStub = { getElementById:function(id){ return makeRecordingNode(id); }, activeElement:null, querySelectorAll:()=>[], querySelector:function(sel){ return makeQuerySelectorResult(sel); }, createElement:()=>E('div') };
// DATA: 13 elements — indices 10 (DoT status), 11 (master_enabled), 12 (tunnel apps list).
const DATA = ['', {stdout:''}, '', {stdout:''}, {stdout:''}, {stdout:''}, '', '', '', '', {stdout:'{}'}, {stdout:'1'}, {stdout:'[]'}];

// Load a module with a given fs stub and dependency map.
function loadWith(rel, deps, fsStub){ const file = path.join(ROOT, rel); if(!fs.existsSync(file)) return null;
  const src = fs.readFileSync(file,'utf8');
  const names = ['baseclass','ui','fs','poll','view','E','_','L','document','util','failover','routing','zapret','dns'];
  const fn = new Function(...names, src);
  return fn(baseclass, ui, fsStub, poll, view, E, _, L, documentStub,
           deps.util, deps.failover, deps.routing, deps.zapret, deps.dns); }

// Default loader (succeeding fs stubs).
function load(rel, deps){ return loadWith(rel, deps, fsApi); }

const d = {};
d.util      = load('amnezia/util.js', d);
d.routing   = load('amnezia/section/routing.js', d);
d.zapret    = load('amnezia/section/zapret.js', d);
d.dns       = load('amnezia/section/dns.js', d);
d.failover  = load('amnezia/section/failover.js', d);
const main  = load('view/main.js', d);
// FIX: use call(main, DATA) so this=main and data=DATA (LuCI single-arg render signature).
let mainTree = null;
if (main && typeof main.render === 'function') { try { mainTree = main.render.call(main, DATA); } catch(e){ console.error('main.render threw: '+e.message); process.exit(1);} }
// Teeth: the master-switch strip MUST be populated synchronously in the render
// tree (NOT via a microtask + getElementById, which races LuCI's DOM insertion
// on the real router and silently leaves the strip empty). Walk the returned
// tree (not document) and assert #amz-master-strip has a button child.
function findById(n, id){ if(!n||typeof n!=='object') return null;
  if(n.attrs && n.attrs.id===id) return n;
  for(const c of (n.children||[])){ const r=findById(c,id); if(r) return r; } return null; }
function hasTag(n, tag){ if(!n||typeof n!=='object') return false;
  if(n.tag===tag) return true;
  return (n.children||[]).some(c=>hasTag(c,tag)); }
if (mainTree) {
  const strip = findById(mainTree, 'amz-master-strip');
  if (!strip) { console.error('FAIL: #amz-master-strip not found in render tree'); process.exit(1); }
  if (!hasTag(strip, 'button')) { console.error('FAIL: #amz-master-strip is EMPTY in render tree (microtask/getElementById race — strip would be blank on the real router)'); process.exit(1); }
  // Tooth: tunnel-apps-tbody must exist synchronously in the render tree (not via getElementById at render time).
  const appsTbody = findById(mainTree, 'tunnel-apps-tbody');
  if (!appsTbody) { console.error('FAIL: #tunnel-apps-tbody not found in render tree (apps table must be painted synchronously, not via getElementById)'); process.exit(1); }
}
// Execute every render() that exists → throws on undefined-symbol refs.
const panels = [];
for (const k of ['failover','routing','zapret','dns']) {
  if (d[k] && typeof d[k].render === 'function') { const node = d[k].render({}, DATA); panels.push([k,node]); } }
function walk(n, fn){ if(!n||typeof n!=='object')return; fn(n); (n.children||[]).forEach(c=>walk(c,fn)); }

// Lint: LuCI does NOT auto-bind a dotted/namespaced require. `'require a.b.c'` WITHOUT
// ` as <alias>` leaves the local variable undefined → ReferenceError at runtime (blank
// panel). The module-execution path cannot catch this (we bind deps by name here), so
// assert it textually across every shipped JS file. (Convention proven on-device: every
// dotted require — tools.firewall as fwtool, tools.widgets as widgets — carries ` as `.)
function lintRequires(){
  const files = ['view/main.js','amnezia/util.js','amnezia/section/failover.js','amnezia/section/routing.js','amnezia/section/zapret.js','amnezia/section/dns.js'];
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
  dr.failover  = loadWith('amnezia/section/failover.js', dr, fsRej);
  const viewStub = {};
  const refreshPromises = [];
  for (const k of ['failover','routing','zapret','dns']) {
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
      // Each handler mapped to the EXTRA args its button wires via createHandlerFn
      // (NOT including the event — LuCI appends that last). Sentinels are recognizable
      // strings so the arg-order spy can assert they reach the backend (and the event does NOT).
      const WIRING = {
        handleSetMode: [], handleSetSticky: [],
        handleMakeDefault: ['awgSENT'], handleTunnelRestart: ['awgSENT'],
        handleTunnelToggle: ['awgSENT'], handleTunnelRemove: ['awgSENT', '1.2.3.4'],
        handleForcePin: [], handleForceUnpin: [],
        handleDotSetEnabled: ['1'], handleDotProvider: [], handleDotTest: [],
        handleMasterToggle: ['1'],
        handleProbe: ['ex.com'], handleSourceToggle: ['itdoginfo_inside'],
        // Tunnel-apps handlers — extra args first, event last (LuCI convention).
        handleAppToggle: ['appSENT'], handleAppRemove: ['appSENT'],
        handleAppPreset: ['telegram'],
        handleAppAdd: []   // NO extra arg — reads form fields from DOM in handler
      };
      const CHANGE_HANDLERS = Object.keys(WIRING);
      const fakeEv = { __isEvent: true, target: { checked: true, value: 'awg1' }, currentTarget: documentStub.createElement('button'), preventDefault: function(){} };

      function buildView(fsStub) {
        const dv = {};
        dv.util      = loadWith('amnezia/util.js', dv, fsStub);
        dv.routing   = loadWith('amnezia/section/routing.js', dv, fsStub);
        dv.zapret    = loadWith('amnezia/section/zapret.js', dv, fsStub);
        dv.dns       = loadWith('amnezia/section/dns.js', dv, fsStub);
        dv.failover  = loadWith('amnezia/section/failover.js', dv, fsStub);
        const mv = loadWith('view/main.js', dv, fsStub);
        // Assemble exactly as LuCI does via view.extend(Object.assign(...)).
        const assembled = Object.assign({}, mv,
          (dv.failover && dv.failover.handlers) || {},
          (dv.routing  && dv.routing.handlers)  || {},
          (dv.zapret   && dv.zapret.handlers)   || {},
          (dv.dns      && dv.dns.handlers)       || {}
        );
        // Bind util for handlers that call util.uiConfirm.
        assembled.__util = dv.util;
        // Provide a minimal util stub that always confirms so handlers don't deadlock.
        if (assembled.__util) {
          assembled.__util.uiConfirm = function() { return Promise.resolve(false); };
        }
        // Wire __failoverModule so the refresh path inside handlers is real, not the no-op fallback.
        assembled.__failoverModule = dv.failover || null;
        return assembled;
      }

      // Reject-safety: invoke every handler VIA the LuCI-accurate createHandlerFn (extra
      // args first, event last) under succeeding + rejecting fs; each must resolve.
      const handlerTests = [];
      for (const fsStub of [fsApi, fsRej]) {
        const assembled = buildView(fsStub);
        if (assembled.__util) assembled.__util.uiConfirm = function(){ return Promise.resolve(true); };
        for (const name of CHANGE_HANDLERS) {
          const h = ui.createHandlerFn(assembled, name, ...(WIRING[name] || []));
          if (h == null) { handlerTests.push(Promise.reject(new Error('createHandlerFn returned null for ' + name + ' (method missing on view)'))); continue; }
          handlerTests.push(Promise.resolve().then(function(){ return h(fakeEv); })
            .then(undefined, function(e){ throw new Error('handler ' + name + ' rejected: ' + e.message); }));
        }
      }

      return Promise.all(handlerTests)
        .then(function() { console.log('handler-exec-safe ok'); })
        .catch(function(e) { console.error('FAIL: ' + e.message); process.exit(1); })
        .then(function() {
          // ── Arg-order pass (teeth for the createHandlerFn convention) ─────────────
          // LuCI calls handlers as fn(...extraArgs, event). A handler defined function(ev, x)
          // wired with an extra arg would mis-send the EVENT object as a backend argument.
          // Spy fs.exec: assert every backend arg is a STRING (never the event object), and
          // that the sentinel extra arg actually reaches the exec.
          const execCalls = [];
          const fsSpy = { read:()=>Promise.resolve(''), stat:()=>Promise.resolve(null),
            exec:function(cmd, args){ execCalls.push({cmd:cmd, args:(args||[]).slice()}); return Promise.resolve({stdout:'{}',stderr:'',code:0}); } };
          const av = buildView(fsSpy);
          if (av.__util) av.__util.uiConfirm = function(){ return Promise.resolve(true); };
          let chain = Promise.resolve();
          const bad = [];
          CHANGE_HANDLERS.forEach(function(name){
            chain = chain.then(function(){
              const before = execCalls.length;
              const h = ui.createHandlerFn(av, name, ...(WIRING[name] || []));
              if (h == null) { bad.push(name + ': createHandlerFn null'); return; }
              return Promise.resolve(h(fakeEv)).catch(function(){}).then(function(){
                // The teeth: if a handler defined function(ev, x) is wired with an extra arg,
                // LuCI passes (x, event) → the event object leaks in as a backend argument.
                execCalls.slice(before).forEach(function(c){
                  c.args.forEach(function(arg){
                    if (typeof arg !== 'string') bad.push(name + ' passed non-string arg to exec (' + Object.prototype.toString.call(arg) + ') — arg-order bug: event leaked as backend argument');
                  });
                });
              });
            });
          });
          return chain.then(function(){
            if (bad.length) { console.error('FAIL: handler arg-order:\n  ' + bad.join('\n  ')); process.exit(1); }
            console.log('handler-argorder ok');
          });
        })
        .then(function() {
          // ── Master-repaint-safe pass ──────────────────────────────────────────────
          // Exercises the handleMasterToggle repaint branch: uiConfirm=true, fs.exec=ok.
          // paintMasterStrip calls ui.createHandlerFn(this, 'handleMasterToggle', ...) —
          // if this===undefined the realistic createHandlerFn stub throws a TypeError here.
          // This pass ensures paintMasterStrip is called with the correct `self` context.
          var repaintView = buildView(fsApi);
          // Run main.render first so the module-level state (domSeen, pollFn) is seeded.
          var mr = loadWith('view/main.js', (function(){ var dv2={}; dv2.util=loadWith('amnezia/util.js',dv2,fsApi); dv2.routing=loadWith('amnezia/section/routing.js',dv2,fsApi); dv2.zapret=loadWith('amnezia/section/zapret.js',dv2,fsApi); dv2.dns=loadWith('amnezia/section/dns.js',dv2,fsApi); dv2.failover=loadWith('amnezia/section/failover.js',dv2,fsApi); return dv2; }()), fsApi);
          if (mr && typeof mr.render === 'function') { try { mr.render.call(mr, DATA); } catch(e2) { /* ignore render errors in this sub-env */ } }
          // Override uiConfirm to resolve TRUE so the toggle actually executes the repaint path.
          if (repaintView.__util) repaintView.__util.uiConfirm = function() { return Promise.resolve(true); };
          // Track whether a 'danger' notification was added (indicates TypeError in repaint).
          var dangerFired = false;
          var origAddNotification = ui.addNotification;
          ui.addNotification = function(id, node, cls) { if (cls === 'danger') dangerFired = true; origAddNotification(id, node, cls); };
          return Promise.resolve()
            // handleMasterToggle(currentState, ev) — LuCI convention: extra arg first, event last.
            .then(function() { return repaintView.handleMasterToggle.call(repaintView, '1', {preventDefault:function(){}}); })
            .then(function() {
              ui.addNotification = origAddNotification;
              if (dangerFired) { console.error('FAIL: master-repaint fired danger notification (TypeError in paintMasterStrip — this not bound)'); process.exit(1); }
              console.log('master-repaint-safe ok');
            }, function(e) {
              ui.addNotification = origAddNotification;
              console.error('FAIL: master-repaint rejected: ' + e.message);
              process.exit(1);
            });
        });
    });
}
