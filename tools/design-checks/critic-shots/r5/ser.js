const {prototypeURL, OUT}=require('../../runtime.js');
const {chromium}=require('playwright');
(async()=>{const b=await chromium.launch({executablePath:process.env.PWX});const p=await b.newPage({viewport:{width:1500,height:1200}});
await p.addInitScript(()=>{window.__noscale=1});await p.goto(prototypeURL+'?dev=x4c');
await p.evaluate(()=>{__proto.act('nav:recent');__proto.act('filter');__proto.act('fpickopen:series')});
const s=[];for(let i=0;i<6;i++){await p.evaluate(()=>__proto.hw('next'));s.push(await p.evaluate(()=>document.querySelector('#screen .kf')?.dataset.fk));}console.log('series walk',s.join(' > '));
await p.evaluate(()=>{__proto.act('fpickdone');__proto.act('fpickopen:authors')});
const t=[];for(let i=0;i<12;i++){await p.evaluate(()=>__proto.hw('next'));t.push(await p.evaluate(()=>document.querySelector('#screen .kf')?.dataset.fk));}console.log('author walk',t.join(' > '));
await b.close();})();
