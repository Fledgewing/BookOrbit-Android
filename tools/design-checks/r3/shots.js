const {prototypeURL, OUT}=require('../runtime.js');
// quick shooter: node shots.js dev name 'js to run before shot' ...
const {chromium}=require('playwright');

(async()=>{const b=await chromium.launch({executablePath:process.env.PWX});const [dev,...rest]=process.argv.slice(4);
const p=await b.newPage({viewport:{width:1500,height:1200}});const errs=[];p.on('pageerror',e=>errs.push(e.message));p.on('console',m=>{if(m.type()==='error')errs.push(m.text())});
await p.addInitScript(()=>{window.__noscale=1});await p.goto(prototypeURL+'?dev='+dev);await p.waitForTimeout(150);
for(let i=0;i<rest.length;i+=2){await p.evaluate(rest[i+1]);await p.waitForTimeout(60);await p.evaluate(()=>{const S=window.__proto.S;S.toast=null;window.__proto.render()});await p.locator('#screen').screenshot({path:OUT+rest[i]+'.png'});}
console.log('ERR',errs);await b.close();})();
