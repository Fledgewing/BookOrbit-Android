const {prototypeURL, OUT}=require('../../runtime.js');
const {chromium}=require('playwright');const O=OUT+'critic-shots/r5/';
(async()=>{const b=await chromium.launch({executablePath:process.env.PWX});
for(const dev of ['x4c','m8c']){const p=await b.newPage({viewport:{width:1500,height:1200},deviceScaleFactor:dev==='m8c'?2:1});
await p.addInitScript(()=>{window.__noscale=1});await p.goto(prototypeURL+'?dev='+dev);
const rows=()=>p.evaluate(()=>[...document.querySelectorAll('.fsheet [data-fk^=fp-]')].map(e=>e.dataset.fk+'|'+e.innerText.replace(/\s+/g,' ').trim()+'|'+getComputedStyle(e.querySelector('.ell')||e).color));
await p.evaluate(()=>{__proto.act('nav:library');__proto.act('filter')});
console.log(dev,'lib apply',await p.evaluate(()=>document.querySelector('[data-fk=f-apply]').innerText), await p.evaluate(()=>document.querySelector('#screen').innerText.slice(0,60).replace(/\s+/g,' ')));
await p.evaluate(()=>{__proto.S.modal=null;__proto.act('home');__proto.act('nav:recent');__proto.act('filter');__proto.act('fpickopen:authors');__proto.act('fpick:Caspian Moore');__proto.act('fpickdone');__proto.act('fpickopen:len');__proto.act('fone:len:1');__proto.act('fpickopen:authors')});
console.log(dev,'ticked+short',JSON.stringify(await rows()));
await p.locator('#screen').screenshot({path:O+dev+'-r6-author-zero.png'});
await p.evaluate(()=>{__proto.act('fpickdone');__proto.act('fpickopen:series')});
await p.locator('#screen').screenshot({path:O+dev+'-r6-series-zero.png'});
await p.close();}
await b.close();})();
