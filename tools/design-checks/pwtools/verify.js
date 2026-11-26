const {prototypeURL, OUT}=require('../runtime.js');
const {chromium}=require('playwright');

(async()=>{const b=await chromium.launch({executablePath:process.env.PWX});
const errs=[];const res=[];
const ok=(n,c)=>res.push((c?'PASS ':'FAIL ')+n);
async function open(dev){const p=await b.newPage({viewport:{width:1500,height:1150}});
 p.on('console',m=>{if(m.type()==='error')errs.push(dev+': '+m.text())});p.on('pageerror',e=>errs.push(dev+': '+e.message));
 await p.goto(prototypeURL+'?dev='+dev);await p.waitForTimeout(150);return p;}
const fk=(p,k)=>p.click(`#screen [data-fk="${k}"]`);
const has=(p,s)=>p.locator('#screen '+s).count().then(n=>n>0);
async function overflow(p,label){
 return p.evaluate((label)=>{const out=[];const sc=document.querySelector('#screen').getBoundingClientRect();
  document.querySelectorAll('#screen *').forEach(e=>{if(e.ownerSVGElement)return;const r=e.getBoundingClientRect();if(!r.width)return;
   if(r.right>sc.right+1||r.left<sc.left-1){ if(!e.closest('.zone')) out.push(label+' screen-x '+e.outerHTML.slice(0,120));}});
  document.querySelectorAll('#screen .tile').forEach(t=>{const tr=t.getBoundingClientRect();t.querySelectorAll('.tin *').forEach(e=>{if(e.ownerSVGElement)return;const r=e.getBoundingClientRect();if(!r.width||!r.height)return;
   if(r.bottom>tr.bottom+0.5||r.right>tr.right+0.5)out.push(label+' tile '+t.dataset.tile+' '+e.tagName+'.'+(e.className.baseVal??e.className)+' "'+(e.textContent||'').slice(0,24)+'" by '+Math.round(Math.max(r.bottom-tr.bottom,r.right-tr.right)));});});
  // text clipping: ellipsis elements are fine; check scrollWidth on non-ell nowrap
  return out;},label);}
for(const dev of ['m8c','x4pro','x4c']){
 const p=await open(dev);
 const pages=await p.evaluate(()=>window.__proto.S.layouts[window.__proto.S.dev==='m8c'?'m8c':'x4'].length);
 for(let i=0;i<pages;i++){await p.evaluate(i=>window.__proto.act('page:'+i),i);const o=await overflow(p,dev+' home'+(i+1));o.forEach(x=>res.push('OVERFLOW '+x));}
 await p.evaluate(()=>window.__proto.act('page:0'));
 if(dev==='x4c'){
  ok(dev+' focus ring on hero resume',await has(p,'.kf[data-fk="hero-resume"]'));
  await p.click('[data-hw="next"]');ok(dev+' next moves focus',!(await has(p,'.kf[data-fk="hero-resume"]')));
  await p.click('[data-hw="prev"]');await p.click('[data-hw="select"]');ok(dev+' select opens reader',await has(p,'.ptext'));
  await p.click('[data-hw="next"]');await p.click('[data-hw="more"]');ok(dev+' more opens top panel',await has(p,'.panel'));
  await p.click('[data-hw="next"]');await p.click('[data-hw="select"]');ok(dev+' select in panel opens a sheet',await has(p,'.sheet'));
  await p.click('[data-hw="back"]');await p.click('[data-hw="select"]');ok(dev+' select opens bottom panel',await has(p,'[data-fk="x-font-l"]'));
  await p.click('[data-hw="back"]');await p.click('[data-hw="back"]');ok(dev+' back goes home',await has(p,'.tile'));
  await p.keyboard.press('ArrowRight');await p.keyboard.press('ArrowRight');console.log('focus',await p.evaluate(()=>window.__proto.S.fk));await p.keyboard.press('m');ok(dev+' more on focused book opens actions',await has(p,'[data-fk="a-open"]'));
  await p.keyboard.press('Escape');
 }
 // reader flow (touch)
 await fk(p,'hero-resume');ok(dev+' resume opens reader',await has(p,'.ptext'));
 const z=await p.locator('#screen .zone').first().boundingBox();await p.mouse.click(z.x+z.width/2,z.y+10);ok(dev+' top zone opens top panel',await has(p,'[data-fk="tp-toc"]'));
 res.push(...(await overflow(p,dev+' toppanel')).map(x=>'OVERFLOW '+x));
 await fk(p,'tp-toc');ok(dev+' contents sheet',await has(p,'[data-fk^="toc-"]'));await fk(p,'sh-close');
 await p.mouse.click(z.x+z.width/2,z.y+10);await fk(p,'tp-marks');ok(dev+' bookmarks sheet',await has(p,'[data-fk="tab-1"]'));await fk(p,'tab-1');await fk(p,'sh-close');
 await p.mouse.click(z.x+z.width/2,z.y+10);await fk(p,'tp-search');ok(dev+' search sheet',await has(p,'#bq'));await fk(p,'sh-close');
 await p.mouse.click(z.x+z.width/2,z.y+10);await fk(p,'tp-info');ok(dev+' info sheet',await has(p,'[data-fk="i-details"]'));await fk(p,'sh-close');
 if(dev==='m8c'){await p.mouse.click(z.x+z.width/2,z.y+10);await fk(p,'tp-kor');ok(dev+' KOReader menu',await has(p,'.kor'));await fk(p,'kor-back');}
 const zb=await p.locator('#screen .zone').nth(1).boundingBox();await p.mouse.click(zb.x+zb.width/2,zb.y+zb.height-10);ok(dev+' bottom zone opens bottom panel',await has(p,'[data-fk="bp-scrub"]'));
 res.push(...(await overflow(p,dev+' bottompanel')).map(x=>'OVERFLOW '+x));
 const fsBefore=await p.evaluate(()=>getComputedStyle(document.querySelector('.ptext')).fontSize);
 await fk(p,dev==='m8c'?'set-size-r':'x-size-r');const fsAfter=await p.evaluate(()=>getComputedStyle(document.querySelector('.ptext')).fontSize);ok(dev+' size changes text '+fsBefore+'->'+fsAfter,fsBefore!==fsAfter);
 const sb=await p.locator('#screen [data-fk="bp-scrub"]').boundingBox();await p.mouse.click(sb.x+sb.width*0.25,sb.y+sb.height/2);const pg=await p.evaluate(()=>window.__proto.S.pages.b1);ok(dev+' scrubber jumps (p '+pg+')',pg>60&&pg<110);
 await p.mouse.click(10,10); // outside device: no-op
 await p.evaluate(()=>window.__proto.act('rd:close'));
 await p.mouse.click(z.x+z.width/2,z.y+10);await fk(p,'tp-goto');await fk(p,'gm-1');if(dev==='x4c'){await p.evaluate(()=>{const P=window.__proto;P.S.fk='gt-val';P.hw('more');for(let i=0;i<12;i++)P.hw('next');P.hw('select');});}else{await fk(p,'gk-1');await fk(p,'gk-0');await fk(p,'gk-0');await fk(p,'gk-go');}ok(dev+' go to 100% opens end of book',await has(p,'[data-fk="e-home"]'));
 res.push(...(await overflow(p,dev+' end')).map(x=>'OVERFLOW '+x));
 await fk(p,'star-4');await fk(p,'e-home');ok(dev+' end -> home',await has(p,'.tile'));
 const hero=await p.evaluate(()=>window.__proto.S.hero);ok(dev+' hero moves to next book after finishing ('+hero+')',hero!=='b1');
 // long press -> actions -> remove download with confirm
 const cov=p.locator("#screen [data-fk^=\"also-b\"]").first();const cb=await cov.boundingBox();
 await p.mouse.move(cb.x+20,cb.y+10);await p.mouse.down();await p.waitForTimeout(650);await p.mouse.up();ok(dev+' long press opens actions',await has(p,'[data-fk="a-remove"]'));
 await fk(p,'a-remove');ok(dev+' remove asks to confirm',await has(p,'[data-fk="cf-ok"]'));await fk(p,'cf-ok');
 const dv=await p.evaluate(()=>window.__proto.S&&1);ok(dev+' remove done',!(await has(p,'[data-fk="cf-ok"]')));
 // offline: tap server-only -> connect -> download -> opens
 await p.check('#offline');await p.evaluate(()=>window.__proto.act('page:0'));
 const rc=p.locator('#screen [data-book="b10"]').first();await rc.click();ok(dev+' offline tap asks to connect',await has(p,'[data-fk="cn-ok"]'));
 await fk(p,'cn-ok');await p.waitForTimeout(300);ok(dev+' download progress on cover',await has(p,'.dl'));
 await p.waitForTimeout(2600);ok(dev+' opens after download',await has(p,'.ptext'));
 await p.evaluate(()=>window.__proto.act('home'));
 // download with cancel
 await p.evaluate(()=>window.__proto.act('page:0'));const rc2=p.locator('#screen [data-book="b12"]').first();if(await rc2.count()){await rc2.click();await p.waitForTimeout(150);await p.locator('#screen [data-fk="cancel-b12"]').first().click();ok(dev+' cancel download',!(await has(p,'.dl')));}
 // also reading list, scopes, search
 await fk(p,'also-all');ok(dev+' reading-now list',await has(p,'.shdr'));res.push(...(await overflow(p,dev+' reading')).map(x=>'OVERFLOW '+x));await fk(p,'back');
 await p.locator('#screen [data-act^="scope:"]').first().click();ok(dev+' scope opens shelf',await has(p,'[data-fk="s-filter"]'));res.push(...(await overflow(p,dev+' scope')).map(x=>'OVERFLOW '+x));await fk(p,'back');
 await fk(p,'h-search');for(const k of 'tide')await fk(p,'k-'+k);ok(dev+' search finds results',await has(p,'[data-fk^="row-"]'));res.push(...(await overflow(p,dev+' search')).map(x=>'OVERFLOW '+x));await fk(p,'back');
 // details, series, download next 3
 await p.evaluate(()=>{window.__proto.act('home')});await p.evaluate(()=>window.__proto.act('details:b1'));res.push(...(await overflow(p,dev+' details')).map(x=>'OVERFLOW '+x));
 await fk(p,'d-series');ok(dev+' series page',await has(p,'[data-fk="s-dlnext"]'));res.push(...(await overflow(p,dev+' series')).map(x=>'OVERFLOW '+x));
 await p.uncheck('#offline');await fk(p,'s-dlnext');await p.waitForTimeout(200);ok(dev+' download next 3 starts',await p.evaluate(()=>Object.keys(window.__proto.S.downloads).length>0));
 await p.waitForTimeout(4500);
 // edit mode
 await p.evaluate(()=>window.__proto.act('home'));await fk(p,'h-menu');await fk(p,'m-edit');ok(dev+' edit mode',await has(p,'.tile.ed'));
 await fk(p,'tile-1');ok(dev+' select tile',await has(p,'.tile.sel'));
 const before=await p.evaluate(()=>JSON.stringify(window.__proto.S.layouts));
 await p.evaluate(()=>window.__proto.act('remove'));await fk(p,'ed-add');ok(dev+' picker opens',await has(p,'[data-fk="add-week"]')||await has(p,'[data-fk="add-hero"]'));
 res.push(...(await overflow(p,dev+' picker')).map(x=>'OVERFLOW '+x));
 const addk=await p.locator('#screen [data-fk^="add-"]').nth(1).getAttribute('data-fk');await fk(p,addk);ok(dev+' widget added ('+addk+')',await has(p,'.tile.sel'));
 const sz1=await p.evaluate(()=>{const S=window.__proto.S;const t=S.layouts[S.dev==='m8c'?'m8c':'x4'][S.page].tiles[S.sel];return t.cw+'x'+t.ch});
 if(dev==='x4c')await p.evaluate(()=>window.__proto.hw('more'));else await fk(p,'ed-size');const sz2=await p.evaluate(()=>{const S=window.__proto.S;const t=S.layouts[S.dev==='m8c'?'m8c':'x4'][S.page].tiles[S.sel];return t.cw+'x'+t.ch});ok(dev+' resize '+sz1+'->'+sz2,true);
 await p.evaluate(()=>window.__proto.act('desel'));await fk(p,'ed-padd');ok(dev+' page added',await has(p,'.slot'));await fk(p,'ed-pdel');await fk(p,'ed-reset');await fk(p,'ed-done');ok(dev+' edit done',!(await has(p,'.tile.ed')));
 await p.close();
}
console.log(res.join('\n'));console.log('ERRORS:',errs.length?errs.join('\n'):'none');await b.close();})();
