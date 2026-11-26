const {prototypeURL, OUT}=require('../../runtime.js');
const {chromium}=require('playwright');const O=OUT+'critic-shots/r10/';
const dev=process.env.DEV||'x4c';
(async()=>{const b=await chromium.launch({executablePath:process.env.PWX});const p=await b.newPage({viewport:{width:1500,height:1200},deviceScaleFactor:dev==='m8c'?2:1});
const errs=[];p.on('pageerror',e=>errs.push(e.message));
await p.addInitScript(()=>{window.__noscale=1});await p.goto(prototypeURL+'?dev='+dev);
const H=k=>p.evaluate(k=>__proto.hw(k),k);const A=a=>p.evaluate(a=>__proto.act(a),a);const W=ms=>p.waitForTimeout(ms);
const kf=()=>p.evaluate(()=>{const e=document.querySelector('#screen .kf');return e?e.dataset.fk+'«'+e.innerText.replace(/\s+/g,' ').trim().slice(0,34)+'»':'NONE'});
const scr=()=>p.evaluate(()=>document.querySelector('#screen').innerText.replace(/\s+/g,' '));
const card=()=>p.evaluate(()=>{const c=[...document.querySelectorAll('#screen .card')].pop();if(!c)return '(no card)';const s=document.querySelector('#screen').getBoundingClientRect(),r=c.getBoundingClientRect();return c.innerText.replace(/\s+/g,' ').slice(0,200)+` [${Math.round(r.top-s.top)}..${Math.round(r.bottom-s.top)}/${Math.round(s.height)}]`});
const ring=async(n=30)=>{const s=[await kf()];for(let i=0;i<n;i++){await H('next');const k=await kf();if(k===s[0])break;s.push(k);}return s.map(x=>x.split('«')[0]).join(' > ');};
const goTo=async t=>{for(let i=0;i<50;i++){const k=await kf();if(k.startsWith(t+'«')||k.includes(t))return true;await H('next');}console.log('   !! cannot reach',t,'at',await kf());return false;};
const val=()=>p.evaluate(()=>{const e=document.querySelector('#screen .card [data-fk=ce-dec]');return e?e.parentElement.innerText.replace(/\s+/g,' '):null});
const shot=n=>p.locator('#screen').screenshot({path:O+dev+'-'+n+'.png'});
const small=()=>p.evaluate(()=>{const c=[...document.querySelectorAll('#screen .card')].pop();if(!c)return [];return [...c.querySelectorAll('[data-act]')].filter(e=>{const r=e.getBoundingClientRect();return r.width&&(Math.min(r.width,r.height)<(location.search.includes('m8c')?50:44))}).map(e=>e.dataset.fk+':'+Math.round(e.getBoundingClientRect().width)+'x'+Math.round(e.getBoundingClientRect().height))});
await A('nav:settings');await A('setg:reading');await W(30);
console.log('READING page:',(await scr()).slice(0,700));console.log('ring',await ring());
for(const row of ['Custom font','Custom margins','Custom line spacing','Custom contrast']){
  await A('home');await A('nav:settings');await A('setg:reading');
  if(!await goTo(row)){ // maybe page 2
    continue;}
  const before=await kf();await H('select');await W(30);console.log('\n['+row+'] from',before,'->',await card(),'| focus',await kf(),'| small',JSON.stringify(await small()));
  console.log(' ring',await ring());
  if(row==='Custom font'){await goTo('ce-f-2');await H('select');console.log(' picked font focus',await kf());}
  const v0=await val();await goTo('ce-inc');await H('select');await H('select');const v1=await val();await goTo('ce-dec');await H('select');const v2=await val();
  for(let i=0;i<60;i++)await H('select');const vmin=await val();await goTo('ce-inc');for(let i=0;i<80;i++)await H('select');const vmax=await val();
  console.log(' stepper',v0,'| +2:',v1,'| -1:',v2,'| min:',vmin,'| max:',vmax);await shot('ed-'+row.split(' ')[1]);
  await H('back');await W(30);console.log(' Back ->',await kf(),'modal',await p.evaluate(()=>__proto.S.modal&&__proto.S.modal.k));
  await H('select');await W(30);await goTo('ce-done');await H('select');console.log(' Done ->',await kf());
}
// panel custom
await A('home');const ra=await p.evaluate(()=>document.querySelector('#screen [data-fk=hero-resume]').getAttribute('data-act'));await A(ra);await A('rd:bottom');await W(30);
const rs0=await p.evaluate(()=>JSON.stringify(__proto.S.rs));console.log('\nPANEL rs',rs0);
if(dev==='m8c'){
  await p.evaluate(()=>{__proto.S.rs.spacing=0});await A('set:spacing:0');
  const seg=await p.evaluate(()=>{const e=document.querySelector('#screen [data-fk=set-spacing-2]');return e&&[e.innerText.replace(/\s+/g,' '),e.getAttribute('data-act')]});console.log(' spacing custom seg (not picked):',seg);
  await A(seg[1]);console.log(' after tap: rs.spacing',await p.evaluate(()=>__proto.S.rs.spacing),'modal',await p.evaluate(()=>__proto.S.modal&&__proto.S.modal.k));
  const seg2=await p.evaluate(()=>{const e=document.querySelector('#screen [data-fk=set-spacing-2]');return e&&[e.innerText.replace(/\s+/g,' '),e.getAttribute('data-act'),!!e.querySelector('svg')]});console.log(' seg now',seg2);
  await A(seg2[1]);console.log(' second tap ->',await card());await A('ceadj:1');await A('ceadj:1');console.log(' adjusted, panel seg behind:',await p.evaluate(()=>document.querySelector('#screen [data-fk=set-spacing-2]')?.innerText.replace(/\s+/g,' ')));
  await A('cedone');console.log(' done -> fk',await p.evaluate(()=>__proto.S.fk),'panel open?',await p.evaluate(()=>!!document.querySelector('#screen [data-fk=set-spacing-2]')));
} else {
  // classic: reach spacing stepper and step into custom
  await goTo('x-spacing-r');const steps=[];for(let i=0;i<3;i++){await H('select');steps.push(await p.evaluate(()=>__proto.S.rs.spacing+':'+(document.querySelector('#screen [data-fk=x-spacing-l]')?.parentElement.innerText.replace(/\s+/g,' '))));if(await p.evaluate(()=>__proto.S.rs.spacing===2))break;}
  console.log(' step into custom',steps,'modal',await p.evaluate(()=>__proto.S.modal&&__proto.S.modal.k));
  console.log(' panel ring',await ring(40));
  await goTo('x-spacing-v');await H('select');await W(30);console.log(' value stop ->',await card(),'| focus',await kf());
  await goTo('ce-inc');await H('select');console.log(' +1',await val(),'behind:',await p.evaluate(()=>document.querySelector('#screen [data-fk=x-spacing-v]')?.innerText.replace(/\s+/g,' ')));
  await H('back');console.log(' back ->',await kf(),'panel open?',await p.evaluate(()=>!!document.querySelector('#screen [data-fk=x-spacing-l]')));
  await shot('panel-after');
}
// wording scans
const t=[];await A('home');await A('nav:settings');for(const g of ['reading','sync','home','power','updates','account']){await A('setg:'+g);t.push(await scr());for(let i=0;i<3;i++){await A('page:'+i).catch(()=>{});} await A('back');}
const all=t.join(' ## ');console.log('\nFrom KOReader:',/From KOReader/i.test(all),'| Your own settings:',/Your own settings/.test(all),'| KOReader decides:',all.match(/.{0,40}KOReader decides.{0,30}/)?.[0],'| Furthest:',all.match(/.{0,40}Furthest page wins.{0,30}/)?.[0],'| copy row:',/Use KOReader's current values/.test(all));
console.log('errs',errs);await b.close();})();
