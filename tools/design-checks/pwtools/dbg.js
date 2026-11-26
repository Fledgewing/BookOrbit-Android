const {prototypeURL, OUT}=require('../runtime.js');
const {chromium}=require('playwright');

(async()=>{const b=await chromium.launch({executablePath:process.env.PWX});
for (const dev of ['x4c','m8c']){
const p=await b.newPage({viewport:{width:1500,height:1150}});
await p.goto(prototypeURL+'?dev='+dev);await p.waitForTimeout(150);
console.log(dev, await p.evaluate(()=>[document.querySelector('.kf')?.dataset.fk, window.__proto.S.fk]));
console.log(await p.evaluate(()=>{const out=[];const sc=document.querySelector('#screen').getBoundingClientRect();document.querySelectorAll('#screen *').forEach(e=>{const r=e.getBoundingClientRect();if(r.width&&(r.right>sc.right+1||r.left<sc.left-1))out.push(e.outerHTML.slice(0,140)+' R'+Math.round(r.right-sc.right));});return out.slice(0,6)}));
await p.evaluate(()=>window.__proto.openBook('b1'));await p.evaluate(()=>window.__proto.act('rd:bottom'));
console.log(await p.evaluate(()=>[getComputedStyle(document.querySelector('.ptext')).fontSize, document.querySelector('.ptext').style.fontSize, window.__proto.S.rs.size]));
await p.evaluate(()=>window.__proto.act('cyc:size:1:6'));
console.log(await p.evaluate(()=>[document.querySelector('.ptext').style.fontSize, window.__proto.S.rs.size]));
await p.close();}
await b.close();})();
