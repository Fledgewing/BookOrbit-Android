const {prototypeURL, OUT}=require('../../runtime.js');
const {chromium}=require('playwright');const O=OUT+'critic-shots/r8/';
const dev=process.env.DEV||'x4c';
(async()=>{const b=await chromium.launch({executablePath:process.env.PWX});const p=await b.newPage({viewport:{width:1500,height:1200},deviceScaleFactor:dev==='m8c'?2:1});
const errs=[];p.on('pageerror',e=>errs.push(e.message));
await p.addInitScript(()=>{window.__noscale=1});await p.goto(prototypeURL+'?dev='+dev);
const H=k=>p.evaluate(k=>__proto.hw(k),k);const A=a=>p.evaluate(a=>__proto.act(a),a);
const W=ms=>p.waitForTimeout(ms);
const kf=()=>p.evaluate(()=>{const e=document.querySelector('#screen .kf');return e?e.dataset.fk+'«'+e.innerText.replace(/\s+/g,' ').trim().slice(0,40)+'»':'NONE'});
const txt=()=>p.evaluate(()=>{const m=document.querySelector('#screen .card:last-of-type')||document.querySelector('#screen');return document.querySelector('#screen').innerText.replace(/\s+/g,' ').slice(0,400)});
const modalTxt=()=>p.evaluate(()=>{const c=[...document.querySelectorAll('#screen .card')].pop();return c?c.innerText.replace(/\s+/g,' ').slice(0,500):'(no card)'});
const ring=async(n=25)=>{const s=[await kf()];for(let i=0;i<n;i++){await H('next');const k=await kf();if(k===s[0])break;s.push(k);}return s.map(x=>x.split('«')[0]).join(' > ');};
const setSel=(id,v)=>p.evaluate(([id,v])=>{const e=document.getElementById(id);e.value=v;e.dispatchEvent(new Event('change',{bubbles:true}));e.dispatchEvent(new Event('input',{bubbles:true}));},[id,v]);
const shot=n=>p.locator('#screen').screenshot({path:O+dev+'-'+n+'.png'});
const goTo=async fk=>{for(let i=0;i<30;i++){const k=await kf();if(k.startsWith(fk+'«')||(fk.startsWith('~')&&k.includes(fk.slice(1))))return true;await H('next');}console.log('!! cannot reach',fk,'at',await kf());return false;};
// ---- Round 7: update channel
await A('nav:settings');await A('setg:updates');console.log('UPD ring',await ring());
await goTo('set-chan');console.log('chan row',await kf());await H('select');console.log('picker',await modalTxt(),'| focus',await kf());await shot('chan-picker');
console.log('picker ring',await ring());
await H('next');const pk=await kf();await H('select');console.log('picked',pk,'-> focus',await kf(),'|',(await txt()).slice(0,200));
await H('select');await H('back');console.log('back from picker ->',await kf(),'modal',await p.evaluate(()=>__proto.S.modal&&__proto.S.modal.k));
// ---- Round 8: signed out
await setSel('acct','0');await A('home');await A('nav:settings');await W(100);
console.log('SETTINGS row', (await txt()).match(/Your server.{0,80}/)?.[0]);
await A('setg:account');await W(50);console.log('SO page',await txt());console.log('SO ring',await ring());await shot('signed-out');
for(const res of ['wrong','unreach','twostep','old','ok']){
  await setSel('sires',res);
  await A('home');await A('nav:settings');await A('setg:account');await W(50);
  await goTo('~Sign in to your server');
  const st=await kf();await H('select');await W(50);
  console.log('\n['+res+'] opened from',st,'->',await modalTxt(),'| focus',await kf());
  if(dev!=='m8c'){ // phone sheet
    console.log(' phone ring',await ring());
    await H('select');await W(50);console.log(' after select busy?',await modalTxt());await W(1100);
    console.log(' result:',await modalTxt(),'| focus',await kf());await shot('phone-'+res);
    console.log(' result ring',await ring());
  } else {
    console.log(' form ring (empty)',await ring());
    for(const k of ['si-server','si-user','si-pw']){await goTo(k);await H('select');await W(30);}
    console.log(' filled ring',await ring());
    await goTo('si-ok');await H('select');await W(50);console.log(' busy:',await modalTxt(),'focus',await kf());await W(1100);
    console.log(' result:',await modalTxt(),'| focus',await kf());await shot('form-'+res);console.log(' result ring',await ring());
  }
  await p.evaluate(()=>{__proto.S.modal=null});
}
console.log('errs',errs);await b.close();})();
