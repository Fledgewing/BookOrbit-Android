const {prototypeURL, OUT}=require('../../runtime.js');
const {chromium}=require('playwright');

(async()=>{const b=await chromium.launch({executablePath:process.env.PWX});
for(const dev of ['m8c','x4pro']){
const p=await b.newPage({viewport:{width:1500,height:1200}});const errs=[];p.on('pageerror',e=>errs.push(e.message));p.on('console',m=>{if(m.type()==='error')errs.push(m.text())});
await p.addInitScript(()=>{window.__noscale=1});
await p.goto(prototypeURL+'?dev='+dev);await p.waitForTimeout(200);
const res=await p.evaluate(()=>{const P=window.__proto;P.act('menu');P.act('m:edit');const S=P.S;const dk=Object.keys(S.layouts).find(k=>S.layouts[k]===S.layouts[k]);
 const key=(S.dev==='m8c')?'m8c':'x4';const g={m8c:{cols:4,rows:8},x4:{cols:2,rows:7}}[key];
 let bad=[],moves=0,noop=0,toasts=0;let seed=7;const rnd=()=>{seed=(seed*1103515245+12345)&0x7fffffff;return seed/0x7fffffff};
 for(let i=0;i<400;i++){const pg=S.layouts[key][S.page];if(!pg.tiles.length)break;const t=Math.floor(rnd()*pg.tiles.length);P.act('sel:'+t);if(S.sel==null)P.act('sel:'+t);
  const d=[[1,0],[-1,0],[0,1],[0,-1]][Math.floor(rnd()*4)];const before=JSON.stringify(pg.tiles);P.act('mv:'+d[0]+':'+d[1]);const after=JSON.stringify(S.layouts[key][S.page].tiles);if(before===after)noop++;else moves++;if(S.toast)toasts++;
  const tl=S.layouts[key][S.page].tiles;const o=Array.from({length:g.rows},()=>Array(g.cols).fill(-1));
  tl.forEach((q,j)=>{for(let y=q.y;y<q.y+q.ch;y++)for(let x=q.x;x<q.x+q.cw;x++){if(y<0||x<0||y>=g.rows||x>=g.cols)bad.push('oob '+i);else if(o[y][x]>=0)bad.push('overlap step '+i+' '+q.w+' with '+tl[o[y][x]].w);else o[y][x]=j;}});
  if(bad.length)break;}
 return {moves,noop,toasts,bad:bad.slice(0,5),page:S.page,pages:S.layouts[key].length};});
console.log(dev,JSON.stringify(res),'ERR',errs.slice(0,3));await p.close();}
await b.close();})();
