const {prototypeURL, OUT}=require('../../runtime.js');
const {chromium}=require('playwright');const O=OUT+'critic-shots/r9/';
(async()=>{const b=await chromium.launch({executablePath:process.env.PWX});const p=await b.newPage({viewport:{width:1500,height:1200}});
await p.addInitScript(()=>{window.__noscale=1});await p.goto(prototypeURL+'?dev=x4c');
const A=a=>p.evaluate(a=>__proto.act(a),a);const set=(id,v)=>p.evaluate(([id,v])=>{const e=document.getElementById(id);e.value=v;e.dispatchEvent(new Event('change',{bubbles:true}));},[id,v]);
const card=()=>p.evaluate(()=>{const c=[...document.querySelectorAll('#screen .card')].pop();const s=document.querySelector('#screen').getBoundingClientRect(),r=c.getBoundingClientRect();return c.innerText.replace(/\s+/g,' ')+` [${Math.round(r.top-s.top)}..${Math.round(r.bottom-s.top)}/${Math.round(s.height)}]`});
for(const [w,res] of [['sync','wrong'],['opds','unreach'],[null,'wrong'],[null,'unreach'],[null,'old']]){
 await set('acct','none');await set('sires',res);await p.evaluate(()=>{__proto.S.modal=null});await A('home');await A('nav:settings');await A('setg:account');
 await A(w?'lopen:'+w:'modal:sicode');await A('sicheck');await p.waitForTimeout(1100);
 console.log(w||'account',res,'::',(await card()).replace(/Typing a password.*?minutes\./,'…'));await p.locator('#screen').screenshot({path:O+`x4c-ph-${w||'acct'}-${res}.png`});}
// no-OPDS download
await set('acct','0');await set('olog','none');await A('home');await A('nav:library');
const ids=await p.evaluate(()=>[...document.querySelectorAll('#screen [data-act^="book:"]')].map(e=>e.getAttribute('data-act')));
for(const a of ids){await A(a);await p.waitForTimeout(50);const t=await p.evaluate(()=>(document.querySelector('#screen .toast')||{}).innerText||'');const c=await p.evaluate(()=>{const c=[...document.querySelectorAll('#screen .card')].pop();return c?c.innerText.replace(/\s+/g,' ').slice(0,160):''});if(/OPDS|download/i.test(t+c)){console.log('no-opds tap',a,'::',t,'|',c);await p.locator('#screen').screenshot({path:O+'x4c-no-opds.png'});break;}await p.evaluate(()=>{__proto.S.modal=null});await A('home');await A('nav:library');}
await b.close();})();
