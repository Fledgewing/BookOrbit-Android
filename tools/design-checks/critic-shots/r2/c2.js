const {prototypeURL, OUT}=require('../../runtime.js');
const {chromium}=require('playwright');
const O=OUT+'critic-shots/r2/';
(async()=>{const b=await chromium.launch({executablePath:process.env.PWX});
const p=await b.newPage({viewport:{width:1500,height:1200}});const errs=[];p.on('pageerror',e=>errs.push(e.message));
await p.addInitScript(()=>{window.__noscale=1});
await p.goto(prototypeURL+'?dev=x4c');await p.waitForTimeout(200);
const H=x=>p.evaluate(x=>window.__proto.hw(x),x);const A=a=>p.evaluate(a=>window.__proto.act(a),a);
const st=()=>p.evaluate(()=>{const S=window.__proto.S;const c=S.stack[S.stack.length-1];return JSON.stringify({scr:c.n,fk:S.fk,page:S.page,modal:S.modal&&S.modal.k,edit:S.edit,sel:S.sel,carry:S.carry})});
const shot=n=>p.locator('#screen').screenshot({path:O+n+'.png'});
// home focus sequence
let seq=[];for(let i=0;i<30;i++){await H('next');const s=JSON.parse(await st());seq.push(s.page+':'+s.fk);} console.log('HOME NEXT', seq.join(' '));
await A('page:0');
// edit focus order
await A('menu');await A('m:edit');seq=[];for(let i=0;i<12;i++){await H('next');seq.push(JSON.parse(await st()).fk);} console.log('EDIT NEXT', seq.join(' '));
await A('editDone');
// settings, account sign in
await A('nav:settings');console.log('settings',await st());await A('setg:account');console.log(await st());
const fks=await p.evaluate(()=>[...document.querySelectorAll('#screen [data-act]')].filter(e=>e.offsetParent).map(e=>e.dataset.act).join(' '));console.log('account acts',fks);
await A('signin');await shot('x4c-signin');console.log('signin',await st(), await p.evaluate(()=>document.querySelector('#screen').innerText.slice(0,400)));
await b.close();console.log('ERR',errs);})();
