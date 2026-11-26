// ---------- battery (synthetic numbers; definitions from STATS-DESIGN.md "Statistics (exact definitions)") ----------
const BAT = {level:78, f:.25, rR:[4.1, .3], rS:[.55, .06], chg:[38, 3], per100p:6.2,
  days:[[9,'2 h 10 m',212,14,0],[14,'3 h 05 m',301,22,1],[7,'1 h 20 m',140,9,0],[11,'2 h 30 m',236,17,0],[16,'3 h 40 m',355,25,1],[8,'1 h 35 m',151,11,0],[12,'2 h 45 m',260,19,0],
        [10,'2 h 15 m',221,15,0],[6,'1 h 05 m',98,7,0],[13,'2 h 55 m',288,20,1],[9,'2 h 00 m',190,13,0],[15,'3 h 30 m',330,24,0],[11,'2 h 25 m',240,16,0],[12,'2 h 40 m',255,18,0]],
  charges:[['Sun 21:10','12%','100%','2 h 20 m'],['Wed 07:45','31%','92%','1 h 35 m'],['Sat 22:30','8%','100%','2 h 25 m'],['Tue 19:05','40%','85%','1 h 10 m'],['Fri 23:15','15%','100%','2 h 15 m']]};
const fmtDH = h => h >= 24 ? `${Math.floor(h / 24)} d ${Math.round(h % 24)} h` : h >= 1 ? `${Math.floor(h)} h${h % 1 >= .08 ? ' ' + Math.round(h % 1 * 60) + ' m' : ''}` : Math.round(h * 60) + ' m';
const BAT_LEFT = () => BAT.level / (BAT.f * BAT.rR[0] + (1 - BAT.f) * BAT.rS[0]);
const BAT_READ = () => BAT.level / BAT.rR[0];
const BAT_STBY = () => BAT.level / BAT.rS[0];
const pm = ([v, e]) => `${v} <span style="font-weight:500">± ${e}</span>`;
// Hidden values follow the rule: "—" plus what is still needed.
const NEED = (txt) => `<span class="num" style="font-weight:700">—</span> <span style="font-size:var(--fc);font-weight:500">${txt}</span>`;
// The same glyph as the sleep screen's battery: outline, nub, solid fill.
function batGlyph(w, lv, charging){ const h = Math.round(w * .5); const iw = w - 7; return `<svg width="${w}" height="${h}" viewBox="0 0 ${w} ${h}" style="display:block;flex:none"><rect x="1" y="1" width="${iw}" height="${h - 2}" rx="${h * .18}" fill="#fff" stroke="#000" stroke-width="2"/><rect x="${iw + 1.5}" y="${h * .3}" width="4" height="${h * .4}" rx="1" fill="#000"/><rect x="3.5" y="3.5" width="${((iw - 5) * lv / 100).toFixed(1)}" height="${h - 7}" rx="${h * .1}" fill="#000"/>${charging ? `<path d="M${iw / 2 + 2} ${h * .18}l-${h * .22} ${h * .36}h${h * .2}l-${h * .1} ${h * .3} ${h * .3}-${h * .4}h-${h * .2}z" fill="#fff" stroke="#000" stroke-width="1"/>` : ''}</svg>`; }
function batBars(days, hgt, labels){
  const max = Math.max(...days.map(d => d[0])); const di = ['W','T','F','S','S','M','T'];
  return `<div style="display:flex;gap:6px;align-items:flex-end;height:${hgt}px;border-bottom:1.5px solid #000;padding-top:14px">${days.map((d, i) => `<div style="flex:1;height:100%;position:relative"><div style="position:absolute;bottom:0;left:50%;transform:translateX(-50%);width:100%;max-width:22px;height:${Math.round(d[0] / max * 100)}%;background:${i === days.length - 1 ? '#000' : 'var(--g2)'};border-radius:3px 3px 0 0"></div>${d[0] === max ? `<span class="num" style="position:absolute;left:50%;transform:translateX(-50%);bottom:calc(${Math.round(d[0] / max * 100)}% + 2px);font-size:10px;font-weight:700">${d[0]}%</span>` : ''}</div>`).join('')}</div>
  ${labels ? `<div style="display:flex;gap:6px;margin-top:4px">${days.map((d, i) => `<span style="flex:1;text-align:center;font-size:11px;font-weight:${i === days.length - 1 ? 800 : 500}">${di[i]}</span>`).join('')}</div>` : ''}`;
}
W.battery = {name:'Battery', icon:'battery', rel:'now', desc:'Battery level and how long it will last at your pace, with the split between reading and standby, % used per day and the measured rates.',
  sizes:{m8c:[[2,1],[2,2],[4,3],[2,3],[4,2]], x4:[[1,1],[2,2],[2,3],[1,2],[2,1]]},
  render(t){
    const x4 = t.dev === 'x4'; const wk = BAT.days.slice(-7); const used7 = wk.reduce((s, d) => s + d[0], 0);
    const lvl = (big) => `<div style="display:flex;align-items:center;gap:${big ? 12 : 9}px">${batGlyph(big ? 52 : 40, BAT.level)}<span class="num" style="font-size:${big ? 36 : 28}px;font-weight:700;letter-spacing:-.02em;line-height:1">${BAT.level}<span style="font-size:.55em">%</span></span></div>`;
    const left = (sz) => `<div style="font-size:${sz || 'var(--fs)'};font-weight:700;margin-top:5px;white-space:nowrap">≈ ${fmtDH(BAT_LEFT())} left</div>`;
    const split = `<div style="font-size:var(--fc);margin-top:3px;white-space:nowrap" class="meta"><b>${fmtDH(BAT_READ())}</b> reading · <b>${fmtDH(BAT_STBY())}</b> standby</div>`;
    const wrap = (inner, extra = '') => `<div class="tin" data-act="nav:battery" data-fk="bat-open" ${extra}>${inner}</div>`;
    if (t.h < 130){ // small
      if (t.w < 260) return wrap(`<div style="flex:1"></div>${lvl()}${left()}<div style="flex:1"></div>`);
      return wrap(`<div style="flex:1;display:flex;align-items:center;gap:16px">${lvl(true)}<div style="min-width:0">${left('var(--fb)').replace('margin-top:5px', 'margin-top:0')}${split}</div></div>`);
    }
    const hd = `<div class="th"><span class="lab">Battery</span><span class="more" style="margin-left:auto">${ic('chevR', 14, 2.6)}</span></div>`;
    if (t.w < 260){ // tall narrow
      return wrap(`${hd}<div style="margin-top:10px">${lvl()}</div>${left()}<div style="font-size:var(--fc);margin-top:6px;line-height:1.4" class="meta"><b>${fmtDH(BAT_READ())}</b> reading<br><b>${fmtDH(BAT_STBY())}</b> standby</div><div style="flex:1;min-height:8px"></div>${t.h > 250 ? batBars(wk, 70, true) : ''}`);
    }
    const large = t.w > 420 && t.h > 250;
    if (!large){ // medium
      const bh = t.h - 2*t.tp - 22 - 74 - 22; return wrap(`${hd}<div style="display:flex;align-items:center;gap:14px;margin-top:8px">${lvl(t.w > 420)}<div style="min-width:0">${left().replace('margin-top:5px', 'margin-top:0')}${split}</div></div><div style="flex:1"></div>
        <div style="display:flex;justify-content:space-between;font-size:11px;font-weight:700;margin-top:6px"><span>% used per day</span><span class="num">${used7}% this week</span></div>${batBars(wk, Math.max(40, bh), true)}`);
    }
    const st = (v, l) => `<div style="min-width:0"><div class="num" style="font-size:${x4 ? 16 : 19}px;font-weight:700;white-space:nowrap">${v}</div><div style="font-size:var(--fc);margin-top:2px" class="meta ell">${l}</div></div>`;
    const lc = BAT.charges[0];
    return wrap(`${hd}<div style="display:flex;gap:${x4 ? 14 : 24}px;margin-top:8px;flex:1;min-height:0">
        <div style="flex:none;display:flex;flex-direction:column">${lvl(!x4)}${left(x4 ? 'var(--fs)' : 'var(--fb)')}${split}</div>
        <div style="flex:1;min-width:0;display:flex;flex-direction:column"><div style="display:flex;justify-content:space-between;font-size:11px;font-weight:700"><span>% used per day</span><span class="num">${used7}% / 7 d</span></div><div style="flex:1"></div>${batBars(wk, x4 ? 56 : 84, true)}</div></div>
      <div class="hair" style="margin:${x4 ? 10 : 14}px 0"></div>
      <div style="display:grid;grid-template-columns:repeat(4,1fr);gap:${x4 ? 8 : 14}px">${st(pm(BAT.rR) , 'reading %/h')}${st(pm(BAT.rS), 'standby %/h')}${st(BAT.per100p + '%', 'per 100 pages')}${st(pm(BAT.chg), 'charging %/h')}</div>
      <div style="display:flex;align-items:center;gap:8px;font-size:var(--fc);margin-top:${x4 ? 8 : 12}px;white-space:nowrap">${batGlyph(22, 100, true)}<span>Last charge <b>${lc[0]}</b> · ${lc[1]} → ${lc[2]} in ${lc[3]}</span></div>`);
  }};

function batteryView(c, g){
  const x4 = dk() === 'x4'; const tab = c.tab || 0; const P = g.padx + 6;
  const tabs = `<div class="sg" style="margin:14px ${P}px 0">${['Overview','Rates','Daily','Charges'].map((l, i) => `<div class="${tab === i ? 'on' : ''}" data-act="tab:${i}" data-fk="bt-${i}">${l}</div>`).join('')}</div>`;
  const sec = t => `<div class="cap" style="padding:${x4 ? 14 : 18}px 0 6px">${t}</div>`;
  const row = (l, v, sub) => `<div style="display:flex;align-items:center;gap:12px;min-height:${x4 ? 40 : 48}px;border-bottom:1px solid var(--g3)"><div style="flex:1;min-width:0"><div style="font-size:var(--fs);font-weight:600">${l}</div>${sub ? `<div class="meta" style="font-size:var(--fc)">${sub}</div>` : ''}</div><div class="num" style="font-size:var(--fs);font-weight:700;text-align:right">${v}</div></div>`;
  let body = '';
  if (tab === 0){
    body = `<div style="display:flex;align-items:center;gap:20px;margin-top:${x4 ? 16 : 22}px">${batGlyph(x4 ? 76 : 96, BAT.level)}<div><div class="num" style="font-size:${x4 ? 40 : 52}px;font-weight:700;letter-spacing:-.02em;line-height:1">${BAT.level}%</div><div style="font-size:var(--fb);font-weight:700;margin-top:6px">≈ ${fmtDH(BAT_LEFT())} left at your pace</div></div></div>
      ${sec('How the estimate is made')}
      ${row('If you read text non-stop', fmtDH(BAT_READ()), `78% ÷ reading ${BAT.rR[0]} %/h`)}
      ${row('In standby only', fmtDH(BAT_STBY()), `78% ÷ standby ${BAT.rS[0]} %/h`)}
      ${row('Screen on, last 7 days', Math.round(BAT.f * 100) + '%', 'the share used to blend the two')}
      ${sec('Per amount of reading')}
      ${row('Per 100 pages', BAT.per100p + '%', 'reading text')}
      ${row('Per 100 full refreshes', x4 ? NEED('64 of 100 refreshes needed') : '3.4%', x4 ? '' : 'all content')}
      ${row('Charging', pm(BAT.chg) + ' %/h', 'from your last 5 charges')}
      <div style="display:flex;gap:10px;margin-top:${x4 ? 14 : 20}px">${x4 ? '' : `<div class="pill wh" data-act="toast:Pick a battery export from another reader to see both side by side" data-fk="bt-compare" style="flex:1">${ic('layers', 18, 2.2)}Compare with another reader</div>`}<div class="pill wh" data-act="toast:Saved battery-stats.json (orbit-battery-stats/1)" data-fk="bt-export" style="flex:${x4 ? 1 : 'none'};padding:0 18px">${ic('download', 18, 2.2)}Export</div></div>`;
  } else if (tab === 1){
    const r = (l, v) => row(l, v === null ? NEED('0.4 h of 1 h needed') : pm(v) + ' <span style="font-weight:500;font-size:var(--fc)">%/h</span>');
    body = `${sec('Reading · screen on, not charging')}${r('All reading', BAT.rR)}${r('Text', [3.9, .3])}${r('Comics', [6.8, .9])}${x4 ? '' : r('PDF', null)}${r('Wi-Fi off while reading', [3.8, .3])}${r('Wi-Fi just in time', [4.0, .4])}${x4 ? '' : r('Front light on', [4.9, .4]) + r('Front light off', [3.2, .3])}
      ${sec('Standby · screen off, not charging')}${r('All standby', BAT.rS)}${r('Wi-Fi always on', [1.9, .2])}${r('Wi-Fi just in time', [.42, .05])}${x4 ? '' : r('Wi-Fi off while reading', null)}
      <div class="meta" style="font-size:var(--fc);margin-top:10px">± is the margin of error. A rate shows after 1 h of data and a drop of more than 2%.</div>`;
  } else if (tab === 2){
    const per = 7; const pg = clamp(S.pg_bday || 0, 0, 1); const days = BAT.days.slice().reverse().slice(pg * per, pg * per + per);
    const max = Math.max(...BAT.days.map(d => d[0])); const names = ['Today','Yesterday','Sun','Sat','Fri','Thu','Wed','Tue','Mon','Sun','Sat','Fri','Thu','Wed'];
    body = `<div style="display:grid;grid-template-columns:${x4 ? '78px 1fr' : '96px 1fr 74px 64px 70px'};gap:0 12px;align-items:center;margin-top:14px;font-size:var(--fc);font-weight:700;padding-bottom:6px;border-bottom:1.5px solid #000"><span>Day</span><span>% used</span>${x4 ? '' : '<span>Screen on</span><span>Pages</span><span>Refreshes</span>'}</div>
      ${days.map((d, i) => `<div style="display:grid;grid-template-columns:${x4 ? '78px 1fr' : '96px 1fr 74px 64px 70px'};gap:0 12px;align-items:center;height:${x4 ? 64 : 78}px;border-bottom:1px solid var(--g3);font-size:var(--fs)"><b>${names[pg * per + i]}</b>
        <div><div style="display:flex;align-items:center;gap:8px"><div style="height:12px;width:${Math.round(d[0] / max * (x4 ? 150 : 150))}px;background:#000;border-radius:2px"></div><b class="num">${d[0]}%</b>${d[4] ? ic('bolt', 16, 2) : ''}</div>${x4 ? `<div class="meta num" style="font-size:var(--fc);margin-top:3px">${d[1]} · ${d[2]} pp · ${d[3]} full${d[4] ? ' · charged' : ''}</div>` : ''}</div>
        ${x4 ? '' : `<span class="num">${d[1]}</span><span class="num">${d[2]}</span><span class="num">${d[3]} full</span>`}</div>`).join('')}
      ${pagerRow({p:pg, pages:2}, 'bday')}`;
  } else {
    body = `${sec('Last ' + BAT.charges.length + ' charges')}${BAT.charges.map(ch => `<div style="display:flex;align-items:center;gap:14px;height:${x4 ? 60 : 70}px;border-bottom:1px solid var(--g3)">${batGlyph(34, parseInt(ch[2]), true)}<div style="flex:1;min-width:0"><div style="font-size:var(--fs);font-weight:700">${ch[0]}</div><div class="meta" style="font-size:var(--fc)">${ch[3]}</div></div>
        <div style="display:flex;align-items:center;gap:6px;font-size:var(--fs);font-weight:700" class="num">${ch[1]}<span style="display:inline-block;width:${x4 ? 40 : 70}px;height:8px;border:1.5px solid #000;border-radius:4px;background:linear-gradient(90deg,#fff ${parseInt(ch[1])}%,#000 ${parseInt(ch[1])}%,#000 ${parseInt(ch[2])}%,#fff ${parseInt(ch[2])}%)"></span>${ch[2]}</div></div>`).join('')}
      ${row('Charging rate', pm(BAT.chg) + ' %/h', 'needs 0.5 h and more than 2% of charging')}`;
  }
  return shdr('Battery', `${BAT.level}% · ≈ ${fmtDH(BAT_LEFT())} left`) + tabs + `<div style="padding:0 ${P}px">${body}</div>`;
}
