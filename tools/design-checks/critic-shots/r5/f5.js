const {prototypeURL, OUT}=require('../../runtime.js');
const {chromium}=require('playwright');
const O=OUT+'critic-shots/r5/';
(async()=>{const b=await chromium.launch({executablePath:process.env.PWX});
for(const dev of ['m8c','x4pro','x4c']){
 const sz=dev==='m8c'?{width:702,height:936}:{width:480,height:800};
 const p=await b.newPage({viewport:sz,deviceScaleFactor:dev==='m8c'?2:1});
 await p.addInitScript(()=>{window.__noscale=1});
 await p.goto(prototypeURL+'?dev='+dev);
 const ctxs=[['recent',"nav:recent"],['library',"nav:library"],['reading',"nav:reading"],['wtr','nav:wtr'],['search','search'],['authors','nav:authors'],['device','nav:device']];
 for(const [nm,a] of ctxs){
  await p.evaluate(a=>{__proto.S.modal=null;__proto.act('home');__proto.act(a);__proto.act('filter');},a);
  const info=await p.evaluate(()=>{const card=document.querySelector('.fsheet');if(!card)return 'NOSHEET';const cr=card.getBoundingClientRect();
   const rows=[...card.querySelectorAll('[data-fk]')].map(e=>{const r=e.getBoundingClientRect();return [e.dataset.fk,Math.round(r.top),Math.round(r.height),e.innerText.replace(/\s+/g,' ').trim().slice(0,50)]});
   const clip=[...card.querySelectorAll('*')].filter(e=>e.children.length==0&&e.scrollWidth>e.clientWidth+1&&getComputedStyle(e).overflow!='visible').map(e=>e.innerText.slice(0,30));
   const out=[...card.querySelectorAll('[data-fk]')].filter(e=>{const r=e.getBoundingClientRect();return r.bottom>cr.bottom+1||r.top<cr.top-1}).map(e=>e.dataset.fk);
   return {card:[Math.round(cr.top),Math.round(cr.bottom)],rows,clip,out,pager:!!card.querySelector('[data-fk^=pg],[data-act^=pg]')}});
  console.log(dev,nm,JSON.stringify(info));
  await p.screenshot({path:O+`${dev}-${nm}-sheet.png`});
 }
 await p.close();}
await b.close();})();
