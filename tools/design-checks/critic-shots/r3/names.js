const {prototypeURL, OUT}=require('../../runtime.js');
const {chromium}=require('playwright');

(async()=>{const b=await chromium.launch({executablePath:process.env.PWX});
for(const dev of ['m8c','x4c']){const p=await b.newPage({viewport:{width:1500,height:1200}});const errs=[];p.on('pageerror',e=>errs.push(e.message));p.on('console',m=>{if(m.type()==='error')errs.push(m.text())});
await p.addInitScript(()=>{window.__noscale=1});await p.goto(prototypeURL+'?dev='+dev);await p.waitForTimeout(200);
const A=a=>p.evaluate(a=>window.__proto.act(a),a);let txt='';const grab=async()=>{txt+='\n'+await p.evaluate(()=>document.querySelector('#screen').innerText+' '+[...document.querySelectorAll('#screen [title]')].map(e=>e.title).join(' '))};
await grab();await A('nav:settings');await grab();for(const g of ['account','sync','library','reading','home','sleep','power','updates','about']){await A('setg:'+g);await grab();await A('lp:set:1');await grab();await A('back');}
await A('home');await A('nav:battery');for(const t of [0,1,2,3]){await A('tab:'+t);await grab();}
const m=txt.match(/.{0,40}(BookOrbit|Tailscale|Grimmory|192\.168|tailnet|awesomeland|0\.12\.0[^\s]*).{0,30}/g)||[];console.log(dev,[...new Set(m)].join('\n   '),'ERR',errs);await p.close();}
await b.close();})();
