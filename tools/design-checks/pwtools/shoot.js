const {prototypeURL, OUT}=require('../runtime.js');
const {chromium}=require('playwright');


const only=process.argv[4];
(async()=>{const b=await chromium.launch({executablePath:process.env.PWX});
const errs=[];
async function page(dev,dsf){const p=await b.newPage({viewport:{width:1500,height:1200},deviceScaleFactor:dsf||1});
 p.on('console',m=>{if(m.type()==='error')errs.push(dev+': '+m.text())});p.on('pageerror',e=>errs.push(dev+': '+e.message));
 await p.addInitScript(()=>{window.__noscale=1});
 await p.goto(prototypeURL+'?dev='+dev);await p.waitForTimeout(200);return p;}
async function shot(p,name,keepToast){await p.waitForTimeout(80);if(!keepToast)await p.evaluate(()=>{const P=window.__proto;if(P.S.toast){P.S.toast=null;P.S.toastAct=null;P.render();}});await p.locator('#screen').screenshot({path:OUT+name+'.png'});}
const A=(p,a)=>p.evaluate(a=>window.__proto.act(a),a);
const shots={
 async m8c(){const p=await page('m8c',+process.env.DSF||1);await shot(p,'m8c-home-1');
  await A(p,'page:1');await shot(p,'m8c-home-2');await A(p,'page:0');
  await p.evaluate(()=>{const P=window.__proto;P.openBook('b1')});await A(p,'rd:top');await shot(p,'m8c-reader-top');
  await A(p,'rd:close');await shot(p,'m8c-reader');await A(p,'rd:bottom');await shot(p,'m8c-reader-bottom');
  await A(p,'sheet:toc');await shot(p,'m8c-sheet-toc');await A(p,'sheet:marks');await shot(p,'m8c-sheet-marks');await A(p,'sheet:goto');await shot(p,'m8c-sheet-goto');await A(p,'sheet:search');await shot(p,'m8c-sheet-search');await A(p,'sheet:info');await shot(p,'m8c-sheet-info');await A(p,'sheet:kor');await shot(p,'m8c-kor');
  await A(p,'jump:341');await shot(p,'m8c-end');
  await p.evaluate(()=>window.__proto.restart('m8c'));await A(p,'menu');await shot(p,'m8c-menu');await A(p,'m:edit');await A(p,'sel:0');await shot(p,'m8c-edit');await A(p,'size');await shot(p,'m8c-edit-resized');await A(p,'picker');await shot(p,'m8c-picker');await A(p,'closeModal');await A(p,'editDone');
  await A(p,'actions:b1');await shot(p,'m8c-actions');await A(p,'closeModal');
  await A(p,'details:b1');await shot(p,'m8c-details');await A(p,'series:tide');await shot(p,'m8c-series');
  await A(p,'home');await A(p,'nav:reading');await shot(p,'m8c-reading');await A(p,'home');await A(p,'scope:s1');await shot(p,'m8c-scope');
  await A(p,'home');await A(p,'search');await A(p,'sq:calder');await shot(p,'m8c-search');
  await A(p,'home');await A(p,'book:b10');await p.waitForTimeout(500);await shot(p,'m8c-download');
  await p.evaluate(()=>window.__proto.restart('m8c'));await A(p,'nav:settings');await shot(p,'m8c-settings');await A(p,'setg:reading');await shot(p,'m8c-settings-reading');await A(p,'back');
  await A(p,'setg:account');await A(p,'modal:signin');await shot(p,'m8c-settings-signin');await A(p,'closeModal');await A(p,'back');
  await A(p,'setg:library');await A(p,'fullrefresh');await p.waitForTimeout(1200);await shot(p,'m8c-settings-library');await p.waitForTimeout(3000);await A(p,'back');
  await A(p,'setg:about');await shot(p,'m8c-settings-about');await A(p,'home');
  await A(p,'nav:battery');await shot(p,'m8c-battery');await A(p,'tab:1');await shot(p,'m8c-battery-rates');await A(p,'tab:2');await shot(p,'m8c-battery-daily');await A(p,'tab:3');await shot(p,'m8c-battery-charges');await A(p,'home');
  await A(p,'nav:library');await shot(p,'m8c-library-list');await A(p,'home');
  await p.evaluate(()=>{const S=window.__proto.S;S.layouts.m8c.push({name:'Sizes',tiles:[{w:'hero',x:0,y:0,cw:2,ch:3},{w:'battery',x:2,y:0,cw:2,ch:3},{w:'battery',x:0,y:3,cw:2,ch:2},{w:'battery',x:2,y:3,cw:2,ch:1},{w:'clock',x:2,y:4,cw:2,ch:1},{w:'library',x:0,y:5,cw:2,ch:1},{w:'battery',x:0,y:6,cw:4,ch:2}]});S.page=S.layouts.m8c.length-1;window.__proto.render();});await shot(p,'m8c-sizes-gallery');
  await p.evaluate(()=>{const P=window.__proto,S=P.S;S.page=0;S.layouts.m8c[0].tiles=[{w:'hero',x:0,y:0,cw:4,ch:2},{w:'records',x:0,y:2,cw:4,ch:1},{w:'also',x:0,y:3,cw:2,ch:2},{w:'library',x:0,y:5,cw:2,ch:1},{w:'scopes',x:2,y:3,cw:2,ch:3},{w:'recent',x:0,y:6,cw:4,ch:2}];S.edit=true;P.act('sel:1');});await shot(p,'m8c-edit-move-before');
  await A(p,'mv:0:1');await shot(p,'m8c-edit-move-after');
  await p.evaluate(()=>{const P=window.__proto;P.restart('m8c');const S=P.S;S.edit=true;P.act('sel:0');});await A(p,'size');await A(p,'size');await shot(p,'m8c-edit-hero-2x3');
  await p.evaluate(()=>{const P=window.__proto;P.restart('m8c');P.openBook('b1');});await A(p,'rd:top');await shot(p,'m8c-reader-top');
  await p.evaluate(()=>{const P=window.__proto;P.restart('m8c');P.act('nav:storage');});await shot(p,'m8c-storage');
  await p.evaluate(()=>{const P=window.__proto;P.S.lowspace=1;P.act('home');});await shot(p,'m8c-home-lowspace');await A(p,'nav:storage');await shot(p,'m8c-storage-low');await A(p,'modal:rmfinished');await shot(p,'m8c-storage-remove-finished');
  await p.evaluate(()=>{const P=window.__proto;P.act('closeModal');P.act('home');P.act('series:tide');P.act('dlnext:tide');});await shot(p,'m8c-not-enough-space');
  await p.evaluate(()=>{const P=window.__proto;P.restart('m8c');P.act('hsync');});await shot(p,'m8c-home-syncing');
  await p.evaluate(()=>{const P=window.__proto;P.restart('m8c');P.openBook('b1');P.act('rd:top');P.act('bsync');});await shot(p,'m8c-book-syncing');await p.waitForTimeout(1100);await shot(p,'m8c-sync-further');
  await p.evaluate(()=>{const P=window.__proto;P.restart('m8c');const S=P.S;S.edit=true;P.act('sel:5');});await shot(p,'m8c-edit-booklist');await A(p,'cfg');await shot(p,'m8c-booklist-config');await A(p,'blpg:1');await shot(p,'m8c-booklist-source');
  await p.evaluate(()=>{const P=window.__proto;P.restart('m8c');P.act('lst:list:s1|Short%20reads|0');P.act('grp:1');});await shot(p,'m8c-list-by-author');await A(p,'grp:2');await shot(p,'m8c-list-by-series');await A(p,'grp:0');await shot(p,'m8c-list');
  await p.evaluate(()=>{const P=window.__proto;P.restart('m8c');P.act('nav:reading');});await shot(p,'m8c-reading');
  await p.close();},
 async x4(dev){const p=await page(dev);const pre=dev==='x4c'?'x4c':'x4pro';
  await shot(p,pre+'-home-1');await A(p,'page:1');await shot(p,pre+'-home-2');await A(p,'page:2');await shot(p,pre+'-home-3');await A(p,'page:0');
  await p.evaluate(()=>window.__proto.openBook('b1'));await shot(p,pre+'-reader');await A(p,'rd:top');await shot(p,pre+'-reader-top');await A(p,'rd:close');await A(p,'rd:bottom');await shot(p,pre+'-reader-bottom');
  await A(p,'sheet:toc');await shot(p,pre+'-sheet-toc');await A(p,'sheet:goto');await shot(p,pre+'-sheet-goto');await A(p,'jump:341');await shot(p,pre+'-end');
  await p.evaluate(d=>window.__proto.restart(d),dev);await A(p,'menu');await A(p,'m:edit');await A(p,'sel:1');await shot(p,pre+'-edit');await A(p,'editDone');
  await A(p,'details:b1');await shot(p,pre+'-details');await A(p,'series:tide');await shot(p,pre+'-series');await A(p,'home');await A(p,'actions:b2');await shot(p,pre+'-actions');await A(p,'closeModal');
  await A(p,'nav:settings');await shot(p,pre+'-settings');await A(p,'setg:reading');await shot(p,pre+'-settings-reading');await A(p,'back');await A(p,'setg:power');await shot(p,pre+'-settings-power');await A(p,'home');
  await A(p,'nav:battery');await shot(p,pre+'-battery');await A(p,'tab:1');await shot(p,pre+'-battery-rates');await A(p,'tab:2');await shot(p,pre+'-battery-daily');await A(p,'home');
  await p.evaluate(()=>{const S=window.__proto.S;S.layouts.x4.push({name:'Sizes',tiles:[{w:'hero',x:0,y:0,cw:2,ch:3},{w:'battery',x:0,y:3,cw:1,ch:1},{w:'clock',x:1,y:3,cw:1,ch:1},{w:'battery',x:0,y:4,cw:1,ch:2},{w:'hero',x:1,y:4,cw:1,ch:2},{w:'battery',x:0,y:6,cw:2,ch:1}]});S.page=S.layouts.x4.length-1;window.__proto.render();});await shot(p,pre+'-sizes-gallery');
  if(dev==='x4c'){await p.evaluate(()=>{const P=window.__proto;P.restart('x4c');P.act('m:edit');P.hw('select');P.hw('next');P.hw('next');});await shot(p,'x4c-edit-carry');
   await p.evaluate(()=>{const P=window.__proto;P.restart('x4c');P.openBook('b1');P.act('rd:top');P.act('sheet:toc');});await shot(p,'x4c-toc-focus');
   await p.evaluate(()=>{const P=window.__proto,S=P.S;P.act('sheetclose');P.act('rd:bottom');S.fk='bp-scrub';P.hw('select');P.hw('next');});await shot(p,'x4c-scrub-grab');
   await p.evaluate(()=>{const P=window.__proto;P.restart('x4c');P.act('m:edit');P.hw('next');P.hw('more');});await shot(p,'x4c-edit-options');
   await p.evaluate(()=>{const P=window.__proto,S=P.S;S.fk='tm-cfg';P.hw('select');P.hw('next');});await shot(p,'x4c-booklist-config');}
  await p.evaluate(d=>{const P=window.__proto;P.restart(d);P.act('lst:all|Library|0');P.act('grp:2');},dev);await shot(p,pre+'-list-by-series');
  await p.evaluate(d=>{const P=window.__proto;P.restart(d);P.act('nav:storage');},dev);await shot(p,pre+'-storage');
  await p.evaluate(()=>{const P=window.__proto;P.S.lowspace=1;P.act('home');P.act('page:1');});await shot(p,pre+'-library-lowspace');
  await p.evaluate(d=>{const P=window.__proto;P.restart(d);P.openBook('b1');P.act('rd:top');P.act('bsync');},dev);await p.waitForTimeout(1100);await shot(p,pre+'-sync-further');
  await p.close();}
};
if(!only||only==='m8c')await shots.m8c();
if(!only||only==='x4')await shots.x4('x4pro');
if(!only||only==='x4c')await shots.x4('x4c');
console.log('ERRORS:',errs.length?errs.join('\n'):'none');await b.close();})();
