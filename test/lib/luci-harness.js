// Offline loader for LuCI 'require'-style modules. Stubs globals, records E() tree,
// executes each module + its render() to catch undefined-symbol ReferenceErrors and
// to expose the virtual DOM for structural (accordion) assertions.
const fs = require('fs'), path = require('path');
const ROOT = path.resolve(__dirname, '../../openwrt/luci-app-amnezia');
function E(tag, attrs, children){ if (attrs && (Array.isArray(attrs)||typeof attrs!=='object')){children=attrs;attrs={};}
  return { tag, attrs: attrs||{}, children: [].concat(children||[]).filter(x=>x!=null) }; }
const _ = s => s;
const L = { bind:(fn,ctx)=>fn.bind(ctx), resolveDefault:(_p,d)=>Promise.resolve(d) };
const ui = { createHandlerFn:()=>function(){return Promise.resolve();}, addNotification:()=>{}, showModal:()=>E('div'), hideModal:()=>{} };
const fsApi = { read:()=>Promise.resolve(''), exec:()=>Promise.resolve({stdout:'',stderr:'',code:0}), stat:()=>Promise.resolve(null) };
const poll = { add:()=>{}, remove:()=>{} };
const baseclass = { extend:o=>o }, view = { extend:o=>o };
const documentStub = { getElementById:()=>null, activeElement:null, querySelectorAll:()=>[], createElement:()=>E('div') };
const DATA = ['', {stdout:''}, '', {stdout:''}, {stdout:''}, {stdout:''}, '', '', '', ''];
function load(rel, deps){ const file = path.join(ROOT, rel); if(!fs.existsSync(file)) return null;
  const src = fs.readFileSync(file,'utf8');
  const names = ['baseclass','ui','fs','poll','view','E','_','L','document','util','failover','routing','zapret','dns','autolearn'];
  const fn = new Function(...names, src);
  return fn(baseclass, ui, fsApi, poll, view, E, _, L, documentStub,
           deps.util, deps.failover, deps.routing, deps.zapret, deps.dns, deps.autolearn); }
const d = {};
d.util      = load('amnezia/util.js', d);
d.routing   = load('amnezia/section/routing.js', d);
d.zapret    = load('amnezia/section/zapret.js', d);
d.dns       = load('amnezia/section/dns.js', d);
d.autolearn = load('amnezia/section/autolearn.js', d);
d.failover  = load('amnezia/section/failover.js', d);
const main  = load('view/main.js', d);
// Execute every render() that exists → throws on undefined-symbol refs.
const panels = [];
for (const k of ['failover','routing','zapret','dns','autolearn']) {
  if (d[k] && typeof d[k].render === 'function') { const node = d[k].render({}, DATA); panels.push([k,node]); } }
function walk(n, fn){ if(!n||typeof n!=='object')return; fn(n); (n.children||[]).forEach(c=>walk(c,fn)); }
module.exports = { d, main, panels, walk, DATA };
if (require.main === module) {
  // Self-test mode: assert accordion invariants when all section modules exist.
  let details=[], badOpen=[];
  panels.forEach(([k,node])=>walk(node,n=>{ if(n.tag==='details'){ details.push(n);
    const cls=(n.attrs.class||''); const open=Object.prototype.hasOwnProperty.call(n.attrs,'open') && n.attrs.open!=null;
    if(cls.indexOf('amnezia-action')>=0 && open) badOpen.push(k); }}));
  if (badOpen.length) { console.error('FAIL: action panel open by default in '+badOpen.join(',')); process.exit(1); }
  console.log('harness ok: modules='+Object.keys(d).filter(k=>d[k]).length+' panels='+panels.length+' details='+details.length);
}
