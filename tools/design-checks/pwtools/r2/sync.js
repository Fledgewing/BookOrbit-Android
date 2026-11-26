const {prototypeURL, OUT}=require('../../runtime.js');
const {chromium}=require('playwright');

(async()=>{const b=await chromium.launch({executablePath:process.env.PWX});const res=[],errs=[];const ok=(n,c,x)=>res.push((c?'PASS ':'FAIL ')+n+(x!=null?' ('+x+')':''));
for(const dev of ['m8c','x4pro','x4c']){const p=await b.newPage({viewport:{width:1500,height:1150}});p.on('pageerror',e=>errs.push(dev+': '+e.message));
 await p.goto(prototypeURL+'?dev='+dev);await p.waitForTimeout(150);
 const S=f=>p.evaluate(f);const txt=()=>p.locator('#screen').innerText();const W8=ms=>p.waitForTimeout(ms);
 // wrap-around steppers
 const wrap=await S(()=>{const P=window.__proto,S=P.S;P.openBook('b1');P.act('rd:bottom');const x4=S.dev!=='m8c';const out={};
   S.rs.size=0;P.act(x4?'cyc:size:-1:5':'cyc:size:-1:6');out.sizeBack=S.rs.size;P.act(x4?'cyc:size:1:5':'cyc:size:1:6');out.sizeFwd=S.rs.size;
   for(const k of ['font','margins','spacing','contrast']){S.rs[k]=2;P.act('cyc:'+k+':1:3');out[k]=S.rs[k];}
   out.dis=[...document.querySelectorAll('#screen .stp [data-act^="cyc:"]')].filter(e=>e.classList.contains('dis')||e.style.opacity==='.3').length;
   S.rs.light=100;return out;});
 ok(dev+' size stepper wraps from first to last and back',wrap.sizeBack===(dev==='m8c'?5:4)&&wrap.sizeFwd===0,JSON.stringify(wrap));
 ok(dev+' font/margins/spacing/contrast wrap last -> first',['font','margins','spacing','contrast'].every(k=>wrap[k]===0));ok(dev+' no stepper arrow is greyed',wrap.dis===0);
 const sv=await S(()=>{const P=window.__proto;P.act('home');P.act('nav:settings');P.act('setg:power');const before=document.querySelector('[data-fk="set-wifi"]').innerText;for(let i=0;i<3;i++)P.act('setc:wifi:3');return [before,document.querySelector('[data-fk="set-wifi"]').innerText];});
 ok(dev+' settings stepper wraps round to the same value after a full cycle',sv[0]===sv[1]);
 if(dev==='x4c'){const g=await S(()=>{const P=window.__proto,S=P.S;P.act('home');P.openBook('b1');P.act('sheet:goto');S.fk='gt-val';for(let i=0;i<400;i++)P.hw('next');const hi=S.stack.at(-1).val;for(let i=0;i<500;i++)P.hw('prev');return [hi,S.stack.at(-1).val];});ok('x4c Go to stepper stays bounded (1..341)',g[0]==='341'&&g[1]==='1',g.join('/'));}
 // book sync: further position on the other device first, then plain sync
 await S(()=>{const P=window.__proto;P.restart(P.S.dev);P.openBook('b1');P.act('rd:top');});
 ok(dev+' top panel has a sync button',await p.locator('#screen [data-fk="tp-sync"]').count()===1);
 await S(()=>window.__proto.act('bsync'));ok(dev+' shows Syncing…',(await txt()).includes('Syncing'));await W8(1100);
 ok(dev+' other device further sheet',(await txt()).includes('p. 240'));await p.click('#screen [data-fk="fu-jump"]');ok(dev+' Jump there moves to p. 240',await S(()=>window.__proto.S.pages.b1===240));
 await S(()=>{const P=window.__proto;P.act('rd:top');P.act('bsync');});await W8(1100);ok(dev+' then a plain sync toasts the saved page',(await txt()).includes('Synced · p. 240 saved'));
 if(dev!=='m8c'){const f=await S(()=>{const P=window.__proto,S=P.S;P.act('rd:close');P.act('rd:top');return [...document.querySelectorAll('#screen .panel [data-fk]')].map(e=>e.dataset.fk).includes('tp-sync');});ok(dev+' sync is a focus stop on X4',f);}
 await S(()=>{const P=window.__proto;P.S.offline=true;P.act('bsync');});ok(dev+' offline book sync says so',(await txt()).includes('Offline · will sync when connected'));
 // home header sync
 await S(()=>{const P=window.__proto;P.restart(P.S.dev);});ok(dev+' header status is a button',await p.locator('#screen [data-fk="h-sync"]').count()===1);
 await p.click('#screen [data-fk="h-sync"]');ok(dev+' header shows Syncing…',(await txt()).includes('Syncing'));await W8(1100);ok(dev+' then Synced just now',(await txt()).includes('Synced just now'));
 await S(()=>{const P=window.__proto;P.S.offline=true;P.render();});ok(dev+' offline: chip, no sync button',await p.locator('#screen [data-fk="h-sync"]').count()===0);
 await p.close();}
console.log(res.join('\n'));console.log('ERRORS:',errs.join('\n')||'none');await b.close();})();
