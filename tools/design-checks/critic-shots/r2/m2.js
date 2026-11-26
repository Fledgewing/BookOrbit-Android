const {prototypeURL, OUT}=require('../../runtime.js');
const {chromium}=require('playwright');

const DEV=process.env.DEV||'m8c';
(async()=>{const b=await chromium.launch({executablePath:process.env.PWX});
const p=await b.newPage({viewport:{width:1500,height:1200}});const errs=[];p.on('pageerror',e=>errs.push(e.message));p.on('console',m=>{if(m.type()==='error')errs.push(m.text())});
await p.addInitScript(()=>{window.__noscale=1});
await p.goto(prototypeURL+'?dev='+DEV);await p.waitForTimeout(200);
const A=a=>p.evaluate(a=>window.__proto.act(a),a);
const meas=async(label)=>{await p.waitForTimeout(30);const r=await p.evaluate(()=>{
 const items=[...document.querySelectorAll('#screen [data-act],#screen [data-book]')].filter(e=>e.offsetParent).map(e=>{const r=e.getBoundingClientRect();return [e.dataset.act||('book '+e.dataset.book),Math.round(r.width),Math.round(r.height),(e.innerText||'').trim().replace(/\s+/g,' ').slice(0,24)]});
 // overflow: elements whose content is clipped
 const ov=[...document.querySelectorAll('#screen *')].filter(e=>e.offsetParent&&e.children.length===0&&(e.innerText||'').trim()&&(e.scrollWidth>e.clientWidth+1)&&getComputedStyle(e).textOverflow!=='ellipsis').map(e=>(e.innerText||'').trim().slice(0,30)+' ['+e.scrollWidth+'>'+e.clientWidth+']');
 return {items,ov}});
 const small=r.items.filter(i=>Math.min(i[1],i[2])<50);console.log('==',label,'small',small.length,'/',r.items.length, 'overflow',r.ov.length);small.forEach(i=>console.log('   S',i.join(' | ')));r.ov.slice(0,6).forEach(o=>console.log('   O',o));};
await meas('home1');await A('page:1');await meas('home2');if(DEV!=='m8c'){await A('page:2');await meas('home3');}await A('page:0');
await A('book:b10');await p.waitForTimeout(450);await meas('downloading');await p.waitForTimeout(4000);
await p.evaluate(d=>window.__proto.restart(d),DEV);
await A('details:b1');await meas('details');await A('series:tide');await meas('series');await A('home');
await A('nav:reading');await meas('reading');await A('grp:2');await meas('reading-series');await A('home');
await A('scope:s1');await meas('list');await A('grp:1');await meas('list-author');await A('home');
await A('search');await A('sq:calder');await meas('search');await A('home');
await A('actions:b1');await meas('actions');await A('closeModal');
await A('menu');await meas('menu');await A('closeModal');
await A('nav:settings');await meas('settings');for(const g of ['account','sync','library','reading','home','sleep','power','updates','about']){await A('setg:'+g);await meas('set-'+g);await A('back');}
await A('home');await A('nav:battery');for(const t of [0,1,2,3]){await A('tab:'+t);await meas('battery-'+t);}
await A('home');await A('nav:storage');await meas('storage');await A('home');
await A('menu');await A('m:edit');await meas('edit-none');await A('sel:3');await meas('edit-sel-booklist');await A('cfg');await meas('configure');await A('closeModal');await A('editDone');
await p.evaluate(()=>window.__proto.openBook('b1'));await A('rd:top');await meas('top');await A('rd:close');await A('rd:bottom');await meas('bottom');await A('sheet:goto');await meas('goto');await A('sheet:search');await meas('bsearch');await A('sheet:info');await meas('info');
console.log('ERR',errs);await b.close();})();
