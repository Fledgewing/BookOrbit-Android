const {prototypeURL, OUT}=require('../../runtime.js');
const {chromium}=require('playwright');
const O=OUT+'critic-shots/r5/';
(async()=>{const b=await chromium.launch({executablePath:process.env.PWX});
const dev=process.env.DEV||'x4c';const sz={width:1500,height:1200};
const p=await b.newPage({viewport:sz,deviceScaleFactor:dev==='m8c'?2:1});
await p.addInitScript(()=>{window.__noscale=1});
await p.goto(prototypeURL+'?dev='+dev);
const dump=async(tag)=>{const r=await p.evaluate(()=>{const card=document.querySelector('.fsheet');const cr=card.getBoundingClientRect();
 return {title:card.querySelector('b')?.innerText,rows:[...card.querySelectorAll('[data-fk]')].map(e=>{const r=e.getBoundingClientRect();return e.dataset.fk+'@'+Math.round(r.top-cr.top)+'+'+Math.round(r.height)+(r.bottom>cr.bottom+1?'!OUT':'')+' '+e.innerText.replace(/\s+/g,' ').trim().slice(0,45)}),fk:__proto.S.fk,kf:document.querySelector('.kf')?.dataset.fk}});console.log('==',tag,JSON.stringify(r,null,0));};
for(const [ctx,a] of [['recent','nav:recent'],['library','nav:library'],['search','search']]){
 await p.evaluate(a=>{__proto.S.modal=null;__proto.act('home');__proto.act(a);__proto.act('filter');},a);
 for(const k of ['show','where','authors','series','tags','len','rate','added','gs']){
  const ok=await p.evaluate(k=>{if(!document.querySelector('[data-fk="f-'+k+'"]'))return false;__proto.act('fpickopen:'+k);return true},k);
  if(!ok)continue; if(process.env.Q)await dump(ctx+' '+k); await p.locator('#screen').screenshot({path:O+`${dev}-${ctx}-pick-${k}.png`});
  await p.evaluate(()=>__proto.act('fpickdone'));
 }}
await b.close();})();
