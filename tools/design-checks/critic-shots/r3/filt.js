const {prototypeURL, OUT}=require('../../runtime.js');
const {chromium}=require('playwright');
const O=OUT+'critic-shots/r3/';
(async()=>{const b=await chromium.launch({executablePath:process.env.PWX});
const p=await b.newPage({viewport:{width:1500,height:1200},deviceScaleFactor:2});const errs=[];p.on('pageerror',e=>errs.push(e.message));p.on('console',m=>{if(m.type()==='error')errs.push(m.text())});
await p.addInitScript(()=>{window.__noscale=1});
await p.goto(prototypeURL+'?dev=x4c');await p.waitForTimeout(200);
const H=x=>p.evaluate(x=>window.__proto.hw(x),x);const A=a=>p.evaluate(a=>window.__proto.act(a),a);
const fk=()=>p.evaluate(()=>window.__proto.S.fk);const st=()=>p.evaluate(()=>{const S=window.__proto.S;const c=S.stack[S.stack.length-1];return JSON.stringify({scr:c.n,modal:S.modal&&S.modal.k,fk:S.fk,f:c.f||c.filter||null})});
const goTo=async(t,max=60)=>{for(let i=0;i<max;i++){if(await fk()===t)return true;await H('next');}return false};
const clip=async(name)=>{const box=await p.evaluate(()=>{const e=document.querySelector('#screen .kf');if(!e)return null;const r=e.getBoundingClientRect();return {x:r.x-14,y:r.y-14,width:r.width+28,height:r.height+28}});if(box)await p.screenshot({path:O+'dk-'+name+'.png',clip:box});};
const fks=()=>p.evaluate(()=>[...document.querySelectorAll('#screen [data-fk]')].filter(e=>e.offsetParent).map(e=>e.dataset.fk).join(' '));
// where are filter buttons? list, search, reading, scope list, configure sheet
for(const [lab,nav] of [['recent','nav:recent'],['reading','nav:reading'],['scope','scope:s1'],['library','nav:library'],['search','search']]){await A('home');await A(nav);const f=await fks();console.log(lab,'has filter fk:',(f.match(/\S*filter\S*/g)||[]).join(','));}
await A('home');await A('nav:recent');console.log(await goTo('s-filter'));await H('select');console.log('open',await st());
await p.locator('#screen').screenshot({path:O+'x4c-filter-open.png'});
let seq=[];for(let i=0;i<24;i++){const k=await fk();seq.push(k);if(/^f-show|^f-go|^f-apply|show/i.test(k||''))await clip('f-'+k);await H('next');}console.log('FILTER NEXT',seq.join(' '));
// try selecting Unread
console.log(await goTo(seq.find(x=>/unread|show-1|sh-1/i.test(x||''))||'zz',30));await H('select');console.log('after select',await st());
await p.locator('#screen').screenshot({path:O+'x4c-filter-sel.png'});
console.log('ERR',errs);await b.close();})();
