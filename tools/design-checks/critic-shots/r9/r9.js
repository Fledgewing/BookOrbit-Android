const {prototypeURL, OUT}=require('../../runtime.js');
const {chromium}=require('playwright');const O=OUT+'critic-shots/r9/';
const dev=process.env.DEV||'x4c';
(async()=>{const b=await chromium.launch({executablePath:process.env.PWX});const p=await b.newPage({viewport:{width:1500,height:1200},deviceScaleFactor:dev==='m8c'?2:1});
const errs=[];p.on('pageerror',e=>errs.push(e.message));
await p.addInitScript(()=>{window.__noscale=1});await p.goto(prototypeURL+'?dev='+dev);
const H=k=>p.evaluate(k=>__proto.hw(k),k);const A=a=>p.evaluate(a=>__proto.act(a),a);const W=ms=>p.waitForTimeout(ms);
const kf=()=>p.evaluate(()=>{const e=document.querySelector('#screen .kf');return e?e.dataset.fk+'«'+e.innerText.replace(/\s+/g,' ').trim().slice(0,28)+'»':'NONE'});
const scr=()=>p.evaluate(()=>document.querySelector('#screen').innerText.replace(/\s+/g,' '));
const card=()=>p.evaluate(()=>{const c=[...document.querySelectorAll('#screen .card')].pop();return c?c.innerText.replace(/\s+/g,' '):'(no card)'});
const set=(id,v)=>p.evaluate(([id,v])=>{const e=document.getElementById(id);e.value=v;e.dispatchEvent(new Event('change',{bubbles:true}));},[id,v]);
const shot=n=>p.locator('#screen').screenshot({path:O+dev+'-'+n+'.png'});
const goTo=async t=>{for(let i=0;i<40;i++){const k=await kf();if(k.startsWith(t+'«')||k.includes(t))return true;await H('next');}console.log('   !! cannot reach',t,'at',await kf());return false;};
const ring=async(n=25)=>{const s=[await kf()];for(let i=0;i<n;i++){await H('next');const k=await kf();if(k===s[0])break;s.push(k);}return s.map(x=>x.split('«')[0]).join(' > ');};
const server=async()=>{await p.evaluate(()=>{__proto.S.modal=null});await A('home');await A('nav:settings');await A('setg:account');await W(30);};
const state=async(acct,sl,ol)=>{await set('acct',acct);if(sl)await set('slog',sl);if(ol)await set('olog',ol);};
const homeStatus=async()=>{await p.evaluate(()=>{__proto.S.modal=null});await A('home');return (await scr()).slice(0,70);};
const top=async()=>{await A('home');const a=await p.evaluate(()=>document.querySelector('#screen [data-fk=hero-resume]')?.getAttribute('data-act'));await A(a);await A('rd:top');const t=await p.evaluate(()=>{const e=document.querySelector('#screen [data-fk=tp-sync]');return e?e.innerText.replace(/\s+/g,' ')+'|'+e.getAttribute('data-act'):'(no tp-sync)'});await A('rd:close').catch(()=>{});return t;};
const syncGrp=async()=>{await A('home');await A('nav:settings');const s=(await scr()).match(/Sync, Wi-Fi & power.{0,60}/)?.[0];await A('setg:sync');const t=(await scr()).slice(0,260);return s+' || '+t;};
await set('sires','ok');
for(const [nm,acct,sl,ol] of [['S1 account-only','1','acct','acct'],['S2 own-sync+account','1','user','acct'],['S3 own-both+account','1','user','user']]){
  await state(acct,sl,ol);await server();console.log('\n#',nm,'| page:',(await scr()).slice(0,420));
  await goTo('set-out');await H('select');await W(30);console.log(' confirm:',await card(),'| focus',await kf());
  await H('select');console.log(' Stay ->',await kf());
  await H('select');await H('back');console.log(' Back from question ->',await kf(),'modal',await p.evaluate(()=>__proto.S.modal&&__proto.S.modal.k));
  await H('select');await goTo('so-ok');await H('select');await W(30);console.log(' after signout:',(await scr()).slice(0,330),'| focus',await kf());await shot(nm.split(' ')[0]+'-after');
  console.log(' home:',await homeStatus());console.log(' top:',await top());console.log(' syncgrp:',await syncGrp());
}
// Nothing set up: home link
await state('none');console.log('\n# Nothing set up home:',await homeStatus());
const hs=await p.evaluate(()=>{const e=document.querySelector('#screen [data-fk=h-sync]');return e&&[e.innerText,e.getAttribute('data-act')]});console.log(' h-sync',hs);
if(hs){await A(hs[1]);console.log(' -> ',(await scr()).slice(0,120));}
console.log(' top:',await top());console.log(' sync grp:',await syncGrp());
// download a server-only book without OPDS
await A('home');await A('nav:recent');const sb=await p.evaluate(()=>{const e=[...document.querySelectorAll('#screen [data-act^="book:"]')].find(x=>/cloud|server/i.test(x.innerHTML)||true);return e&&e.getAttribute('data-act')});
// mixed: signed out own sync only, sign in -> kept
await state('0');await set('olog','none');await server();console.log('\n# S4 own sync, no opds, signed out page:',(await scr()).slice(0,380));
await goTo('set-signin');await H('select');await W(30);console.log(' sign in opens:',(await card()).slice(0,120),'|',await kf());
if(dev==='m8c'){for(const k of ['si-server','si-user','si-pw']){await goTo(k);await H('select');}await goTo('si-ok');await H('select');}else{await goTo('si-check');await H('select');}
await W(1100);console.log(' result:',await card(),'| focus',await kf());await shot('S4-kept');
await H('select');await W(30);console.log(' after Done focus',await kf(),'| page:',(await scr()).slice(0,420));
// Replace on sync
await goTo('set-slog');await H('select');await W(30);console.log(' sync form:',await card(),'| ring',await ring());await shot('S4-syncform');
await goTo('Replace');await H('select');await W(30);console.log(' after Replace focus',await kf(),'| row',(await scr()).match(/Sync login.{0,80}/)?.[0]);
// Remove sync
await H('select');await W(30);await goTo('Remove');await H('select');await W(30);console.log(' remove ask:',await card(),'| focus',await kf());
await H('back');console.log(' back from remove ->',await kf(),'modal',await p.evaluate(()=>__proto.S.modal&&__proto.S.modal.k));
await H('select');await W(30);await goTo('Remove');await H('select');await W(30);const ring2=await ring();console.log(' remove ring',ring2);
await goTo('Remove');await H('select');await W(30);console.log(' after remove focus',await kf(),'| row',(await scr()).match(/Sync login.{0,80}/)?.[0]);
console.log(' home:',await homeStatus());const hs2=await p.evaluate(()=>{const e=document.querySelector('#screen [data-fk=h-sync]');return e&&[e.innerText,e.getAttribute('data-act')]});console.log(' h-sync',hs2);
if(hs2){await A(hs2[1]);await W(30);console.log(' -> ',(await card()).slice(0,140));}
console.log(' top:',await top());
// X4 phone path per login + errors
for(const w of ['slog','olog']){
 for(const res of ['wrong','unreach','old','twostep','ok']){
  await state('none');await set('sires',res);await server();await goTo('set-'+w);await H('select');await W(30);
  const c0=await card();await H('select');await W(1100);
  console.log(`\n# ${w} Not set [${res}] opens: ${c0.slice(0,90)} | after check: ${(await card()).slice(0,260)} | focus ${await kf()} | ring ${await ring()}`);
  if(res==='wrong'){await goTo('Get a new code');await H('select');await W(30);console.log('  new code:',(await card()).match(/[A-Z0-9]{3} [A-Z0-9]{3}/)?.[0],await kf());}
  if(res==='ok')console.log('  row:',(await scr()).match(new RegExp((w==='slog'?'Sync':'OPDS')+' login.{0,70}'))?.[0]);
 }
 await state('none');await set(w,'user');await server();await goTo('set-'+w);await H('select');await W(30);console.log(` ${w} set by you opens: ${(await card()).slice(0,200)} | focus ${await kf()} | ring ${await ring()}`);await shot(w+'-userform');
}
// KOReader word scan
const k=[];await state('1','acct','acct');await server();k.push(await scr());await A('lopen:sync');k.push(await card());await A('lclose');await A('lopen:opds');k.push(await card());await A('lclose');
await A('home');await A('nav:settings');await A('setg:sync');k.push(await scr());await state('none');await server();k.push(await scr());await A('modal:signin');k.push(await card());
console.log('\nKOReader mentions:',k.join(' ## ').match(/.{0,50}KOReader.{0,30}/g));
const bad=/bookorbit|grimmory|tailscale|tailnet|calibre|kavita|komga|booklore|kosync|192\.168/i;console.log('names',k.join(' ').match(bad));
console.log('errs',errs);await b.close();})();
