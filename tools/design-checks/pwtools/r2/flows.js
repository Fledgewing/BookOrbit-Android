const {prototypeURL, OUT}=require('../../runtime.js');
const {chromium}=require('playwright');

(async()=>{const b=await chromium.launch({executablePath:process.env.PWX});const res=[],errs=[];const ok=(n,c,x)=>res.push((c?'PASS ':'FAIL ')+n+(x?' ('+x+')':''));
for(const dev of ['m8c','x4pro','x4c']){const p=await b.newPage({viewport:{width:1500,height:1150}});p.on('pageerror',e=>errs.push(dev+': '+e.message));p.on('console',m=>{if(m.type()==='error')errs.push(dev+': '+m.text())});
 await p.goto(prototypeURL+'?dev='+dev);await p.waitForTimeout(150);
 const fk=k=>p.click(`#screen [data-fk="${k}"]`);const has=s=>p.locator('#screen '+s).count().then(n=>n>0);const txt=()=>p.locator('#screen').innerText().then(t=>t.toLowerCase());
 const S=f=>p.evaluate(f);
 ok(dev+' no "Smart scope" text anywhere on Home',!(await txt()).toLowerCase().includes('smart scope'));
 await fk('h-menu');ok(dev+' menu says Manage lists',(await txt()).includes('manage lists'));await fk('m-settings');ok(dev+' menu opens BookSync settings',await has('[data-fk="sg-reading"]'));
 const groups=await p.locator('#screen [data-fk^="sg-"]').count();ok(dev+' settings groups on one page',groups===8,groups);
 await fk('sg-reading');const f0=await S(()=>window.__proto.S.layouts&&document.querySelector('#screen [data-fk="set-font2"]').innerText);await fk('set-font2');const f1=await S(()=>document.querySelector('#screen [data-fk="set-font2"]').innerText);ok(dev+' Your font cycles',f0!==f1,f1.replace(/\n/g,' '));
 await fk('back');await fk('sg-account');await fk('set-resign');ok(dev+' re-sign-in sheet',await has('[data-fk="si-ok"]'));await fk('si-pw');await fk('si-ok');await p.waitForTimeout(1100);ok(dev+' sign-in result names what was set up',(await txt()).includes('opds login'));await fk('sd-ok');await fk('back');
 await fk('sg-library');await fk('set-refresh');await p.waitForTimeout(700);ok(dev+' full refresh shows progress',(await txt()).includes('refreshing'));await p.waitForTimeout(3500);
 await fk('set-storage');ok(dev+' storage page from settings',(await txt()).includes('free up space'));await fk('st-finished');ok(dev+' remove finished asks to confirm and keeps server copies',(await txt()).includes('stay in your library on the server'));await fk('cf-cancel');await fk('back');await fk('back');
 if(dev==='m8c'){await fk('sg-about');ok('m8c companion link (Android only)',await has('[data-fk="set-comp"]'));await fk('back');}
 else {await fk('sg-about');ok(dev+' no companion link on X4',!(await has('[data-fk="set-comp"]')));await fk('back');}
 await fk('sg-sync');await S(()=>window.__proto.act('nav:battery'));ok(dev+' battery page from settings',(await txt()).includes('how the estimate is made'));
 for(const i of [1,2,3]){await fk('bt-'+i);}ok(dev+' battery charges tab',(await txt()).includes('last 5 charges'));
 await fk('bt-0');ok(dev+(dev==='m8c'?' compare offered':' compare hidden on X4'),(await has('[data-fk="bt-compare"]'))===(dev==='m8c'));
 await S(()=>{const P=window.__proto;P.act('home');P.S.page=P.S.layouts[P.S.dev==='m8c'?'m8c':'x4'].findIndex(pg=>pg.tiles.some(t=>t.w==='battery'));P.render();});
 ok(dev+' battery widget on default Stats page',await has('[data-fk="bat-open"]'));await fk('bat-open');ok(dev+' widget opens battery page',(await txt()).includes('how the estimate is made'));
 await S(()=>{const P=window.__proto;P.act('home');P.openBook('b1');P.act('rd:top');});const tp=await txt();ok(dev+' top panel shows battery estimate',tp.includes('≈ 2 d 6 h'));await fk('tp-set');ok(dev+' settings from top panel',await has('[data-fk="sg-sync"]'));
 await S(()=>{const P=window.__proto;P.act('home');P.openBook('b1');});const st=await S(()=>document.querySelector('.pstatus').innerText.trim().split(/\s+/)[0]);ok(dev+' status line starts with battery',st==='78%',st);
 await S(()=>{const P=window.__proto;P.act('rd:bottom');});const bp=await txt();ok(dev+" bottom panel offers Book's own and Custom",bp.includes("book's own"));
 await S(()=>{const P=window.__proto;P.S.lowspace=2;P.act('home');P.act('details:b1');P.act('series:tide');});ok(dev+' low space: download next says not enough space',(await txt()).includes('not enough space'));
 await S(()=>window.__proto.act('dlnext:tide'));ok(dev+' low space: download opens the space sheet',(await txt()).includes('always leaves 200 mb free'));
 await p.close();}
console.log(res.join('\n'));console.log('ERRORS:',errs.join('\n')||'none');await b.close();})();
