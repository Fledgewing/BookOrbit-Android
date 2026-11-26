const {prototypeURL, OUT}=require('../../runtime.js');
const {chromium}=require('playwright');const O=OUT+'critic-shots/r10/';
(async()=>{const b=await chromium.launch({executablePath:process.env.PWX});
for(const dev of ['m8c','x4c']){const p=await b.newPage({viewport:{width:1500,height:1200},deviceScaleFactor:dev==='m8c'?2:1});const errs=[];p.on('pageerror',e=>errs.push(e.message));
await p.addInitScript(()=>{window.__noscale=1});await p.goto(prototypeURL+'?dev='+dev);
const A=a=>p.evaluate(a=>__proto.act(a),a);const H=k=>p.evaluate(k=>__proto.hw(k),k);const scr=()=>p.evaluate(()=>document.querySelector('#screen').innerText.replace(/\s+/g,' '));
const kf=()=>p.evaluate(()=>document.querySelector('#screen .kf')?.dataset.fk);
await A('nav:settings');await A('setg:sync');let t=await scr();console.log(dev,'sync p1:',t.slice(0,140));
// change a setting below the mode to trigger 'Your own settings'
const acts=await p.evaluate(()=>[...document.querySelectorAll('#screen [data-act^="lp:"],#screen [data-act^="tg:"],#screen [data-act^="tog"]')].map(e=>e.getAttribute('data-act')).slice(0,6));console.log(' acts',acts);
if(acts[0]){await A(acts[0]);}
t=await scr();console.log(' after change:',t.match(/.{0,30}(Your own settings|Custom).{0,90}/g));
for(let i=0;i<4;i++){await A('lp:set_sync:1').catch(()=>{});}
let all='';for(let pg=0;pg<4;pg++){await p.evaluate(pg=>{__proto.S['pg_set_sync']=pg;__proto.render()},pg);all+=await scr();}
console.log(' reading pos:',all.match(/Reading position.{0,120}/g));
if(dev==='m8c'){await A('home');await A('nav:settings');await A('setg:reading');const before=await scr();await A('kocopy');const t1=await scr();console.log(' kocopy toast:',t1.match(/Copied.{0,40}/)?.[0],'| values:',t1.match(/Custom font.{0,200}/)?.[0]);
 await A('kocopyundo');const t2=await scr();console.log(' undo restored:',t2.match(/Custom font.{0,200}/)?.[0]===before.match(/Custom font.{0,200}/)?.[0],'focus',await kf());}
console.log(' errs',errs);await p.close();}
await b.close();})();
