const {prototypeURL, OUT}=require('../runtime.js');
const {chromium}=require('playwright');

(async()=>{const b=await chromium.launch({executablePath:process.env.PWX});const out=[];
for(const dev of ['m8c','x4pro']){const p=await b.newPage({viewport:{width:1500,height:1150}});p.on('pageerror',e=>out.push('ERR '+e.message));
 await p.addInitScript(()=>{window.__noscale=1});await p.goto(prototypeURL+'?dev='+dev);
 const list=await p.evaluate(()=>{const S=window.__proto.S;const k=S.dev==='m8c'?'m8c':'x4';return eval('ORDER_PICK').map(w=>[w,eval('W')[w].sizes[k]])});
 for(const [w,sizes] of list){for(const [cw,ch] of sizes){for(const so of (['year','week','hours','records'].includes(w)?[false,true]:[false])){
  const o=await p.evaluate(([w,cw,ch,so])=>{const S=window.__proto.S;if(S.acct||true){window.__proto.S.acct=Object.assign(window.__proto.S.acct||{name:'reader',srv:'books.example.net',sync:{st:'acct',how:'found'},opds:{st:'acct',how:'created'}},{in:!so});}const k=S.dev==='m8c'?'m8c':'x4';S.layouts[k][0].tiles=[{w,x:0,y:0,cw,ch}];S.page=0;window.__proto.render();
   const t=document.querySelector('#screen .tile');const tr=t.getBoundingClientRect();const bad=[];
   t.querySelectorAll('.tin *').forEach(e=>{if(e.ownerSVGElement)return;const r=e.getBoundingClientRect();if(!r.width||!r.height)return;if(r.bottom>tr.bottom+0.5||r.right>tr.right+0.5)bad.push(e.tagName+'.'+e.className+' '+(e.textContent||'').slice(0,20)+' by '+Math.round(Math.max(r.bottom-tr.bottom,r.right-tr.right)));});
   // also text clipped horizontally in nowrap non-ell
   t.querySelectorAll('.tin *').forEach(e=>{if(e.ownerSVGElement||e.classList.contains('ell'))return;if(e.scrollWidth>e.clientWidth+1&&getComputedStyle(e).overflow==='hidden')bad.push('clip '+e.className+' '+(e.textContent||'').slice(0,20));});
   // clipped child text: any text run that ends outside an ancestor that clips (overflow not visible), up to the tile
   const tw=document.createTreeWalker(t.querySelector('.tin'),NodeFilter.SHOW_TEXT);let n;while((n=tw.nextNode())){if(!n.textContent.trim())continue;const el=n.parentElement;if(el.closest('.ell'))continue;const rg=document.createRange();rg.selectNodeContents(n);const rr=rg.getBoundingClientRect();if(!rr.width)continue;
    let a=el;while(a&&!a.classList.contains('tile')){const cs=getComputedStyle(a);if(cs.overflowX!=='visible'||cs.overflow!=='visible'){const ar=a.getBoundingClientRect();const clampBox=cs.webkitLineClamp&&cs.webkitLineClamp!=='none';if(rr.right>ar.right+1||(rr.bottom>ar.bottom+(clampBox?5:1))){bad.push('textclip "'+n.textContent.trim().slice(0,24)+'" by '+Math.round(Math.max(rr.right-ar.right,rr.bottom-ar.bottom)));break;}}a=a.parentElement;}
    const tr2=t.getBoundingClientRect();if(rr.right>tr2.right-1||rr.bottom>tr2.bottom-1)bad.push('textout "'+n.textContent.trim().slice(0,24)+'"');}
   // round 5: the battery estimate always says what it assumes, and that phrase is never clipped
   if(w==='battery'){const bl=t.querySelector('.batleft');if(!bl)bad.push('battery: no estimate line');else{const r=bl.getBoundingClientRect();const txt=bl.textContent;const full=/≈ .+ at your usual use$/.test(txt),short=/≈ .+ · usual use$/.test(txt);if(!full&&!short)bad.push('battery: estimate says "'+txt+'"');if(short&&tr.width>=260)bad.push('battery: short form on a wide tile');if(r.right>tr.right-4||bl.scrollWidth>bl.clientWidth+1)bad.push('battery: estimate clipped "'+txt+'"');
     const rg=document.createRange();rg.selectNodeContents(bl);const rr=rg.getBoundingClientRect();if(rr.right>tr.right-4)bad.push('battery: estimate text past the tile by '+Math.round(rr.right-tr.right+4));}}
   // round 8: signed out, Stats widgets carry the "This reader only" note, fully visible
   if(so){const n=t.querySelector('.srcnote');if(!n)bad.push('no source note');else{const r=n.getBoundingClientRect();if(r.right>tr.right-4)bad.push('source note clipped');}}
   return bad;},[w,cw,ch,so]);
  o.forEach(x=>out.push(dev+' '+w+' '+cw+'x'+ch+(so?' (signed out)':'')+': '+x));
  const box=await p.locator('#screen .tile').boundingBox();await p.screenshot({path:OUT+`sweep/${dev}-${w}-${cw}x${ch}${so?'-out':''}.png`,clip:box});
 }}}await p.close();}
console.log(out.join('\n')||'no overflow');await b.close();})();
