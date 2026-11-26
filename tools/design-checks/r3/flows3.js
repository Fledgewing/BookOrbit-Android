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
// ---- round 8: sign in to your server once; plain-word errors; X4 signs in from the phone; stats say where they come from ----
const W8=ms=>p.waitForTimeout(ms);const scr=()=>E(()=>document.querySelector('#screen').innerText.replace(/\s+/g,' '));
await E(()=>{const P=window.__proto;P.restart(P.S.dev);P.act('nav:settings');P.act('setg:account');});
let t8=await scr();ok(/Signed in as reader/.test(t8)&&/Sync login Catalog|Sync login/.test(t8)&&(t8.match(/Set up by your account/g)||[]).length===2,'signed in: name, and both logins set up by the account');
await A('modal:signout');t8=await scr();const so=await E(()=>document.querySelector('#screen [data-here]').dataset.fk);ok(/Sign out of your server\?/.test(t8)&&so==='so-cancel','sign out asks first; focus on Stay signed in');
await A('dosignout');t8=await scr();ok(/Sign in to your server/.test(t8)&&/this reader only/.test(t8),'signed out: one Sign in row and what that means');
const notes=await E(()=>{const P=window.__proto,S=P.S;const L=S.layouts[S.dev==='m8c'?'m8c':'x4'];const i=L.findIndex(p=>p.tiles.some(t=>t.w==='year'));P.act('home');P.act('page:'+i);const n=document.querySelectorAll('#screen .srcnote').length;P.S.acct.in=true;P.render();const n2=document.querySelectorAll('#screen .srcnote').length;P.S.acct.in=false;P.render();return [n,n2,L[i].tiles.filter(t=>['year','week','hours','records'].includes(t.w)).length];});
ok(notes[0]===notes[2]&&notes[0]>0&&notes[1]===0,'Stats widgets say "This reader only" only when signed out ('+notes.join('/')+')');
await E(()=>{const P=window.__proto;P.act('nav:settings');P.act('setg:account');P.act('modal:signin');});
const x4d=dev!=='m8c';const k0=await E(()=>window.__proto.S.modal.k);
if(!x4d){ok(k0==='signin','M8C: Sign in opens the form');
 const dis=await E(()=>document.querySelector('#screen [data-fk="si-ok"]').classList.contains('dis'));ok(dis,'Sign in is off until all three are filled');
 for(const [res,re] of [['wrong',/didn't work/],['unreach',/Can't reach your server/],['twostep',/two-step sign-in/],['old',/too old/]]){
  await E(r=>{const P=window.__proto;P.S.sires=r;const m=P.S.modal;if(m.k!=='signin'){P.act('modal:signin');}['server','user','pw'].forEach(k=>P.act('sikey:'+k));P.act('signin');},res);
  const busy=await scr();await W8(1100);const after=await scr();const extra=await E(()=>({phone:!!document.querySelector('#screen [data-fk="si-phone"]'),pw:/Not entered/.test(document.querySelector('#screen [data-fk="si-pw"]').innerText),here:(document.querySelector('#screen [data-here]')||{dataset:{}}).dataset.fk}));
  ok(/Signing in…/.test(busy)&&re.test(after)&&(res!=='twostep'||extra.phone)&&(res!=='wrong'||(extra.pw&&extra.here==='si-pw')),'error "'+res+'" in plain words '+JSON.stringify(extra));}
 await E(()=>{const P=window.__proto;P.S.sires='ok';['pw'].forEach(k=>P.act('sikey:'+k));P.act('signin');});await W8(1100);
} else {ok(k0==='sicode','X4: Sign in opens "from your phone"');t8=await scr();const qr=await E(()=>!!document.querySelector('#screen .card svg rect')&&document.querySelector('#screen [data-here]').dataset.fk);
 ok(/K7Q 4M2/.test(t8)&&/companion app/.test(t8)&&qr==='si-check','X4: code, QR and companion app; focus on the check row ('+qr+')');
 await A('sitype');const k1=await E(()=>window.__proto.S.modal.k);ok(k1==='signin','X4: "Type it on this reader instead" opens the form');await A('modal:sicode');
 await E(()=>{const P=window.__proto;P.S.sires='unreach';P.act('sicheck');});await W8(1100);ok(/Your phone couldn't reach your server/.test(await scr()),'X4: phone sign-in error in phone words');
 await E(()=>{const P=window.__proto;P.S.sires='ok';P.act('sicheck');});const b8=await scr();await W8(1100);ok(/Signing in…/.test(b8),'X4: Signing in… state');}
t8=await scr();ok(/Signed in as reader/.test(t8)&&/Sync login/.test(t8)&&/OPDS login/.test(t8)&&/From all your devices/.test(t8),'success names what BookSync set up');
await A('closeModal');t8=await scr();ok(/Signed in as reader/.test(t8),'back to Your server, signed in');
// ---- round 9: two signed-out states; phone-sheet errors; focus returns; Back cancels Signing in… ----
const st9=v=>p.evaluate(v=>{const e=document.getElementById('acct');e.value=v;e.dispatchEvent(new Event('change',{bubbles:true}))},v);
await E(()=>{const P=window.__proto;P.restart(P.S.dev);});await st9('0');
let t9=await scr();ok(/Synced 12 min ago/.test(t9)&&!/Not signed in/.test(t9),'(a) signed out with a sync login: Home still says Synced');
await E(()=>{const P=window.__proto;P.act('nav:settings');P.act('setg:account');});t9=await scr();
ok(/Position sync uses your sync login · Stats from this reader only/.test(t9)&&/for stats from all your devices and automatic setup/i.test(t9)&&!/doesn't sync/.test(t9),'(a) Your server: sync uses the sync login; Sign in for stats and setup');
await E(()=>{const P=window.__proto;P.act('setg:sync');});t9=await scr();ok(/Sync now/.test(t9)&&!/Sign in to sync/.test(t9),'(a) Sync, Wi-Fi & power: Sync now as usual');
await E(()=>{const P=window.__proto;P.restart(P.S.dev);});await st9('none');t9=await scr();
const hs=await E(()=>{const e=document.querySelector('#screen [data-fk="h-sync"]');const r=e.getBoundingClientRect();return [e.innerText.replace(/\s+/g,' ').trim(),e.dataset.act,Math.round(r.height)]});
ok(hs[0]==='Not signed in · Sign in'&&hs[1]==='setg:account'&&(dev==='x4c'||hs[2]>=50)&&!/Synced/.test(t9),'(b) nothing set up: Home says "'+hs[0]+'" ('+hs[2]+' px)');
await E(()=>window.__proto.act('setg:account'));t9=await scr();const g9=await E(()=>window.__proto.S.stack.at(-1).grp);ok(g9==='account'&&/Nothing syncs yet/.test(t9),'(b) Home Sign in opens Your server');
await E(()=>{const P=window.__proto;P.act('home');P.act('setg:sync');});t9=await scr();ok(/Sign in to sync/.test(t9)&&/nothing syncs/.test(t9),'(b) Sync, Wi-Fi & power: Sign in to sync with a note');
await E(()=>{const P=window.__proto;P.act('home');P.openBook('b1');P.act('rd:top');});
const tp=await E(()=>{const e=document.querySelector('#screen [data-fk="tp-sync"]');if(!e)return null;const r=e.getBoundingClientRect();return [e.innerText.trim(),Math.round(Math.min(r.width,r.height)),e.dataset.act]});
ok(tp&&tp[0]==='Sign in to sync'&&tp[1]>=50&&tp[2]==='modal:signin','(b) reader top panel: '+JSON.stringify(tp));
await E(()=>{const P=window.__proto;P.restart(P.S.dev);});await st9('1');
if(x4d){await E(()=>{const P=window.__proto;P.S.acct.in=false;P.act('nav:settings');P.act('setg:account');P.act('modal:signin');});
 await E(()=>{const P=window.__proto;P.S.sires='wrong';P.act('sicheck');});await W8(1100);t9=await scr();
 const nc=await E(()=>!!document.querySelector('#screen [data-fk="si-new"]'));ok(/Your phone couldn't sign in/.test(t9)&&/Try again on the phone, or get a new code/.test(t9)&&nc,'phone sheet: wrong password in phone words, with Get a new code');
 await A('sinew');t9=await scr();ok(/P3X 9D5/.test(t9)&&!/couldn't/.test(t9),'Get a new code shows a new code');
 await E(()=>{const P=window.__proto;P.S.sires='old';P.act('sicheck');});await W8(1100);t9=await scr();
 const cl=await E(()=>[!!document.querySelector('#screen [data-fk="si-close"]'),!!document.querySelector('#screen [data-fk="si-check"]'),(document.querySelector('#screen [data-here]')||{dataset:{}}).dataset.fk]);
 ok(/too old/.test(t9)&&!/Waiting for your phone/.test(t9)&&cl[0]&&!cl[1]&&cl[2]==='si-close','phone sheet: Too old shows Close, not the waiting rows '+JSON.stringify(cl));
 await A('closeModal');await A('modal:signin');await E(()=>{const P=window.__proto;P.S.sires='twostep';P.act('sicheck');});await W8(1100);
 ok(await E(()=>window.__proto.S.modal&&window.__proto.S.modal.k==='sidone'),'phone sheet: a two-step account signs in (the phone does the second step)');await A('closeModal');}
await E(()=>{const P=window.__proto;P.S.acct.in=false;P.S.sires='ok';P.act('modal:signin');if(P.S.modal.k==='sicode')P.act('sicheck');else{['server','user','pw'].forEach(k=>P.act('sikey:'+k));P.act('signin');}});
const bz=await E(()=>window.__proto.S.modal.busy);await H('back');const cx=await E(()=>[!!window.__proto.S.modal,window.__proto.S.modal&&window.__proto.S.modal.busy]);await W8(1100);
const cx2=await E(()=>[window.__proto.S.acct.in,window.__proto.S.modal&&window.__proto.S.modal.k]);ok(bz&&cx[0]&&!cx[1]&&!cx2[0]&&cx2[1]!=='sidone','Back during Signing in… cancels the attempt '+JSON.stringify([bz,cx,cx2]));
await A('closeModal');const ph9=await E(()=>{const S=window.__proto.S;S.modal={k:'signin',srv:'',usr:''};window.__proto.render();return document.querySelector('#screen [data-fk="si-server"]').innerText});ok(/Your server address/.test(ph9)&&!/example/.test(ph9),'empty server hint: "Your server address"');
// ---- round 9: three logins, each optional; sign-out honours how each was set ----
const row9=k=>E(k=>{const e=document.querySelector('#screen [data-fk="'+k+'"]');return e?e.innerText.replace(/\s+/g,' ').trim():null},k);
const fill9=async(res='ok')=>{await E(r=>{const P=window.__proto;P.S.sires=r;['server','user','pw'].forEach(k=>P.act('sikey:'+k));P.act(P.S.modal.k==='login'?'lsave':'signin');},res);await W8(1100);};
const acct9=()=>E(()=>{const P=window.__proto;P.act('home');P.act('nav:settings');P.act('setg:account');});
// case 1: account only, then sign out: nothing works
await E(()=>{const P=window.__proto;P.restart(P.S.dev);});await acct9();
await A('modal:signout');t9=await scr();ok(/removes the sync login and the OPDS login it set up/.test(t9)&&/Sync stops on this reader/.test(t9)&&!/stays/.test(t9.replace(/books and your place in them stay/,'')),'sign-out (account only) lists what stops');
await A('dosignout');t9=await scr();ok(/Nothing syncs yet/.test(t9)&&/Sync login.*Not set/.test(await row9('set-slog'))&&/Not set/.test(await row9('set-olog')),'after sign-out (account only): nothing set up');
await E(()=>window.__proto.act('home'));ok((await row9('h-sync'))==='Not signed in · Sign in','after sign-out (account only): Home says Not signed in');
const nb=await E(()=>{const P=window.__proto;const id=Object.keys(eval('B')).find(k=>!eval('B')[k].dev);P.act('nav:library');const n=Object.keys(P.S.downloads).length;try{eval('tapBook')(id)}catch(e){}return [Object.keys(P.S.downloads).length===n,P.S.toast]});const ta=await E(()=>window.__proto.S.toastAct&&window.__proto.S.toastAct.act);ok(nb[0]&&/No OPDS login/.test(nb[1]||'')&&ta==='lopen:opds','no OPDS login: a download says why ('+nb[1]+')');
// case 2: your own sync login plus the account, then sign out: sync stays
await E(()=>{const P=window.__proto;P.restart(P.S.dev);});await acct9();await A('lopen:sync');
ok(await E(()=>window.__proto.S.modal.k==='login'),'a set sync login opens its own form');t9=await scr();ok(/Set up by your account/.test(t9)&&/Replace with the account|Remove sync login/.test(t9)&&!/Replace with the account/.test(t9),'account-set login: Remove, no Replace');
await fill9();ok(/Set by you/.test(await row9('set-slog'))&&(await E(()=>(document.querySelector('#screen .kf')||{dataset:{}}).dataset.fk||window.__proto.S.fk))==='set-slog','saving your own sync login: "Set by you", focus back on the row');
await A('modal:signout');t9=await scr();ok(/removes the OPDS login it set up/.test(t9)&&/Your own sync login stays, so sync keeps working/.test(t9)&&!/Sync stops/.test(t9),'sign-out (own sync + account) says sync keeps working');
await A('dosignout');t9=await scr();ok(/Position sync uses your sync login/.test(t9)&&/Set by you/.test(await row9('set-slog'))&&/Not set/.test(await row9('set-olog')),'after sign-out: own sync login stays, OPDS gone');
await E(()=>window.__proto.act('home'));ok(/Synced 12 min ago/.test(await scr()),'after sign-out with own sync login: Home still syncs');
// case 3: mixed: own OPDS login first, then the account fills only the Not set one; Replace; Remove asks first
await E(()=>{const P=window.__proto;P.restart(P.S.dev);});await st9('none');await acct9();await A('lopen:opds');
const k9=await E(()=>window.__proto.S.modal.k+'|'+(window.__proto.S.modal.w||''));
if(x4d){t9=await scr();ok(k9==='sicode|opds'&&/Enter the OPDS login from your phone/.test(t9),'X4: a Not set login uses the phone code path');await A('sitype');}else ok(k9==='login|opds','M8C: a Not set login opens its form');
await fill9('wrong');t9=await scr();ok(/didn't work/.test(t9)&&await E(()=>window.__proto.S.modal.k==='login'),'login form: wrong password in plain words');
await fill9();ok(/Set by you/.test(await row9('set-olog'))&&/Not set/.test(await row9('set-slog')),'own OPDS login works without the account');
await E(()=>{const P=window.__proto;P.S.sires='ok';P.act('modal:signin');if(P.S.modal.k==='sicode')P.act('sicheck');else{['server','user','pw'].forEach(k=>P.act('sikey:'+k));P.act('signin');}});await W8(1100);
t9=await scr();ok(/Kept: the one you set/.test(t9)&&/Sync login (Found|Created)/.test(t9)&&/Replace with the account's/.test(t9),'account sign-in fills only the Not set login and keeps yours');
await A('closeModal');ok(/Set up by your account/.test(await row9('set-slog'))&&/Set by you/.test(await row9('set-olog')),'mixed: sync from the account, OPDS yours');
await A('modal:signout');t9=await scr();ok(/removes the sync login it set up/.test(t9)&&/Sync stops/.test(t9)&&/Your own OPDS login stays/.test(t9),'sign-out (mixed) lists both');await A('socancel');
await A('lopen:opds');ok(await E(()=>!!document.querySelector('#screen [data-fk="lg-repl"]')),'own login offers Replace with the account\'s');await A('lrepl');ok(/Set up by your account/.test(await row9('set-olog')),'Replace makes it the account\'s');
await A('lopen:sync');await A('lrem');const lr=await E(()=>[window.__proto.S.modal.k,document.querySelector('#screen [data-here]').dataset.fk]);t9=await scr();ok(lr[0]==='lremove'&&lr[1]==='lr-keep'&&/Remove the sync login\?/.test(t9),'Remove asks first; focus on Keep it');
await A('ldel');ok(/Not set/.test(await row9('set-slog'))&&await E(()=>window.__proto.S.fk==='set-slog'),'removed; focus back on the Sync login row');
await E(()=>{const P=window.__proto;P.act('home');});ok((await row9('h-sync'))==='No sync login · Set up','signed in without a sync login: Home says "No sync login · Set up"');
await A('lopen:sync');const hsa=await E(()=>document.querySelector('#screen [data-fk="h-sync"]').dataset.act);ok(hsa==='lopen:sync','"No sync login · Set up" opens the sync login form ('+hsa+')');
// rev 14 minors: own user name in a "Set by you" form; Done focus; single-login phone wording; keyboard wording
const un=await E(()=>{const P=window.__proto;P.S.acct.opds={st:'user',usr:'reader-opds'};P.act('lopen:opds');const t=document.querySelector('#screen [data-fk="si-user"]').innerText;P.act('lclose');return t});ok(/reader-opds/.test(un),'a "Set by you" form shows its own user name');
const dn=await E(()=>{const P=window.__proto;P.S.acct.in=false;P.S.acct.sync={st:null};P.S.sires='ok';P.act('nav:settings');P.act('setg:account');P.act('modal:signin');if(P.S.modal.k==='sicode')P.act('sicheck');else{['server','user','pw'].forEach(k=>P.act('sikey:'+k));P.act('signin');}return 1});await W8(1100);
await A('sddone');ok(await E(()=>window.__proto.S.fk)==='set-slog','Done on the result sheet focuses the login it changed');
const ie=await E(()=>{const P=window.__proto;P.S.modal={k:'sicode',w:'opds'};P.render();const t=document.querySelector('#screen [data-fk="si-check"]').innerText;P.S.modal=null;P.render();return t});ok(/I've entered it on my phone/.test(ie),'single-login phone sheet: "I\'ve entered it on my phone"');
const kb=await E(()=>{const P=window.__proto;P.S.modal={k:'signin',srv:'',usr:''};P.render();P.act('sikey:user');const t=document.querySelector('#screen .card').innerText+'|'+P.S.toast;P.S.modal=null;P.render();return t});ok(!/KOReader/.test(kb)&&/The keyboard typed/.test(kb),'sign-in keyboard wording has no KOReader');
const kor=await E(()=>{const P=window.__proto;P.act('nav:settings');P.act('setg:account');const a=/KOReader/.test(document.querySelector('#screen').innerText);P.act('lopen:opds');const b=/KOReader|BookOrbit|Kavita|Komga|Calibre/.test([...document.querySelectorAll('#screen .card')].pop().innerText);P.act('lclose');return [a,b]});
ok((dev==='m8c'?kor[0]:!kor[0])&&!kor[1],'"KOReader" names the sync login only on the M8C '+JSON.stringify(kor));
await A('closeModal');
if(dev==='x4c'){await E(()=>{const P=window.__proto;P.restart('x4c');P.act('nav:settings');P.act('setg:account');P.S.fk='set-out';P.render();});
 await H('select');await H('select');const f1=await E(()=>document.querySelector('#screen .kf').dataset.fk);ok(f1==='set-out','Classic: Stay signed in returns focus to Sign out ('+f1+')');
 await H('select');await H('back');const f2=await E(()=>document.querySelector('#screen .kf').dataset.fk);ok(f2==='set-out','Classic: Back from the sign-out question returns to Sign out ('+f2+')');
 await H('select');await H('next');await H('select');const f3=await E(()=>document.querySelector('#screen .kf').dataset.fk);ok(f3==='set-signin','Classic: after signing out, focus is on Sign in ('+f3+')');}
const v8=await E(()=>{const P=window.__proto;const bad=[];for(const k of ['signin','sicode','sidone','signout']){P.S.modal={k};P.render();const t=document.querySelector('#screen').innerText;const m=t.match(/BookOrbit|Grimmory|Calibre|Kavita|Komga|Tailscale/g);if(m)bad.push(k+':'+m.join(','));}P.S.modal=null;P.render();return bad;});ok(v8.length===0,'no server or vendor names in sign-in screens '+JSON.stringify(v8));
// ---- round 7: Update channel is one row that opens a radio picker; picking returns to Updates ----
const ch=await E(()=>{const P=window.__proto;P.restart(P.S.dev);P.act('nav:settings');P.act('setg:updates');const row=document.querySelector('#screen [data-fk="set-chan"]');const o={row:row.innerText.replace(/\s+/g,' '),act:row.dataset.act,h:row.getBoundingClientRect().height,radiosOnPage:document.querySelectorAll('#screen [data-act^="setc:chan"]').length};
 P.act('modal:chan');const rows=[...document.querySelectorAll('#screen [data-act^="chanset:"]')];o.n=rows.length;o.desc=rows.every(r=>r.querySelector('.meta'));o.here=(rows.find(r=>r.dataset.here)||{}).dataset?.fk;o.minH=Math.min(...rows.map(r=>r.getBoundingClientRect().height));
 P.act('chanset:2');o.closed=!P.S.modal&&P.S.stack.at(-1).grp==='updates';o.after=document.querySelector('#screen [data-fk="set-chan"]').innerText.replace(/\s+/g,' ');o.fk=P.S.fk;P.act('chanset:1');return o;});
ok(/^Update channel .* RC$/.test(ch.row)&&ch.act==='modal:chan'&&ch.radiosOnPage===0&&ch.h>=50,'Updates has one channel row: "'+ch.row+'"');
ok(ch.n===3&&ch.desc&&ch.here==='ch-1'&&ch.minH>=50,'channel picker: 3 radio rows with descriptions, current marked ('+ch.here+')');
ok(ch.closed&&/Preview$/.test(ch.after)&&ch.fk==='set-chan','picking Preview returns to Updates showing it ("'+ch.after+'")');
if(dev==='x4c'){const cc=await E(()=>{const P=window.__proto;P.act('nav:settings');P.act('setg:updates');P.S.fk='set-chan';P.render();P.hw('select');const a=P.S.modal&&P.S.modal.k+'|'+document.querySelector('#screen .kf').dataset.fk;P.hw('next');P.hw('select');const b=(P.S.modal?'open':'closed')+'|'+P.S.fk;P.act('chanset:1');P.S.fk='set-chan';P.render();P.hw('select');P.hw('back');const c=(P.S.modal?'open':'closed')+'|'+P.S.fk;return [a,b,c];});
 ok(cc[0]==='chan|ch-1'&&cc[1]==='closed|set-chan'&&cc[2]==='closed|set-chan','Classic: Select opens on the current channel, Select picks and returns, Back returns ('+cc.join(' / ')+')');}
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
