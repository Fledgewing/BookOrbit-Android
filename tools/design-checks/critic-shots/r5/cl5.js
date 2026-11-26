const {prototypeURL, OUT}=require('../../runtime.js');
const {chromium}=require('playwright');
const O=OUT+'critic-shots/r5/';
(async()=>{const b=await chromium.launch({executablePath:process.env.PWX});
const p=await b.newPage({viewport:{width:1500,height:1200}});const errs=[];p.on('pageerror',e=>errs.push(e.message));
await p.addInitScript(()=>{window.__noscale=1});
await p.goto(prototypeURL+'?dev=x4c');
const H=async k=>{await p.evaluate(k=>__proto.hw(k),k);};
const st=()=>p.evaluate(()=>({kf:document.querySelector('#screen .kf')?.dataset.fk,pick:__proto.S.modal&&__proto.S.modal.pick,modal:__proto.S.modal&&__proto.S.modal.k,top:__proto.S.stack.at(-1).n+':'+(__proto.S.stack.at(-1).src||''),apply:document.querySelector('[data-fk=f-apply]')?.innerText,sub:document.querySelector('#screen .shdr,#screen')?.innerText.slice(0,120).replace(/\s+/g,' ')}));
await p.evaluate(()=>__proto.act('nav:recent'));
let s=await st();let n=0;while(s.kf!=='s-filter'&&n<40){await H('prev');s=await st();n++;}console.log('to filter',n,s.kf);
await H('select');console.log('open',JSON.stringify(await st()));
const seq=[];for(let i=0;i<14;i++){await H('next');seq.push((await st()).kf);}console.log('next x14',seq.join(' > '));
// go to Length
s=await st();n=0;while(s.kf!=='f-len'&&n<20){await H('next');s=await st();n++;}
await H('select');console.log('len picker',JSON.stringify(await st()));
await H('next');await H('select');console.log('after choose short',JSON.stringify(await st()));
await p.locator('#screen').screenshot({path:O+'x4c-cl-after-short.png'});
// Author picker toggle
s=await st();n=0;while(s.kf!=='f-authors'&&n<20){await H('prev');s=await st();n++;}
await H('select');let a=await st();console.log('author picker',JSON.stringify(a));
await H('select');console.log('toggled',JSON.stringify(await st()));
await p.locator('#screen').screenshot({path:O+'x4c-cl-author-toggled.png'});
await H('back');console.log('back from picker',JSON.stringify(await st()));
await p.locator('#screen').screenshot({path:O+'x4c-cl-sheet-changed.png'});
// gs picker
s=await st();n=0;while(s.kf!=='f-gs'&&n<20){await H('next');s=await st();n++;}
await H('select');const g=[];for(let i=0;i<14;i++){g.push((await st()).kf);await H('next');}console.log('gs walk',g.join(' > '));
await H('back');console.log('back from gs',JSON.stringify(await st()));
await H('back');console.log('back from sheet',JSON.stringify(await st()));
await p.locator('#screen').screenshot({path:O+'x4c-cl-applied.png'});
console.log('errs',errs);await b.close();})();
