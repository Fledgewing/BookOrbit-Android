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
const one=await E(()=>{const sh=document.querySelector('#screen .fsheet');const r=sh.getBoundingClientRect();const rows=[...sh.querySelectorAll('[data-act^="fpickopen:"]')];const foot=sh.querySelector('[data-fk="f-apply"]').getBoundingClientRect();
 return {rows:rows.length,allPick:[...sh.querySelectorAll('.lrow')].filter(e=>e.dataset.fk&&e.dataset.fk.startsWith('f-')&&e.dataset.fk!=='f-save').every(e=>/^fpickopen:/.test(e.dataset.act)),
  fcyc:sh.querySelectorAll('[data-act^="fcyc"],[data-act^="fsort"],[data-act^="fdir"],[data-act^="ftog"],.sg').length,paged:!!sh.querySelector('[data-act^="lp:fsheet"]'),
  minH:Math.min(...rows.map(e=>e.getBoundingClientRect().height)),fits:rows.every(e=>e.getBoundingClientRect().bottom<=foot.top)&&r.bottom<=document.querySelector('#screen').getBoundingClientRect().bottom,
  bold:rows.filter(e=>e.querySelector('.fdot')).map(e=>e.dataset.fk)};});
ok(one.rows===9&&one.allPick&&one.fcyc===0&&!one.paged&&one.minH>=50&&one.fits,'one screen: '+JSON.stringify(one));
ok(one.bold.join(',')==='f-show,f-where,f-gs','changed rows are marked: '+one.bold.join(','));
for(const k of ['show','where','len','rate','added']){const pk=await E(k=>{const P=window.__proto;P.act('fpickopen:'+k);const rows=[...document.querySelectorAll('#screen .fsheet .lrow[data-act^="fone:"]')];const r={n:rows.length,counts:rows.every(e=>/\d\s*$/.test(e.innerText.trim())),radio:rows.length>1};P.act('fpickdone');return r;},k);ok(pk.n>1&&pk.counts,'picker '+k+': '+pk.n+' radio rows with counts');}
for(const k of ['authors','series','tags']){const pk=await E(k=>{const P=window.__proto;P.act('fpickopen:'+k);const n=document.querySelectorAll('#screen .fsheet .lrow[data-act^="fpick:"]').length;P.act('fpickdone');return n;},k);ok(pk>1,'picker '+k+': '+pk+' checkbox rows');}
const gs=await E(()=>{const P=window.__proto;P.act('fpickopen:gs');const r={rows:document.querySelectorAll('#screen .fsheet .lrow').length,paged:!!document.querySelector('#screen [data-act^="lp:fpickgs"]'),caps:[...document.querySelectorAll('#screen .fsheet .cap')].map(e=>e.innerText)};P.act('fpickdone');return r;});ok(!gs.paged&&gs.caps.join(',')==='GROUP,SORT BY,ORDER','Group & sort picker on one page: '+JSON.stringify(gs));
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
await A('search');await A('sq:calder');await A('filter');const secs=await txt('.fsheet [data-act^="fpickopen:"] > span:first-child');ok(secs.join(',')==='Show,Where,Author,Series,Tags,Length,Rating,Added,Group & sort','search sheet rows: '+secs.join(','));
const sortv=(await txt('[data-fk="f-gs"]'))[0];ok(/Best match/.test(sortv),'search sort defaults to Best match ('+sortv+')');
await A('fset:where:1');const sbtn=(await txt('[data-fk="f-apply"]'))[0];await A('fdone');
const schips=await txt('[data-act^="fx:"]');ok(schips.join('|')==='On device','search chips: '+schips.join(' | '));
const nres=await E(()=>document.querySelectorAll('#screen [data-fk^="row-"]').length);ok(sbtn==='Show '+nres+' book'+(nres===1?'':'s')||nres>0,'search results '+nres+' match "'+sbtn+'"');
await p.locator('#screen').screenshot({path:O+dev+'-search-filtered.png'});
await A('filter');await A('fsave');const st=await E(()=>{const S=window.__proto.S;return S.layouts[S.dev==='m8c'?'m8c':'x4'].flatMap(p=>p.tiles).filter(t=>t.cfg&&t.cfg.fid).map(t=>t.cfg.title+'|'+t.cfg.q)});ok(st.some(s=>/calder/.test(s)),'search filter saved as a Book list: '+st.join(' / '));
// ---- Book list source "Custom filter" uses the same sheet ----
await E(()=>window.__proto.restart(window.__proto.S.dev));await E(()=>{const P=window.__proto,S=P.S;S.edit=true;const L=S.layouts[S.dev==='m8c'?'m8c':'x4'][0];P.act('sel:'+L.tiles.findIndex(t=>t.cfg));});await A('cfg');await A('blpg:1');await A('blsrc:custom');
const isF=await E(()=>window.__proto.S.modal.k==='filter'&&!!window.__proto.S.modal.ret);ok(isF,'Source › Custom filter opens the filter sheet');
await A('fset:show:3');await A('fdone');const cf=await txt('[data-fk="cfg-filter"]');ok(/Finished/.test(cf[0]),'config shows the filter: '+cf[0]);await A('bldone');
// ---- round 6: checkbox counts follow the other filters; zero last; one count source; no dead page bar; Where hidden in On device ----
const r6=await E(()=>{const P=window.__proto;P.restart(P.S.dev);P.act('nav:library');P.act('filter');
 const apply=()=>+(document.querySelector('#screen [data-fk="f-apply"]').innerText.match(/[\d,]+/)||['0'])[0].replace(/,/g,'');
 const sub=()=>+document.querySelector('#screen .shdr small').innerText.match(/[\d,]+/)[0].replace(/,/g,'');
 const picks=k=>{P.act('fpickopen:'+k);const rows=[...document.querySelectorAll('#screen .fsheet .lrow[data-act^="fpick:"]')].map(e=>({v:e.dataset.act.slice(6),n:+((e.innerText.match(/(\d+)\s*$/)||[0,0])[1]),z:e.classList.contains('fzero')}));const pb=!!document.querySelector('#screen [data-act^="lp:fpick"]');const pages=(document.querySelector('#screen .fsheet')||{innerText:''}).innerText.match(/Page \d+ of (\d+)/);P.act('fpickdone');return {rows,pb,pages:pages?+pages[1]:1};};
 const out={};const a0=picks('authors');out.footer0=apply();P.act('fdone');out.sub0=sub();P.act('filter');
 // every book has one author: on one page of authors the counts must sum to the footer when the picker fits a page
 out.sum0=a0.pages===1?a0.rows.reduce((x,r)=>x+r.n,0):null;out.pb0=a0.pb;out.pages0=a0.pages;
 const se=picks('series');out.seriesPB=se.pb;out.seriesPages=se.pages;
 P.act('fone:len:1');const a1=picks('authors');out.footer1=apply();
 const f=P.S.stack.at(-1).f;const lib=eval('fBase')(P.S.stack.at(-1));const expect=v=>eval('fApply')(lib,{...f,authors:[]}).filter(b=>b.a===v).length;
 out.match=a1.rows.every(r=>r.z?expect(r.v)===0:r.n===expect(r.v));
 const zi=a1.rows.findIndex(r=>r.z);out.zeroLast=zi<0||a1.rows.slice(zi).every(r=>r.z);out.zeros=a1.rows.filter(r=>r.z).length;out.zeroNoNum=document.querySelectorAll('#screen .fsheet .fzero .num').length===0;
 // a ticked value always stays, even at zero
 const zv=a1.rows.find(r=>r.z);if(zv){P.act('fpickopen:authors');P.act('fpick:'+zv.v);const keep=[...document.querySelectorAll('#screen .fsheet .lrow[data-act^="fpick:"]')].some(e=>e.dataset.act==='fpick:'+zv.v);out.tickedKept=keep;P.act('fpickdone');}
 P.act('fdone');P.act('home');P.act('nav:device');P.act('filter');out.whereInDevice=!!document.querySelector('#screen [data-fk="f-where"]');P.act('fdone');
 return out;});
ok(r6.footer0===r6.sub0,'one count source: footer '+r6.footer0+' = list subtitle '+r6.sub0);
ok(r6.sum0===null||r6.sum0===r6.footer0,'unfiltered author counts add up to the footer ('+r6.sum0+' / '+r6.footer0+', pages '+r6.pages0+')');
ok(r6.pages0>1||!r6.pb0,'author picker has a page bar only when it has pages ('+r6.pages0+')');ok(r6.seriesPages===1&&!r6.seriesPB,'series picker: one page, no page bar');
ok(r6.match,'author counts follow the other filters (Length = Short; footer '+r6.footer1+')');
ok(r6.zeroLast&&r6.zeroNoNum,'zero-count authors sort last with no number ('+r6.zeros+' zero)');ok(r6.zeros===0||r6.tickedKept,'a ticked zero-count author stays listed');
ok(!r6.whereInDevice,'Where is hidden inside On device');
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
 const f0=await E(()=>window.__proto.S.fk||document.querySelector('#screen .kf').dataset.fk);ok(f0==='f-show','Classic: focus starts on the Show row ('+f0+')');
 await H('select');const pk=await E(()=>window.__proto.S.modal.pick+'|'+(window.__proto.S.fk||document.querySelector('#screen .kf').dataset.fk));ok(pk==='show|fp-show-0','Classic: Select opens the Show picker on the current choice ('+pk+')');
 await H('next');await H('select');const back=await E(()=>!window.__proto.S.modal.pick&&window.__proto.S.fk);ok(back==='f-show','Classic: choosing returns to the Show row ('+back+')');
 await H('next');await H('select');await H('back');const bk2=await E(()=>window.__proto.S.modal&&!window.__proto.S.modal.pick&&window.__proto.S.fk);ok(bk2==='f-where','Classic: Back closes a picker first ('+bk2+')');
 await H('back');const c3=await txt('[data-act^="fx:"]');ok(c3.join('|')==='Unread','Classic: Back then closes the sheet and applies ('+c3.join('|')+')');}
await p.close();}
console.log('PASS',pass,'FAIL',fail,'ERR',errs);await b.close();})();
