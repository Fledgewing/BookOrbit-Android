const {prototypeURL, OUT}=require('../../runtime.js');
const {chromium}=require('playwright');

(async()=>{const b=await chromium.launch({executablePath:process.env.PWX});const out=OUT+'smoke';
for(const dev of ['m8c','x4pro']){const p=await b.newPage({viewport:{width:1500,height:1150}});const errs=[];p.on('pageerror',e=>errs.push(e.message));p.on('console',m=>{if(m.type()==='error')errs.push(m.text())});
await p.goto(prototypeURL+'?dev='+dev);await p.evaluate(()=>{window.__noscale=1;window.__proto.restart&&0});await p.waitForTimeout(200);
const sc=async n=>{await p.waitForTimeout(120);await p.locator('#screen').screenshot({path:out+'-'+dev+'-'+n+'.png'});};
await p.evaluate(()=>window.__proto.act('home'));await sc('home1');
await p.evaluate(()=>window.__proto.act('page:1'));await sc('home2');
if(dev!=='m8c'){await p.evaluate(()=>window.__proto.act('page:2'));await sc('home3');}
await p.evaluate(()=>window.__proto.act('nav:settings'));await sc('settings');
await p.evaluate(()=>window.__proto.act('setg:reading'));await sc('set-reading');
await p.evaluate(()=>window.__proto.act('nav:battery'));await sc('battery');
console.log(dev,errs.join('\n')||'no errors');await p.close();}
await b.close();})();
