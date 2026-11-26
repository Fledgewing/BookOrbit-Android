const {prototypeURL, OUT}=require('../../runtime.js');
const {chromium}=require('playwright');

(async()=>{const b=await chromium.launch({executablePath:process.env.PWX});
for(const dev of ['m8c','x4pro']){const p=await b.newPage({viewport:{width:1500,height:1150}});const errs=[];p.on('pageerror',e=>errs.push(e.message));
await p.goto(prototypeURL+'?dev='+dev);await p.evaluate(()=>{window.__noscale=1});
const sc=async n=>{await p.waitForTimeout(100);await p.locator('#screen').screenshot({path:OUT+'r2/s/st-'+dev+'-'+n+'.png'});};
await p.evaluate(()=>window.__proto.act('nav:storage'));await sc('storage');
await p.evaluate(()=>{const P=window.__proto;P.S.lowspace=true;P.act('home');if(P.S.dev!=='m8c')P.act('page:1');});await sc('lowhome');
await p.evaluate(()=>{const P=window.__proto;P.act('nav:storage');});await sc('lowstorage');
await p.evaluate(()=>{const P=window.__proto;P.act('modal:rmfinished');});await sc('rm');
console.log(dev,errs.join(';')||'ok');await p.close();}await b.close();})();
