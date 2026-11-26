const {prototypeURL, OUT}=require('../runtime.js');
const {chromium}=require('playwright');

(async()=>{const b=await chromium.launch({executablePath:process.env.PWX});
const p=await b.newPage({viewport:{width:1500,height:1200}});const errs=[];p.on('pageerror',e=>errs.push(e.message));p.on('console',m=>{if(m.type()==='error')errs.push(m.text())});
await p.addInitScript(()=>{window.__noscale=1});
await p.goto(prototypeURL+'?dev=x4c');await p.waitForTimeout(200);
const H=x=>p.evaluate(x=>window.__proto.hw(x),x);const A=a=>p.evaluate(a=>window.__proto.act(a),a);
const st=()=>p.evaluate(()=>{const S=window.__proto.S;const c=S.stack[S.stack.length-1];return JSON.stringify({scr:c.n,panel:c.panel,sheet:c.sheet,fk:S.fk,page:S.page,modal:S.modal&&S.modal.k,edit:S.edit,sel:S.sel})});
const fks=()=>p.evaluate(()=>[...document.querySelectorAll('#screen [data-fk]')].filter(e=>e.offsetParent).map(e=>e.dataset.fk).join(' '));
console.log('home', await st());
for(let i=0;i<14;i++){await H('next');} console.log('after 14 next', await st());
await A('page:0');
await H('more'); console.log('more on home', await st()); await H('back'); console.log(await st());
// edit
await A('menu');await A('m:edit'); console.log('edit', await st(), await fks());
await H('select'); console.log('edit select', await st());
await H('next');await H('next'); console.log('edit next2', await st());
await H('select'); console.log('edit sel', await st()); await p.locator('#screen').screenshot({path:OUT+'critic-shots/x4c-edit-sel.png'});
await H('back'); console.log('edit back', await st());
await A('editDone');
// reader
await p.evaluate(()=>window.__proto.openBook('b1'));await H('more');console.log('top',await st());
await H('select');console.log('toc',await st());await p.locator('#screen').screenshot({path:OUT+'critic-shots/x4c-toc.png'});
await H('back');console.log('back from toc',await st());
await H('more');await H('next');await H('next');await H('next');console.log('focus',await st());await H('select');console.log('goto',await st(), await fks());
await H('back');await H('select');console.log('bottom', await st(), await fks());
await H('next');await H('next');await H('select');console.log('after select in bottom', await st());
await p.locator('#screen').screenshot({path:OUT+'critic-shots/x4c-bottom-nav.png'});
await H('back');await H('back');console.log('back back',await st());
console.log('ERR',errs);
await b.close();})();
