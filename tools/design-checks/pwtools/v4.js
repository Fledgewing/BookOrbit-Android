const {prototypeURL, OUT}=require('../runtime.js');
const {chromium}=require('playwright');
(async()=>{const b=await chromium.launch({executablePath:process.env.PWX});
const p=await b.newPage({viewport:{width:1500,height:1100}});
await p.goto(prototypeURL);await p.waitForTimeout(300);
await p.screenshot({path:OUT+'screen.png'});await b.close();})();
