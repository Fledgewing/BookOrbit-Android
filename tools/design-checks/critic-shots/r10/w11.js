const {prototypeURL, OUT}=require('../../runtime.js');
const {chromium}=require('playwright');const O=OUT+'critic-shots/r10/';
(async()=>{const b=await chromium.launch({executablePath:process.env.PWX});
for(const dev of ['m8c','x4c']){const p=await b.newPage({viewport:{width:1500,height:1200},deviceScaleFactor:dev==='m8c'?2:1});
await p.addInitScript(()=>{window.__noscale=1});await p.goto(prototypeURL+'?dev='+dev);
const A=a=>p.evaluate(a=>__proto.act(a),a);const H=k=>p.evaluate(k=>__proto.hw(k),k);const scr=()=>p.evaluate(()=>document.querySelector('#screen').innerText.replace(/\s+/g,' '));
const kf=()=>p.evaluate(()=>{const e=document.querySelector('#screen .kf');return e?e.dataset.fk+'«'+e.innerText.replace(/\s+/g,' ').slice(0,60)+'»':'NONE'});
await A('nav:settings');await A('setg:sync');
for(let i=0;i<40;i++){const k=await kf();if(/Reading position/.test(k))break;await H('next');}
console.log(dev,'pos row:',await kf());await H('select');console.log(' after select:',await kf());await H('next');
// change sleep row etc to trigger own settings
for(let i=0;i<40;i++){const k=await kf();if(/Sleep after/.test(k))break;await H('next');}await H('select');console.log(' changed',await kf());
for(let i=0;i<40;i++){const k=await kf();if(/^(lp-|set-mode|back)/.test(k)&&/Back|mode/i.test(k))break;await H('prev');}
const all=await scr();console.log(' mode card:',all.match(/.{0,20}(Your own settings).{0,120}/)?.[0]||all.slice(60,300));
await p.locator('#screen').screenshot({path:O+dev+'-sync-own.png'});await p.close();}
await b.close();})();
