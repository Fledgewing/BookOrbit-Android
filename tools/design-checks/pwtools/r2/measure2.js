const {prototypeURL, OUT}=require('../../runtime.js');
const {chromium}=require('playwright');

const DEVV=process.env.DEV||'m8c';(async()=>{const b=await chromium.launch({executablePath:process.env.PWX});
const p=await b.newPage({viewport:{width:1500,height:1200}});
await p.addInitScript(()=>{window.__noscale=1});
await p.goto(prototypeURL+'?dev='+(process.env.DEV||'m8c')+'');await p.waitForTimeout(200);
const A=a=>p.evaluate(a=>window.__proto.act(a),a);
const meas=async(label)=>{const r=await p.evaluate(()=>{const sc=document.querySelector('#screen').getBoundingClientRect();return {sw:sc.width,items:[...document.querySelectorAll('#screen [data-act]')].filter(e=>e.offsetParent).map(e=>{const r=e.getBoundingClientRect();return [e.dataset.act,Math.round(r.width),Math.round(r.height),(e.innerText||'').trim().slice(0,20)]})}});
 const small=r.items.filter(i=>Math.min(i[1],i[2])<50);console.log('==',label,'screen w',r.sw,'small:',small.length,'/',r.items.length);small.forEach(i=>console.log('  ',i.join(' | ')));};
await meas('home1');await A('page:1');await meas('home2');await A('page:0');
await p.evaluate(()=>window.__proto.openBook('b1'));await A('rd:top');await meas('top');await A('rd:close');await A('rd:bottom');await meas('bottom');
await A('sheet:toc');await meas('toc');await A('sheet:marks');await meas('marks');await A('jump:341');await meas('end');
await p.evaluate(d=>window.__proto.restart(d),DEVV);await A('menu');await A('m:edit');await A('sel:0');await meas('edit');await A('editDone');await A('nav:settings');await meas('settings');for(const g of ['account','sync','library','reading','home','sleep','power','updates','about']){await A('setg:'+g);await meas('set-'+g);await A('back');}await A('nav:battery');await meas('battery');await A('tab:2');await meas('battery-daily');await A('home');await A('nav:storage');await meas('storage');await A('home');await A('page:1');await meas('home2b');await A('page:2');await meas('home3');
await b.close();})();
