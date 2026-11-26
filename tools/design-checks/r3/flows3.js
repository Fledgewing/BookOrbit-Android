const {prototypeURL, OUT}=require('../runtime.js');
// Round-3 flows: page rename + auto-name, the shared filter sheet (list and search), save as a Book list on Home, Classic filter.
const {chromium}=require('playwright');
const O=OUT+'shots/';
let pass=0,fail=0;const ok=(c,m)=>{if(c){pass++;console.log('  ok  ',m)}else{fail++;console.log('  FAIL',m)}};
(async()=>{const b=await chromium.launch({executablePath:process.env.PWX});const errs=[];
for(const dev of ['m8c','x4pro','x4c']){console.log('==',dev);
const p=await b.newPage({viewport:{width:1500,height:1200},deviceScaleFactor:dev==='m8c'?2:1});p.on('pageerror',e=>errs.push(dev+' '+e.message));p.on('console',m=>{if(m.type()==='error')errs.push(dev+' '+m.text())});
await p.addInitScript(()=>{window.__noscale=1});await p.goto(prototypeURL+'?dev='+dev);await p.waitForTimeout(150);
const A=a=>p.evaluate(a=>window.__proto.act(a),a);const H=x=>p.evaluate(x=>window.__proto.hw(x),x);const E=(f,a)=>p.evaluate(f,a);
const txt=sel=>p.evaluate(s=>[...document.querySelectorAll('#screen '+s)].map(e=>e.innerText.replace(/\s+/g,' ').trim()),sel);
const dk=dev==='m8c'?'m8c':'x4';
// ---- rename: add a page, add a widget, auto-name, rename, pager shows it ----
await A('menu');await A('m:edit');await A('pageAdd');
const n0=await E(()=>{const S=window.__proto.S;return S.layouts[S.dev==='m8c'?'m8c':'x4'][S.page].name});ok(/^Page \d+$/.test(n0),'new page is "'+n0+'"');
await A('add:year');const n1=await E(()=>{const S=window.__proto.S;return S.layouts[S.dev==='m8c'?'m8c':'x4'][S.page].name});ok(n1==='Stats','first widget Year in reading auto-names it "'+n1+'"');
await A('desel');await A('rename');
if(dev==='m8c'){await p.fill('#pgname','Evenings');}else if(dev==='x4c'){await E(()=>{window.__proto.S.fk='rn-cyc';window.__proto.render()});await H('select');await H('select');}else{await A('rnset:Favourites');}
const want=await E(()=>window.__proto.S.modal.v);await A('rnsave');
const n2=await E(()=>{const S=window.__proto.S;return S.layouts[S.dev==='m8c'?'m8c':'x4'][S.page].name});ok(n2===want&&n2!=='Stats','renamed to "'+n2+'"');
await A('add:week');const n3=await E(()=>{const S=window.__proto.S;return S.layouts[S.dev==='m8c'?'m8c':'x4'][S.page].name});ok(n3===n2,'a hand-set name is never replaced ("'+n3+'")');
await A('editDone');const pg=await txt('.pager .pg.on');ok(pg.join(' ').includes(n2),'pager shows "'+pg.join(' ')+'"');
const headTxt=await E(()=>{const P=window.__proto;P.act('menu');P.act('m:edit');return document.querySelector('#screen [data-fk="ed-title"]').innerText.trim()});ok(headTxt===n2,'Edit Home header shows the page name and is the Rename target');
const sz=await E(()=>['ed-title','ed-rename'].map(k=>{const r=document.querySelector('#screen [data-fk="'+k+'"]').getBoundingClientRect();return Math.min(r.width,r.height)}));ok(sz.every(v=>v>=50),'rename targets ≥ 50 px: '+sz.join(', '));
await A('editDone');
// Settings > Home > Page names opens Edit Home with Rename ready
await A('nav:settings');await A('setg:home');await A('renamego');const rs=await E(()=>{const S=window.__proto.S;return S.edit&&S.modal&&S.modal.k==='rename'&&S.stack.length===1});ok(rs,'Settings › Home › Page names opens Edit Home with Rename open');
await A('closeModal');await A('editDone');
await p.locator('#screen').screenshot({path:O+dev+'-renamed-page.png'});
// ---- filter on a List screen: Recently added All ----
await E(()=>window.__proto.restart(window.__proto.S.dev));await A('nav:recent');await A('filter');
await A('fset:show:1');await A('fset:where:1');await A('fset:group:1');
const btn=(await txt('[data-fk="f-apply"]'))[0];const expect=await E(()=>Object.values(eval('B')).filter(b=>b.added<30&&b.prog==null&&!b.read&&b.dev).length);
ok(btn==='Show '+expect+' book'+(expect===1?'':'s'),'live count "'+btn+'" (expected '+expect+')');
await p.locator('#screen').screenshot({path:O+dev+'-filter-sheet.png'});
await A('fdone');const chips=await txt('[data-act^="fx:"]');ok(chips.join('|')==='Unread|On device|By author','chips: '+chips.join(' | '));
const sub=(await txt('.shdr small'))[0];ok(/Unread · on device · by author/.test(sub),'subtitle "'+sub+'"');
const filled=await E(()=>document.querySelector('#screen [data-fk="s-filter"]').innerHTML.includes('M4 5h16l-6.2 7.3v5.4l-3.6 1.8v-7.2z" fill'));ok(filled,'filter icon is filled when active');
await p.locator('#screen').screenshot({path:O+dev+'-filter-chips.png'});
await A('fx:group');const chips2=await txt('[data-act^="fx:"]');ok(chips2.length===2,'removing a chip removes that part ('+chips2.join(' | ')+')');
await A('fset:group:1');await A('filter');await A('fsave');
const tile=await E(()=>{const S=window.__proto.S;const L=S.layouts[S.dev==='m8c'?'m8c':'x4'];for(let i=0;i<L.length;i++){const t=L[i].tiles.find(t=>t.cfg&&t.cfg.fid);if(t)return {page:i,title:t.cfg.title}}return null});
ok(tile&&/Recently added · Unread/.test(tile.title),'saved as Book list "'+(tile&&tile.title)+'" on page '+(tile&&tile.page+1));
await A('fgo:'+tile.page);const onHome=await E(t=>[...document.querySelectorAll('#screen .tile .lab')].some(e=>e.innerText.includes(t)),tile.title);ok(onHome,'it appears on Home');
await p.locator('#screen').screenshot({path:O+dev+'-filter-saved-home.png'});
// ---- the same component in Search ----
await A('search');await A('sq:calder');await A('filter');const secs=await txt('.fsheet .cap');ok(secs.join(',')==='SHOW,WHERE,REFINE'||secs.join(',').startsWith('SHOW,WHERE,REFINE'),'search sheet sections: '+secs.join(','));
await A('lp:fsheet:1');const sortv=(await txt('[data-fk="f-sort"]'))[0];ok(/Best match/.test(sortv),'search sort defaults to Best match ('+sortv+')');
await A('lp:fsheet:-1');await A('fset:where:1');const sbtn=(await txt('[data-fk="f-apply"]'))[0];await A('fdone');
const schips=await txt('[data-act^="fx:"]');ok(schips.join('|')==='On device','search chips: '+schips.join(' | '));
const nres=await E(()=>document.querySelectorAll('#screen [data-fk^="row-"]').length);ok(sbtn==='Show '+nres+' book'+(nres===1?'':'s')||nres>0,'search results '+nres+' match "'+sbtn+'"');
await p.locator('#screen').screenshot({path:O+dev+'-search-filtered.png'});
await A('filter');await A('fsave');const st=await E(()=>{const S=window.__proto.S;return S.layouts[S.dev==='m8c'?'m8c':'x4'].flatMap(p=>p.tiles).filter(t=>t.cfg&&t.cfg.fid).map(t=>t.cfg.title+'|'+t.cfg.q)});ok(st.some(s=>/calder/.test(s)),'search filter saved as a Book list: '+st.join(' / '));
// ---- Book list source "Custom filter" uses the same sheet ----
await E(()=>window.__proto.restart(window.__proto.S.dev));await E(()=>{const P=window.__proto,S=P.S;S.edit=true;const L=S.layouts[S.dev==='m8c'?'m8c':'x4'][0];P.act('sel:'+L.tiles.findIndex(t=>t.cfg));});await A('cfg');await A('blpg:1');await A('blsrc:custom');
const isF=await E(()=>window.__proto.S.modal.k==='filter'&&!!window.__proto.S.modal.ret);ok(isF,'Source › Custom filter opens the filter sheet');
await A('fset:show:3');await A('fdone');const cf=await txt('[data-fk="cfg-filter"]');ok(/Finished/.test(cf[0]),'config shows the filter: '+cf[0]);await A('bldone');
// ---- round 4: grouped groups that show every book have no "All N"; no vendor names on any settings page; one version ----
await E(()=>window.__proto.restart(window.__proto.S.dev));await A('nav:recent');await A('grp:1');
const ghs=await E(()=>[...document.querySelectorAll('#screen .lrow')].filter(r=>r.querySelector('b')).map(r=>({t:r.innerText.replace(/\s+/g,' '),act:!!r.dataset.act,n:r.parentElement.querySelectorAll('[data-fk^="c-"],[data-fk*="-b"]').length})));
ok(ghs.length>0&&ghs.every(g=>!/All \d/.test(g.t)||g.act),'grouped headers: '+ghs.map(g=>g.t).join(' / '));
const vend=await E(()=>{const P=window.__proto,S=P.S;const bad=[];P.act('nav:settings');const gs=[...document.querySelectorAll('#screen [data-fk^="sg-"]')].map(e=>e.dataset.act);
 if(/BookOrbit|Tailscale|Grimmory/.test(document.querySelector('#screen').innerText))bad.push('settings');
 for(const g of gs){P.act(g);for(let pg=0;pg<4;pg++){const t=document.querySelector('#screen').innerText;const m=t.match(/BookOrbit|Tailscale|Grimmory|tailnet/g);if(m)bad.push(g+':'+m.join(','));const nx=document.querySelector('#screen [data-act^="lp:"][data-act$=":1"]');if(!nx||nx.classList.contains('dis'))break;P.act(nx.dataset.act);}P.act('back');}return bad;});
ok(vend.length===0,'no server or vendor names on settings pages '+JSON.stringify(vend));
const vers=await E(()=>{const P=window.__proto;P.act('nav:settings');const sum=[...document.querySelectorAll('#screen [data-fk^="sg-"]')].map(e=>e.innerText.replace(/\s+/g,' ')).filter(t=>/Updates|About/.test(t));P.act('setg:about');const ab=document.querySelector('#screen').innerText.match(/BookSync [0-9][^\n]*/g);P.act('back');P.act('setg:updates');const up=document.querySelector('#screen').innerText.match(/BookSync [0-9][^\n]*/g);return {sum,ab,up};});
ok(vers.ab.every(v=>v.trim()==='BookSync 0.12.0-rc.2 · RC')&&vers.up.every(v=>v.trim()==='BookSync 0.12.0-rc.2 · RC')&&vers.sum.some(t=>/RC channel · 0\.12\.0-rc\.2/.test(t))&&!vers.sum.some(t=>/^Updates.*rc\.2 · RC/.test(t)),'one installed version: '+JSON.stringify(vers));
// ---- Classic: buttons only ----
if(dev==='x4c'){await E(()=>window.__proto.restart('x4c'));await A('nav:recent');await E(()=>{window.__proto.S.fk='s-filter';window.__proto.render()});await H('select');
 const f0=await E(()=>window.__proto.S.fk||document.querySelector('#screen .kf').dataset.fk);ok(f0==='f-show-0','Classic: focus starts on Show › All ('+f0+')');
 await H('next');await H('select');await H('back');const c3=await txt('[data-act^="fx:"]');ok(c3.join('|')==='Unread','Classic: Next, Select, Back closes and applies ('+c3.join('|')+')');}
await p.close();}
console.log('PASS',pass,'FAIL',fail,'ERR',errs);await b.close();})();
