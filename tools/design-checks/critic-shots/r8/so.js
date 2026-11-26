const {prototypeURL, OUT}=require('../../runtime.js');
const {chromium}=require('playwright');const O=OUT+'critic-shots/r8/';
(async()=>{const b=await chromium.launch({executablePath:process.env.PWX});
for(const dev of ['m8c','x4c']){const p=await b.newPage({viewport:{width:1500,height:1200},deviceScaleFactor:dev==='m8c'?2:1});
await p.addInitScript(()=>{window.__noscale=1});await p.goto(prototypeURL+'?dev='+dev);
const setSel=(id,v)=>p.evaluate(([id,v])=>{const e=document.getElementById(id);e.value=v;e.dispatchEvent(new Event('change',{bubbles:true}));},[id,v]);
const A=a=>p.evaluate(a=>__proto.act(a),a);const H=k=>p.evaluate(k=>__proto.hw(k),k);
await setSel('acct','0');await A('home');
const hdr=await p.evaluate(()=>document.querySelector('#screen').innerText.split('\n').slice(0,4).join(' | '));console.log(dev,'home header signed out:',hdr);
const sy=await p.evaluate(()=>{const e=document.querySelector('#screen [data-fk=h-sync]');return e?e.getAttribute('data-act'):null});console.log(' h-sync act',sy);
if(sy){await A(sy);await p.waitForTimeout(300);console.log(' after sync:',await p.evaluate(()=>({modal:__proto.S.modal&&__proto.S.modal.k,toast:(document.querySelector('#screen .toast')||{}).innerText,hdr:document.querySelector('#screen').innerText.split('\n').slice(0,3).join(' | ')})));await p.locator('#screen').screenshot({path:O+dev+'-so-sync.png'});}
// reader top panel sync when signed out
await p.evaluate(()=>{__proto.S.modal=null});await A('home');await p.evaluate(()=>__proto.openBook(Object.keys(__proto.S).length&&'b1'));await A('rd:top');
console.log(' reader top:',await p.evaluate(()=>{const e=document.querySelector('#screen [data-fk=tp-sync]');return e?e.innerText.replace(/\s+/g,' '):'(no tp-sync)'}));
// busy + back
await setSel('sires','ok');await A('home');await A('nav:settings');await A('setg:account');await A('modal:sicode');await A('sicheck');await H('back');
console.log(' back during busy -> modal',await p.evaluate(()=>__proto.S.modal&&[__proto.S.modal.k,__proto.S.modal.busy]));await p.waitForTimeout(1100);console.log(' then',await p.evaluate(()=>__proto.S.modal&&__proto.S.modal.k));
await p.close();}
await b.close();})();
