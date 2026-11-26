const {prototypeURL, OUT}=require('../../runtime.js');
const {chromium}=require('playwright');
(async()=>{const b=await chromium.launch({executablePath:process.env.PWX});const p=await b.newPage({viewport:{width:1500,height:1200}});
await p.addInitScript(()=>{window.__noscale=1});await p.goto(prototypeURL+'?dev=m8c');
const A=a=>p.evaluate(a=>__proto.act(a),a);await A('nav:settings');await A('setg:sync');
for(let pg=0;pg<3;pg++){await p.evaluate(pg=>{__proto.S.pg_set_sync=pg;__proto.render()},pg);const r=await p.evaluate(()=>{const e=[...document.querySelectorAll('#screen [data-act]')].find(x=>/Reading position/.test(x.innerText)&&/Furthest|KOReader decides/.test(x.innerText));return e&&[e.getAttribute('data-act'),e.innerText.replace(/\s+/g,' ')]});if(r){console.log('row',r);const segs=await p.evaluate(()=>[...document.querySelectorAll('#screen [data-act]')].filter(x=>/KOReader decides|Furthest page wins/.test(x.innerText)&&x.innerText.length<40).map(x=>[x.getAttribute('data-act'),x.innerText]));console.log('segs',segs);
 const a=segs.find(s=>/KOReader decides/.test(s[1]))||[r[0]];await A(a[0]);console.log('after:',await p.evaluate(()=>document.querySelector('#screen').innerText.replace(/\s+/g,' ').match(/Reading position.{0,160}/g)));break;}}
await b.close();})();
