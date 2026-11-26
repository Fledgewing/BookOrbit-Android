const {prototypeURL, OUT}=require('../../runtime.js');
const {chromium}=require('playwright');
const O=OUT+'critic-shots/r3/';
(async()=>{const b=await chromium.launch({executablePath:process.env.PWX});
const p=await b.newPage({viewport:{width:1500,height:1200}});
await p.addInitScript(()=>{window.__noscale=1});
await p.goto(prototypeURL+'?dev=x4c');await p.waitForTimeout(200);
const H=x=>p.evaluate(x=>window.__proto.hw(x),x);
const fks=await p.evaluate(()=>{const a=[...document.querySelectorAll('#screen [data-fk]')].filter(e=>e.offsetParent).map(e=>e.dataset.fk);const d=a.filter((x,i)=>a.indexOf(x)!==i);return {all:a.join(' '),dups:d}});console.log(JSON.stringify(fks));
let seq=[];for(let i=0;i<40;i++){await H('next');seq.push(await p.evaluate(()=>window.__proto.S.page+':'+window.__proto.S.fk));}console.log(seq.join(' '));
await p.locator('#screen').screenshot({path:O+'x4c-loop.png'});
// prev direction
seq=[];for(let i=0;i<10;i++){await H('prev');seq.push(await p.evaluate(()=>window.__proto.S.page+':'+window.__proto.S.fk));}console.log('PREV',seq.join(' '));
await b.close();})();
