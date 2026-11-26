const {prototypeURL, OUT}=require('../../runtime.js');
const {chromium}=require('playwright');const O=OUT+'critic-shots/r8/';
const dev=process.env.DEV||'x4c';
(async()=>{const b=await chromium.launch({executablePath:process.env.PWX});const p=await b.newPage({viewport:{width:1500,height:1200},deviceScaleFactor:dev==='m8c'?2:1});
const errs=[];p.on('pageerror',e=>errs.push(e.message));
await p.addInitScript(()=>{window.__noscale=1});await p.goto(prototypeURL+'?dev='+dev);
const H=k=>p.evaluate(k=>__proto.hw(k),k);const A=a=>p.evaluate(a=>__proto.act(a),a);const W=ms=>p.waitForTimeout(ms);
const kf=()=>p.evaluate(()=>{const e=document.querySelector('#screen .kf');return e?e.dataset.fk+'«'+e.innerText.replace(/\s+/g,' ').trim().slice(0,30)+'»':'NONE'});
const card=()=>p.evaluate(()=>{const c=[...document.querySelectorAll('#screen .card')].pop();if(!c)return '(no card)';const r=c.getBoundingClientRect(),s=document.querySelector('#screen').getBoundingClientRect();return c.innerText.replace(/\s+/g,' ').slice(0,260)+` [card ${Math.round(r.top-s.top)}..${Math.round(r.bottom-s.top)} of ${Math.round(s.height)}]`});
const ring=async(n=25)=>{const s=[await kf()];for(let i=0;i<n;i++){await H('next');const k=await kf();if(k===s[0])break;s.push(k);}return s.map(x=>x.split('«')[0]).join(' > ');};
const setSel=(id,v)=>p.evaluate(([id,v])=>{const e=document.getElementById(id);e.value=v;e.dispatchEvent(new Event('change',{bubbles:true}));},[id,v]);
const shot=n=>p.locator('#screen').screenshot({path:O+dev+'-'+n+'.png'});
const goTo=async t=>{for(let i=0;i<30;i++){const k=await kf();if(k.startsWith(t+'«')||k.includes(t))return true;await H('next');}console.log('!! cannot reach',t,'at',await kf());return false;};
await setSel('acct','0');
const openForm=async()=>{await A('home');await A('nav:settings');await A('setg:account');await goTo('Sign in to your server');await H('select');await W(30);if(dev!=='m8c'){await goTo('si-type');await H('select');await W(30);}};
for(const res of ['wrong','unreach','twostep','old']){
  await setSel('sires',res);await openForm();
  console.log('\n['+res+'] form:',await card(),'| focus',await kf());console.log(' ring empty',await ring());
  for(const k of ['si-server','si-user','si-pw']){await goTo(k);await H('select');await W(20);}
  console.log(' ring filled',await ring());
  await goTo('si-ok');await H('select');await W(50);console.log(' busy',await kf(),'ring',await ring(4));await W(1100);
  console.log(' after:',await card(),'| focus',await kf());console.log(' ring',await ring());await shot('form-'+res);
  // recovery: set to ok and retry
  await setSel('sires','ok');
  if(res==='twostep'){await goTo('si-phone');await H('select');await W(30);console.log(' twostep->phone',await card(),await kf());await H('select');await W(1100);console.log(' retry:',(await card()).slice(0,60));}
  else{ if(res==='wrong'){await H('select');await W(20);} await goTo('si-ok');await H('select');await W(1100);console.log(' retry:',(await card()).slice(0,60));}
  await p.evaluate(()=>{__proto.S.modal=null;});await setSel('acct','0');
}
// signed-in state, sign out flow
await setSel('acct','1');await A('home');await A('nav:settings');await A('setg:account');await W(30);
console.log('\nSI ring',await ring());await goTo('Sign out');await H('select');await W(30);console.log('confirm',await card(),'focus',await kf());
await H('select');console.log('stay ->',await kf(),await p.evaluate(()=>__proto.S.modal));
await goTo('Sign out');await H('select');await H('next');console.log('on',await kf());await H('select');await W(30);
console.log('after signout page:',(await p.evaluate(()=>document.querySelector('#screen').innerText.replace(/\s+/g,' '))).slice(0,200),'focus',await kf());
await goTo('Sign in again');
console.log('errs',errs);await b.close();})();
