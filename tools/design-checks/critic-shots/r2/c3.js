const {prototypeURL, OUT}=require('../../runtime.js');
const {chromium}=require('playwright');
const O=OUT+'critic-shots/r2/';
(async()=>{const b=await chromium.launch({executablePath:process.env.PWX});
const p=await b.newPage({viewport:{width:1500,height:1200}});
await p.addInitScript(()=>{window.__noscale=1});
await p.goto(prototypeURL+'?dev=x4c');await p.waitForTimeout(200);
const H=x=>p.evaluate(x=>window.__proto.hw(x),x);const A=a=>p.evaluate(a=>window.__proto.act(a),a);
const st=()=>p.evaluate(()=>{const S=window.__proto.S;const c=S.stack[S.stack.length-1];return JSON.stringify({scr:c.n,fk:S.fk,modal:S.modal&&S.modal.k,rs:S.rs})});
await A('nav:settings');await A('setg:account');await A('modal:signin');await p.locator('#screen').screenshot({path:O+'x4c-signin.png'});
console.log(await st());
const f=await p.evaluate(()=>[...document.querySelectorAll('#screen .sheet [data-fk], #screen .card [data-fk]')].map(e=>e.dataset.fk+'='+e.dataset.act).join(' '));console.log('focusables',f);
await H('back');await H('back');await H('back');
// wrap stepper on X4 bottom panel size
await p.evaluate(()=>window.__proto.openBook('b1'));await H('select');
const before=await p.evaluate(()=>JSON.stringify(window.__proto.S.rs));console.log('rs',before);
for(let i=0;i<12;i++) await A('cyc:size:1:6');console.log('after 12 size+',await p.evaluate(()=>window.__proto.S.rs.size));
// M8C move rule check: X4 move to page
await b.close();})();
