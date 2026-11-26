const {prototypeURL, OUT}=require('../../runtime.js');
const {chromium}=require('playwright');const O=OUT+'critic-shots/r8/';
(async()=>{const b=await chromium.launch({executablePath:process.env.PWX});
for(const dev of ['m8c','x4pro','x4c']){const p=await b.newPage({viewport:{width:1500,height:1200},deviceScaleFactor:dev==='m8c'?2:1});
await p.addInitScript(()=>{window.__noscale=1});await p.goto(prototypeURL+'?dev='+dev);
const setSel=(id,v)=>p.evaluate(([id,v])=>{const e=document.getElementById(id);e.value=v;e.dispatchEvent(new Event('change',{bubbles:true}));},[id,v]);
const H=k=>p.evaluate(k=>__proto.hw(k),k);const A=a=>p.evaluate(a=>__proto.act(a),a);
await setSel('acct','0');
const n=await p.evaluate(()=>__proto.S.layouts[Object.keys(__proto.S.layouts).find(k=>k===( (location.search.includes('m8c'))?'m8c':'x4'))].length);
for(let pg=0;pg<n;pg++){await A('page:'+pg);
 const r=await p.evaluate(()=>{const out=[];const all=[...document.querySelectorAll('#screen *')].filter(e=>e.children.length===0&&/This reader only/.test(e.textContent));
  for(const e of all){const t=e.closest('[data-fk]')||e.parentElement.parentElement;const er=e.getBoundingClientRect(),tr=t.getBoundingClientRect();
   const sibs=[...t.querySelectorAll('*')].filter(x=>x!==e&&!x.contains(e)&&!e.contains(x)&&x.children.length===0&&x.textContent.trim()).filter(x=>{const r=x.getBoundingClientRect();return r.width&&!(r.right<=er.left||r.left>=er.right||r.bottom<=er.top||r.top>=er.bottom)}).map(x=>x.textContent.trim().slice(0,20));
   out.push({fk:t.dataset.fk,w:Math.round(tr.width),in:er.left>=tr.left-1&&er.right<=tr.right+1&&er.top>=tr.top-1&&er.bottom<=tr.bottom+1,clip:e.scrollWidth>e.clientWidth+1,overlap:sibs});}
  const bat=[...document.querySelectorAll('#screen [data-fk=bat-open]')].map(e=>/This reader only/.test(e.innerText));return {out,bat};});
 if(r.out.length||r.bat.length)console.log(dev,'page',pg,JSON.stringify(r));
 await p.locator('#screen').screenshot({path:O+dev+'-so-page'+pg+'.png'});}
// signed in: no labels
await setSel('acct','1');let tot=0;for(let pg=0;pg<n;pg++){await A('page:'+pg);tot+=await p.evaluate(()=>(document.querySelector('#screen').innerText.match(/This reader only/g)||[]).length);}console.log(dev,'signed-in labels',tot);
// names scan over sign-in sheets
await setSel('acct','0');const bad=/bookorbit|grimmory|tailscale|tailnet|calibre|kavita|komga|booklore|kosync|192\.168/i;const texts=[];
for(const res of ['ok','wrong','unreach','twostep','old']){await setSel('sires',res);await A('home');await A('nav:settings');await A('setg:account');texts.push(await p.evaluate(()=>document.querySelector('#screen').innerText));
 await A('modal:signin');texts.push(await p.evaluate(()=>document.querySelector('#screen').innerText));await A('modal:sicode');texts.push(await p.evaluate(()=>document.querySelector('#screen').innerText));await p.evaluate(()=>{__proto.S.modal=null});}
await setSel('acct','1');await A('home');await A('nav:settings');texts.push(await p.evaluate(()=>document.querySelector('#screen').innerText));await A('setg:account');texts.push(await p.evaluate(()=>document.querySelector('#screen').innerText));
console.log(dev,'names hits',texts.join('\n').split('\n').filter(l=>bad.test(l)));
await p.close();}
await b.close();})();
