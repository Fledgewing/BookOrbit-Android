const {prototypeURL, OUT}=require('../runtime.js');
// Walks Next across every focus stop on each Home page and in the reader panels (X4 Classic) and asserts the focused
// element looks visibly different from its unfocused self. Screenshots every step that lands on a dark (ink) element.
const {chromium}=require('playwright');
const O=OUT+'shots/focus/';
(async()=>{const b=await chromium.launch({executablePath:process.env.PWX});
const p=await b.newPage({viewport:{width:1500,height:1200}});const errs=[];p.on('pageerror',e=>errs.push(e.message));p.on('console',m=>{if(m.type()==='error')errs.push(m.text())});
await p.addInitScript(()=>{window.__noscale=1});
await p.goto(prototypeURL+'?dev=x4c');await p.waitForTimeout(200);
const H=x=>p.evaluate(x=>window.__proto.hw(x),x);const A=a=>p.evaluate(a=>window.__proto.act(a),a);
// Inspect the focused element: is it dark/ink, and does focus change its look?
const probe=()=>p.evaluate(()=>{const el=document.querySelector('#screen .kf');if(!el)return null;
 const sty=e=>{const c=getComputedStyle(e);return [c.backgroundColor,c.color,c.boxShadow,c.outlineStyle+c.outlineWidth+c.outlineColor,c.filter].join('|')};
 const on=sty(el);const cls=[...el.classList].filter(k=>/^kf|^inkbg$/.test(k));el.classList.remove(...cls);const off=sty(el);el.classList.add(...cls);
 const bgOff=off.split('|')[0];
 // dark = on an ink tile, a black control, a selected (black) segment, or a cover whose SVG is mostly dark
 const cov=el.querySelector('.cov svg rect, svg.cov rect, .cover svg rect')||(el.matches('[data-fk*="-b"]')&&el.querySelector('svg rect'));const covDark=!!cov&&(()=>{const r=cov;const f=(r.getAttribute('fill')||'').toLowerCase();const m=f.match(/^#([0-9a-f]{3}|[0-9a-f]{6})$/);if(!m)return false;const h=m[1].length===3?m[1].split('').map(x=>x+x).join(''):m[1];return parseInt(h.slice(0,2),16)<0x90;})();
 const seg=!!(el.parentElement&&el.parentElement.classList.contains('sg'));const segOn=seg&&el.classList.contains('on');
 const dark=!!el.closest('.tile.ink')||bgOff==='rgb(0, 0, 0)'||segOn||covDark;
 const c=getComputedStyle(el);const ring=/rgb\(0, 0, 0\)/.test(c.boxShadow)||c.outlineStyle!=='none'||c.filter!=='none';
 // dark things must change fill (white) or invert, and carry a black ring: a thin inset alone is not enough
 const strong=!dark||((c.backgroundColor==='rgb(255, 255, 255)'||c.filter.includes('invert'))&&ring)||(covDark&&/rgb\(0, 0, 0\)/.test(c.boxShadow)&&/rgb\(255, 255, 255\)/.test(c.boxShadow)&&!/inset/.test(c.boxShadow));
 // the ring must sit inside the tile for whole-tile targets: check the tile does not clip a ring drawn outside
 return {fk:el.dataset.fk,dark,strong,why:segOn?'segment':covDark?'cover':'ink',kind:cls.filter(k=>k.startsWith('kf-'))[0],differs:on!==off,on,off};});
let fails=0,n=0,darkN=0;const out=[];
async function walk(label,steps){const seen=new Set();for(let i=0;i<steps;i++){const r=await probe();if(!r)break;const key=r.fk;if(seen.has(key)&&i>2)break;seen.add(key);n++;
  if(!r.differs){fails++;out.push('FAIL no visible change '+label+' '+key);}
  if(!r.strong){fails++;out.push('FAIL weak focus on dark '+r.why+' '+label+' '+key+' '+r.on);}
  if(r.dark){darkN++;await p.locator('#screen').screenshot({path:O+label+'-'+String(i).padStart(2,'0')+'-'+key.replace(/[^a-z0-9-]/gi,'')+'.png'});out.push(label+' '+key+' dark('+r.why+') '+r.kind);}
  await H('next');}}
for(const pg of [0,1,2]){await A('page:'+pg);await p.evaluate(()=>{window.__proto.S.fk=null;window.__proto.render()});await H('prev');await H('next');
  // start on the page's first widget
  await walk('home'+(pg+1),40);}
await p.evaluate(()=>{const P=window.__proto,S=P.S;S.layouts.x4.push({name:'Hero sizes',tiles:[{w:'hero',x:0,y:0,cw:2,ch:3},{w:'hero',x:0,y:3,cw:2,ch:2},{w:'hero',x:0,y:5,cw:1,ch:2}]});S.page=S.layouts.x4.length-1;S.fk=null;P.render();});await H('prev');await H('next');await walk('herosizes',20);
await p.evaluate(()=>{const P=window.__proto;P.restart('x4c');P.openBook('b1');});await H('more');await walk('toppanel',30);
await H('back');await H('select');await walk('bottompanel',30);
await H('back');await H('more');await A('sheet:toc');await walk('toc',20);
await p.evaluate(()=>{const P=window.__proto;P.restart('x4c');P.openBook('b1');P.act('jump:341')});await walk('endofbook',20);
await p.evaluate(()=>{const P=window.__proto;P.restart('x4c');P.act('nav:recent');P.act('filter');P.act('fset:show:1');P.S.fk=null;P.render();});await H('prev');await H('next');await walk('filtersheet',30);
await p.evaluate(()=>{const P=window.__proto;P.act('lp:fsheet:1');P.S.fk=null;P.render();});await H('prev');await H('next');await walk('filtersheet2',30);
console.log(out.join('\n'));console.log('FOCUS steps',n,'dark',darkN,'fails',fails,'ERR',errs);await b.close();})();
