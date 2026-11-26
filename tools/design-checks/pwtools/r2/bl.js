const {prototypeURL, OUT}=require('../../runtime.js');
const {chromium}=require('playwright');

(async()=>{const b=await chromium.launch({executablePath:process.env.PWX});const res=[],errs=[];const ok=(n,c,x)=>res.push((c?'PASS ':'FAIL ')+n+(x?' ('+x+')':''));
for(const dev of ['m8c','x4pro','x4c']){const p=await b.newPage({viewport:{width:1500,height:1150}});p.on('pageerror',e=>errs.push(dev+': '+e.message));p.on('console',m=>{if(m.type()==='error')errs.push(dev+': '+m.text())});
 await p.goto(prototypeURL+'?dev='+dev);await p.waitForTimeout(150);
 const fk=k=>p.click(`#screen [data-fk="${k}"]`);const has=s=>p.locator('#screen '+s).count().then(n=>n>0);const S=f=>p.evaluate(f);
 const kinds=await S(()=>{const S=window.__proto.S;return [...new Set(Object.values(S.layouts).flat().flatMap(pg=>pg.tiles.map(t=>t.w)))];});
 ok(dev+' no recent/wtr/also widget types remain in layouts',!kinds.some(k=>['recent','wtr','also'].includes(k)),kinds.join(','));
 // add a Book list from the picker, configure it to the Short reads list with a title
 await S(()=>{const P=window.__proto;P.act('home');P.act('m:edit');P.act('pageAdd');});await fk('ed-add');let found=false;for(let i=0;i<4&&!found;i++){found=await has('[data-fk="add-booklist"]');if(!found)await S(()=>window.__proto.act('lp:picker:1'));}ok(dev+' picker offers Book list',found);
 await fk('add-booklist');ok(dev+' Book list opens its configuration at once',await has('[data-fk="cfg-src"]'));
 await fk('cfg-src');await p.locator('#screen [data-fk="src-lists1"]').click().catch(async()=>{await S(()=>window.__proto.act('lp:blsrc:1'));await fk('src-lists1');});
 ok(dev+' source set to Short reads',await S(()=>window.__proto.S.modal.cfg.src==='list:s1'));
 if(dev==='x4c'){await fk('cfg-title');await fk('cfg-title');}else{await p.fill('#blt','Quick picks');}
 await fk('cfg-style-1');await fk('cfg-done');
 const tl=await S(()=>{const S=window.__proto.S;const pg=S.layouts[S.dev==='m8c'?'m8c':'x4'][S.page];return pg.tiles[pg.tiles.length-1];});
 ok(dev+' tile is a configured Book list',tl.w==='booklist'&&tl.cfg.src==='list:s1'&&tl.cfg.style===1,JSON.stringify(tl.cfg));
 if(dev!=='x4c')ok(dev+' title saved',tl.cfg.title==='Quick picks');
 ok(dev+' Configure in the toolbar',await has('[data-fk="ed-cfg"]'));
 await S(()=>window.__proto.act('editDone'));const ttl=await S(()=>[...document.querySelectorAll('#screen .tile .lab')].pop().innerText);ok(dev+' widget shows its title',ttl===tl.cfg.title,ttl);
 await p.locator('#screen [data-fk^="bl"][data-fk$="-all"]').last().click();ok(dev+' All opens the shared List screen with the filter button',await has('[data-fk="s-filter"]'));await fk('s-filter');
 await S(()=>{window.__proto.act('grp:1');window.__proto.act('fdone')});const heads=await p.locator('#screen .lrow:has(> b)').count();ok(dev+' grouped by author shows author headers',heads>=2,heads);
 await S(()=>window.__proto.act('grp:2'));ok(dev+' grouped by series shows series headers',await has('[data-fk="gh-tide"]')||await has('[data-fk^="gh-"]'));
 await S(()=>{const P=window.__proto;P.act('home');P.act('nav:serieslist');});ok(dev+' Library Series link opens the Library list grouped by series',await S(()=>{const c=window.__proto.S.stack.at(-1);return c.n==='list'&&c.src==='all'&&c.group===2;}));
 await p.close();}
console.log(res.join('\n'));console.log('ERRORS:',errs.join('\n')||'none');await b.close();})();
