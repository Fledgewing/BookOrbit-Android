const {prototypeURL, OUT}=require('../../runtime.js');
const {chromium}=require('playwright');
const O=OUT+'critic-shots/r5/';
(async()=>{const b=await chromium.launch({executablePath:process.env.PWX});
for(const dev of ['m8c','x4pro','x4c']){
const p=await b.newPage({viewport:{width:1500,height:1200},deviceScaleFactor:dev==='m8c'?2:1});
await p.addInitScript(()=>{window.__noscale=1});await p.goto(prototypeURL+'?dev='+dev);
// find battery tiles on all home pages
const r=await p.evaluate(()=>{const out=[];for(let pg=0;pg<6;pg++){__proto.act('page:'+pg);document.querySelectorAll('#screen .batleft').forEach(e=>{const t=e.closest('[data-fk]');const r=e.getBoundingClientRect();const tr=t?t.getBoundingClientRect():r;out.push({pg,fk:t&&t.dataset.fk,txt:e.innerText,w:Math.round(r.width),sw:e.scrollWidth,cw:e.clientWidth,tileW:Math.round(tr.width),tileH:Math.round(tr.height),overR:Math.round(r.right-tr.right)})});}return out});
console.log(dev,'home',JSON.stringify(r));
await p.evaluate(()=>{__proto.act('home');__proto.act('nav:battery')});
console.log(dev,'batpage',(await p.locator('#screen').innerText()).replace(/\s+/g,' ').match(/.{0,40}usual use.{0,60}/g));
await p.locator('#screen').screenshot({path:O+dev+'-batpage.png'});
await p.close();}
await b.close();})();
