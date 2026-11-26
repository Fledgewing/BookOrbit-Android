function head(lab, meta, more, act, fk){ const hit = act ? ` hit" data-act="${act}" data-fk="${fk}` : ''; return `<div class="th${hit}"><span class="lab">${lab}</span>${meta ? `<span class="meta">${meta}</span>` : ''}${more ? `<span class="more">${more}${ic('chevR', 14, 2.6)}</span>` : ''}</div>`; }
const DAY3 = d => d.slice(0, 3);

// Hero progress: one continuous bar (white fill, mid-gray track on M8C / black track on X4, 1px white outline),
// small chapter ticks under it and only the current chapter bracketed.
function heroBar(b, p, cs, cc, x4, h){
  const pct = p / b.pages * 100; const L = x => (x / b.pages * 100).toFixed(2);
  const ticks = cs.slice(1).map(c => `<i style="position:absolute;left:${L(c.start - 1)}%;top:0;width:1px;height:4px;background:var(--im2)"></i>`).join('');
  const cur = `<i style="position:absolute;left:${L(cc.start - 1)}%;width:${((cc.end - cc.start + 1) / b.pages * 100).toFixed(2)}%;top:0;height:6px;border:2px solid #fff;border-top:0"></i>`;
  return `<div style="height:${h}px;border-radius:${h}px;background:${x4 ? '#000' : '#8c8c8c'};box-shadow:0 0 0 1px #fff;overflow:hidden"><b style="display:block;height:100%;width:${pct.toFixed(1)}%;background:#fff"></b></div>
    <div style="position:relative;height:8px;margin-top:4px">${ticks}${cur}</div>`;
}

W.hero = {name:'Continue reading', icon:'open', rel:'now', ink:true, desc:'Your current book, big: cover, progress with chapter marks, time left and when you\'ll finish.',
  sizes:{m8c:[[4,3],[4,2],[2,2]], x4:[[2,3],[2,2]]},
  render(t){
    const b = B[S.hero]; const x4 = t.dev === 'x4'; const p = curPage(b); const pct = Math.round(p / b.pages * 100);
    const cs = chapters(b); const cc = chapterOf(b, p); const f = forecast(b);
    const pad = t.tp; const ih = t.h - 2*pad;
    const wide = t.w > 420; const tall = t.h > 250;
    let cH = ih, cW = Math.round(cH * 2/3);
    if (!wide){ cW = Math.min(cW, Math.round(t.w * .36)); cH = Math.round(cW * 1.5); }
    const tw = t.w - 2*pad - cW - (x4 ? 16 : 22);
    const tsize = (x4 ? (tall ? 24 : 19) : (tall ? 31 : 25)) * (b.t.length > 22 ? .86 : 1);
    const mat = 'box-shadow:0 0 0 2px #fff';
    const disabled = !b.dev && S.offline;
    const btnLabel = b.dev ? 'Resume' : disabled ? 'Offline' : 'Download';
    const btn = `<div class="pill inv${disabled ? ' dis' : ''}" data-act="book:${b.id}" data-fk="hero-resume" style="${x4 ? 'padding:0 16px;font-size:15px' : ''}">${ic(b.dev ? 'play' : disabled ? 'cloudoff' : 'download', x4 ? 16 : 18, 2.4)}${btnLabel}</div>`;
    const moreBtn = `<span style="margin:-${x4 ? 11 : 16}px -12px -${x4 ? 11 : 16}px auto;width:var(--tap);height:var(--tap);display:grid;place-items:center;border-radius:99px;flex:none" data-act="actions:${b.id}" data-fk="hero-more" class="inkbg">${ic('more', 22)}</span>`;
    const eyebrow = (txt) => `<div style="display:flex;align-items:center;gap:8px"><span class="cap" style="color:var(--im)">${txt}</span>${moreBtn}</div>`;
    const left = x4 ? `${fmtDur(f.left)} · by ${DAY3(f.by)}` : `${fmtDur(f.left).replace(' m', ' min')} left`;
    if (!wide && !tall){ // 2x2 on M8C
      return `<div class="tin" style="flex-direction:row;gap:14px;align-items:center" data-book="${b.id}">${coverEl(b, cW, cH, {style:mat})}
        <div class="hcol" style="flex:1;min-width:0;display:flex;flex-direction:column;height:100%">${eyebrow('Reading')}<div class="ser" style="font-size:${x4?19:20}px;font-weight:700;line-height:1.12;margin-top:6px;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden">${esc(b.t)}</div>
        <div style="flex:1"></div><div style="display:flex;justify-content:space-between;font-size:var(--fc);color:var(--im);margin-bottom:6px"><b style="color:#fff" class="num">${pct}%</b><span>${fmtDur(f.left)} left</span></div>${heroBar(b, p, cs, cc, x4, 7)}
        <div style="margin-top:6px">${btn.replace('class="pill inv', 'style="padding:0 14px" class="pill inv')}</div></div></div>`;
    }
    if (wide && !tall){ // 4x2 on M8C, 2x2 on X4
      return `<div class="tin" style="flex-direction:row;gap:${x4 ? 16 : 20}px" data-book="${b.id}">${coverEl(b, cW, cH, {style:mat, fk:'hero-cover'})}
        <div class="hcol" style="width:${tw}px;display:flex;flex-direction:column;min-width:0">
          <div style="display:flex;align-items:center;gap:8px"><div class="ser ell" style="font-size:${x4 ? 20 : 24}px;font-weight:700;line-height:1.15;flex:1;min-width:0">${esc(b.t)}</div>${moreBtn}</div>
          <div class="ell" style="font-size:var(--fs);color:var(--im);margin-top:2px">${esc(b.a)}</div>
          <div style="flex:1;min-height:4px"></div>
          <div style="display:flex;align-items:baseline;gap:10px;font-size:var(--fc);color:var(--im);white-space:nowrap"><b class="num" style="font-size:var(--fb);color:#fff">${pct}%</b><span>Ch ${cc.i + 1} of ${cs.length}</span><span style="margin-left:auto"><b style="color:#fff">${left}</b>${x4 ? '' : ' · by ' + f.by}</span></div>
          <div style="margin-top:7px">${heroBar(b, p, cs, cc, x4, 8)}</div>
          <div style="margin-top:6px">${btn}</div></div></div>`;
    }
    const big = `<div style="display:flex;align-items:baseline;gap:10px"><span class="num" style="font-size:${x4 ? 30 : 38}px;font-weight:700;letter-spacing:-.02em;line-height:1">${pct}<span style="font-size:.55em">%</span></span><span style="margin-left:auto;font-size:var(--fc);color:var(--im);text-align:right;line-height:1.35">Chapter ${cc.i + 1} of ${cs.length}<br><span class="num">p. ${p} of ${b.pages}</span></span></div>`;
    const fc = `<div style="display:flex;align-items:center;gap:7px;font-size:var(--fs);color:var(--im);line-height:1.3;white-space:nowrap">${ic('clock', 16, 2)}<span>${x4 ? `<b style="color:#fff">${left}</b>` : `<b style="color:#fff">${left}</b> · done by ${f.by}`}</span></div>`;
    return `<div class="tin" style="flex-direction:row;gap:${x4 ? 16 : 22}px" data-book="${b.id}">
      <div style="position:relative;flex:none;align-self:center">${coverEl(b, cW, cH, {style:mat, fk:'hero-cover'})}</div>
      <div class="hcol" style="width:${tw}px;display:flex;flex-direction:column;min-width:0">
        ${eyebrow('Continue reading')}
        <div class="ser" style="font-size:${tsize}px;font-weight:700;line-height:1.1;letter-spacing:-.005em;margin-top:${x4 ? 6 : 8}px;display:-webkit-box;-webkit-line-clamp:${x4 ? 3 : 2};-webkit-box-orient:vertical;overflow:hidden">${esc(b.t)}</div>
        <div style="font-size:var(--fb);color:var(--im);margin-top:5px" class="ell">${esc(b.a)}</div>
        ${b.series && t.h > 280 ? `<div style="font-size:var(--fc);color:var(--im2);margin-top:3px" class="ell">${esc(SERIES[b.series].name)} · Book ${b.no}</div>` : ''}
        <div style="flex:1;min-height:6px"></div>
        ${big}
        <div style="margin-top:${x4 ? 8 : 10}px">${heroBar(b, p, cs, cc, x4, 10)}</div>
        ${x4 ? `<div style="margin-top:6px">${fc}</div><div style="margin-top:10px">${btn}</div>`
             : `<div style="display:flex;align-items:center;gap:16px;margin-top:10px">${btn}${fc}</div>`}
      </div></div>`;
  }};

W.also = {name:'Also reading', icon:'layers', rel:'now', desc:'Your other open books. Tap one to switch; All lists every book you\'ve started, including ones you\'ve put down.',
  sizes:{m8c:[[2,2],[4,2],[2,3],[2,1]], x4:[[2,2],[2,3],[1,2],[2,1]]},
  render(t){
    const list = IN_PROGRESS_ORDER().filter(b => b.id !== S.hero);
    const x4 = t.dev === 'x4';
    const hd = head('Also reading', '', `All ${list.length}`, 'nav:reading', 'also-all');
    const ih = t.h - 2*t.tp - 24;
    if (t.w > 500){ // strip of covers with progress under
      const ch = ih - 34, cw = Math.round(ch * 2/3); const n = Math.min(list.length, Math.floor((t.w - 2*t.tp + 16) / (cw + 16)));
      return `<div class="tin">${hd}<div style="flex:1;display:flex;gap:16px;margin-top:10px;justify-content:space-between">${list.slice(0, n).map(b => `<div style="width:${cw}px">${coverEl(b, cw, ch)}<div class="bar1" style="margin-top:9px;height:4px"><b style="width:${Math.round(curPage(b)/b.pages*100)}%"></b></div><div class="num" style="font-size:11px;font-weight:700;margin-top:4px">${Math.round(curPage(b)/b.pages*100)}%</div></div>`).join('')}</div></div>`;
    }
    const narrow = t.w < 260;
    // Real covers, not stamps: rows are at least 64px, so a 2x2 tile shows two books with covers twice the old size.
    const n = Math.min(list.length, clamp(Math.floor(ih / 64), 1, 4)); const rowH = Math.floor(ih / n);
    const rows = list.slice(0, n).map((b, i) => { const pct = Math.round(curPage(b)/b.pages*100); const th = rowH - 6; return `<div class="lrow" style="height:${rowH}px;gap:${narrow ? 10 : 14}px" data-act="book:${b.id}" data-book="${b.id}" data-fk="also-${b.id}">
      ${coverEl(b, Math.round(th*2/3), th, {noact:true})}
      <div style="flex:1;min-width:0"><div style="font-size:var(--fs);font-weight:700;line-height:1.2;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden">${esc(b.t)}</div>
      ${narrow ? `<div class="num" style="font-size:var(--fc);color:var(--g1);margin-top:4px">${pct}% · ${b.last} d ago</div>` :
      `<div style="display:flex;align-items:center;gap:8px;margin-top:7px"><div class="bar1" style="width:${x4 ? 80 : 70}px;height:5px"><b style="width:${pct}%"></b></div><span class="num" style="font-size:var(--fc);font-weight:700">${pct}%</span></div><div style="font-size:var(--fc);color:var(--g1);margin-top:3px">${b.last === 0 ? 'Read today' : 'Read ' + b.last + ' days ago'}${b.dev ? '' : ' · on server'}</div>`}</div>
      ${narrow ? '' : `<div style="color:#000">${ic(b.dev ? 'chevR' : 'clouddl', 18, 2.2)}</div>`}</div>`; }).join('');
    return `<div class="tin">${hd}<div style="margin-top:4px;display:flex;flex-direction:column">${rows}</div></div>`;
  }};

function coverRow(t, books, label, meta, act, fk, captions){
  const x4 = t.dev === 'x4';
  const capH = captions ? 18 : 0;
  const ih = t.h - 2*t.tp - 26;
  const iw = t.w - 2*t.tp; const gap = x4 ? 10 : 14; const vgap = 14;
  const rowsN = ih >= 330 ? 2 : 1;
  let ch = Math.min(Math.floor((ih - (rowsN - 1)*vgap) / rowsN) - capH - 10, 210), cw = Math.round(ch * 2/3);
  let n = Math.floor((iw + gap) / (cw + gap));
  if (n < 2 && t.w < 260){ n = 2; cw = Math.floor((iw - gap)/2); ch = Math.round(cw * 1.5); if (ch > ih - 10 - capH){ ch = ih - 10 - capH; cw = Math.round(ch*2/3); } }
  const per = n; n = Math.min(n * rowsN, books.length);
  const item = b => `<div style="width:${cw}px">${coverEl(b, cw, ch)}${captions ? `<div style="font-size:11px;font-weight:700;margin-top:6px;color:var(--g1)" class="ell">${captions(b)}</div>` : ''}</div>`;
  let body = '';
  for (let r = 0; r < rowsN; r++){ const sl = books.slice(r*per, Math.min(n, (r+1)*per)); body += `<div style="display:flex;justify-content:${per > 2 ? 'space-between' : 'flex-start'};gap:${gap}px;${r ? `margin-top:${vgap}px` : ''}">${sl.map(item).join('')}</div>`; }
  return `<div class="tin">${head(label, meta, 'All', act, fk)}<div style="flex:1"></div>${body}</div>`;
}
const RECENT = () => Object.values(B).filter(b => b.added < 30).sort((a, b) => a.added - b.added);
const WTR = () => Object.values(B).filter(b => b.wtr);
W.recent = {name:'Recently added', icon:'inbox', rel:'now', desc:'The newest books on your server, newest first. A cloud badge means it isn\'t on this device yet.',
  sizes:{m8c:[[4,2],[2,2],[4,3]], x4:[[1,2],[2,2]]},
  render(t){ const r = RECENT(); return coverRow(t, r, 'Recently added', t.w > 300 ? `${r.filter(b => b.added < 7).length} this week` : '', 'nav:recent', 'recent-all', b => b.added === 0 ? 'Today' : b.added === 1 ? 'Yesterday' : b.added + ' days ago'); }};
W.wtr = {name:'Want to read', icon:'bookmark', rel:'next', desc:'Books you\'ve marked to read next.',
  sizes:{m8c:[[2,2],[4,2]], x4:[[2,4],[2,2],[1,2]]},
  render(t){ const r = WTR(); return coverRow(t, r, 'Want to read', `${WTR_COUNT()}`, 'nav:wtr', 'wtr-all'); }};
const WTR_COUNT = () => 28 + WTR().length;

W.scopes = {name:'Smart scopes', icon:'filter', rel:'now', desc:'Your saved smart filters with live counts. The main way to browse.',
  sizes:{m8c:[[2,3],[2,2],[4,2]], x4:[[1,2],[2,2],[2,3]]},
  render(t){
    const x4 = t.dev === 'x4'; const ih = t.h - 2*t.tp - 26; const cols = t.w > 500 ? 2 : 1; const narrow = t.w < 260;
    // Rows fill the tile evenly and never drop below the touch minimum.
    const minRow = x4 ? 42 : 52; const per = Math.max(1, Math.floor(ih / minRow)); const rowH = Math.floor(ih / per); const n = Math.min(SCOPES.length, per * cols);
    const item = (s, i) => `<div class="lrow" style="height:${rowH - 1}px;gap:${narrow ? 8 : 11}px" data-act="scope:${s.id}" data-fk="scope-${s.id}">
      ${narrow ? '' : `<div class="well" style="width:32px;height:32px;border-radius:9px;background:var(--g4);display:grid;place-items:center;flex:none">${ic(s.i, 18, 2)}</div>`}
      <div style="flex:1;min-width:0;font-size:var(--fs);font-weight:600" class="ell">${esc(s.n)}</div>
      <span class="num" style="font-size:var(--fs);font-weight:700">${s.c}</span>${narrow ? '' : ic('chevR', 16, 2.4)}</div>`;
    const colsHtml = []; for (let c = 0; c < cols; c++){ const sl = SCOPES.slice(c*per, Math.min(n, (c+1)*per)); colsHtml.push(`<div style="flex:1;min-width:0;display:flex;flex-direction:column">${sl.map((s, i) => (i ? '<div class="hair"></div>' : '') + item(s, i)).join('')}</div>`); }
    return `<div class="tin">${head('Smart scopes', '', `All ${SCOPES.length}`, 'nav:scopes', 'scopes-all')}<div style="display:flex;gap:24px;margin-top:2px">${colsHtml.join('')}</div></div>`;
  }};

W.library = {name:'Library', icon:'books', rel:'now', desc:'Library size and what\'s on this device. Authors and Series are there, smaller.',
  sizes:{m8c:[[2,1],[2,2],[1,1]], x4:[[2,3],[1,2],[2,1],[1,1],[2,2]]},
  render(t){
    const x4 = t.dev === 'x4';
    // 1 row: four stat cells, each a full-height target. The two library counts lead; Authors and Series are lighter.
    if (t.h < 130 && t.w >= 260){
      const cell = (n, l, act, fk, main) => `<div data-act="${act}" data-fk="${fk}" style="flex:${main ? 1.25 : 1};min-width:0;height:100%;display:flex;flex-direction:column;justify-content:center;padding:0 ${main ? 4 : 10}px;${main ? '' : 'border-left:1px solid var(--g3)'}"><div class="num" style="font-size:${main ? 24 : 17}px;font-weight:${main ? 700 : 600};line-height:1.05">${n}</div><div style="font-size:var(--fc);color:var(--g1);margin-top:3px;display:flex;align-items:center;gap:2px;white-space:nowrap">${l}${main ? '' : ic('chevR', 12, 2.6)}</div></div>`;
      return `<div class="tin" style="flex-direction:row;padding-top:${t.tp - 4}px;padding-bottom:${t.tp - 4}px">${cell(fmtN(LIB.total), 'in library', 'nav:library', 'lib-all', 1)}${cell(LIB.device, 'on device', 'nav:device', 'lib-dev', 1)}${cell(LIB.authors, 'authors', 'nav:authors', 'lib-au')}${cell(LIB.series, 'series', 'nav:serieslist', 'lib-se')}</div>`;
    }
    if (t.h < 130) return `<div class="tin" data-act="nav:library" data-fk="lib-all"><span class="lab" style="font-size:var(--fs);font-weight:700">Library</span><div style="flex:1"></div><div class="num" style="font-size:26px;font-weight:700">${fmtN(LIB.total)}</div><div style="font-size:var(--fc);color:var(--g1)">${LIB.device} on device</div></div>`;
    const n1 = `<div data-act="nav:library" data-fk="lib-all" style="min-width:0;flex:1;min-height:var(--tap);display:flex;flex-direction:column;justify-content:flex-end"><div class="num" style="font-size:32px;font-weight:700;letter-spacing:-.02em;line-height:1">${fmtN(LIB.total)}</div><div style="font-size:var(--fc);color:var(--g1);margin-top:3px">books</div></div>`;
    const n2 = `<div data-act="nav:device" data-fk="lib-dev" style="min-width:0;flex:1;min-height:var(--tap);display:flex;gap:8px;align-items:flex-end">${ic('device', 20, 2)}<div><div class="num" style="font-size:24px;font-weight:700;line-height:1">${LIB.device}</div><div style="font-size:var(--fc);color:var(--g1);margin-top:3px">on device</div></div></div>`;
    const links = [['Authors', LIB.authors, 'nav:authors', 'lib-au', 'user'], ['Series', LIB.series, 'nav:serieslist', 'lib-se', 'stack'], ['Collections', LIB.collections, 'toast:Collections open in the Library browser', 'lib-co', 'books']];
    const ih = t.h - 2*t.tp; const narrow = t.w < 260;
    if (narrow) return `<div class="tin">${head('Library')}<div style="margin-top:8px;display:flex">${n1}</div><div class="hair" style="margin:8px 0"></div><div style="display:flex">${n2}</div><div style="flex:1"></div><div style="display:flex;gap:8px">${links.slice(0, 2).map(([l, c, a, fk]) => `<div data-act="${a}" data-fk="${fk}" style="flex:1;height:var(--tap);display:flex;align-items:center;gap:2px;font-size:var(--fc);font-weight:700">${l}${ic('chevR', 13, 2.6)}</div>`).join('')}</div></div>`;
    const rowH = x4 ? 42 : 52; const nl = clamp(Math.floor((ih - 26 - 64 - 12) / rowH), 0, 3);
    return `<div class="tin">${head('Library')}<div style="display:flex;gap:16px;margin-top:8px">${n1}${n2}</div><div style="flex:1"></div>
      ${links.slice(0, nl).map(([l, c, a, fk, i]) => `<div class="lrow" data-act="${a}" data-fk="${fk}" style="height:${rowH}px;border-top:1px solid var(--g3);font-size:var(--fs);font-weight:600">${ic(i, 18, 2)}<span style="flex:1">${l}</span><span class="num" style="color:var(--g1)">${c}</span>${ic('chevR', 16, 2.4)}</div>`).join('')}</div>`;
  }};

const WEEK_DAY = i => DAYS[(TODAY - (WEEK.length - 1) + i + 7) % 7];
W.week = {name:'This week', icon:'chart', rel:'next', desc:'Minutes read each day this week as a bar chart, today in black.',
  sizes:{m8c:[[2,2],[2,3],[2,1],[1,2]], x4:[[1,2],[2,2],[2,1]]},
  render(t){
    const tot = WEEK.reduce((s, d) => s + d.m, 0); const max = Math.max(...WEEK.map(d => d.m)); const bi = WEEK.findIndex(d => d.m === max); const diff = Math.round((tot / WEEK_LAST - 1) * 100);
    const narrow = t.w < 260; const short = t.h < 120;
    const hdr = narrow ? `<div class="th"><span class="lab">This week</span></div><div class="num" style="font-size:22px;font-weight:700;margin-top:4px">${fmtDur(tot)}</div>`
                       : `<div class="th"><span class="lab">This week</span><span class="num" style="margin-left:auto;font-size:var(--fs);font-weight:700">${fmtDur(tot)}</span></div>`;
    const sub = !narrow && !short ? `<div style="font-size:var(--fc);color:var(--g1);margin-top:2px">${diff >= 0 ? '+' : ''}${diff}% on last week · best day ${WEEK_DAY(bi)}</div>` : '';
    // Every column has the same height; the best-day label floats above its bar, so bar heights stay true to the minutes.
    const bars = WEEK.map((d, i) => { const today = i === WEEK.length - 1; const h = Math.max(3, Math.round(d.m / max * 100)); return `<div style="flex:1;position:relative;height:100%">
       <div style="position:absolute;bottom:0;left:50%;transform:translateX(-50%);width:100%;max-width:${narrow ? 18 : 26}px;height:${h}%;background:${today ? '#000' : 'var(--g2)'};border-radius:3px 3px 0 0"></div>
       ${i === bi && !short ? `<span class="num" style="position:absolute;left:50%;transform:translateX(-50%);bottom:calc(${h}% + 3px);font-size:10px;font-weight:700;white-space:nowrap">${fmtDur(d.m)}</span>` : ''}</div>`; }).join('');
    const ini = WEEK.map((d, i) => `<span style="flex:1;text-align:center;font-size:11px;font-weight:${i === 6 ? 800 : 500};color:${i === 6 ? '#000' : 'var(--g1)'}">${d.d}</span>`).join('');
    return `<div class="tin">${hdr}${sub}<div style="flex:1;display:flex;gap:${narrow ? 5 : 8}px;margin-top:8px;padding:${short ? 0 : 16}px 2px 0;border-bottom:1.5px solid #000;min-height:0">${bars}</div>${short ? '' : `<div style="display:flex;gap:${narrow ? 5 : 8}px;margin-top:5px;padding:0 2px">${ini}</div>`}</div>`;
  }};

// Heat levels. M8C: four grays + black. X4: patterns in pure black and white.
const HEAT_LEVEL = v => v <= 0 ? 0 : v < 30 ? 1 : v < 60 ? 2 : v < 110 ? 3 : 4;
const HEAT_FILL_M8C = ['var(--g4)', 'var(--g3)', 'var(--g2)', '#555', '#000'];
const HEAT_DEFS = `<defs><pattern id="hd" width="3" height="3" patternUnits="userSpaceOnUse"><rect width="3" height="3" fill="#fff"/><circle cx="1.5" cy="1.5" r=".85" fill="#000"/></pattern><pattern id="hh" width="3" height="3" patternUnits="userSpaceOnUse" patternTransform="rotate(45)"><rect width="3" height="3" fill="#fff"/><rect width="1.4" height="3" fill="#000"/></pattern></defs>`;
function heatCell(x, y, c, lv, x4, today){
  const rx = c > 7 ? 2 : 1.2;
  if (!x4) return `<rect x="${x}" y="${y}" width="${c}" height="${c}" rx="${rx}" fill="${HEAT_FILL_M8C[lv]}"${today ? ' stroke="#000" stroke-width="1.5"' : ''}/>`;
  const fill = ['#fff', '#fff', 'url(#hd)', 'url(#hh)', '#000'][lv]; const st = lv === 0 && !today ? '' : ` stroke="#000" stroke-width="${today ? 2 : .8}"`;
  const o = today ? 1 : .4; return `<rect x="${(+x + o).toFixed(1)}" y="${(+y + o).toFixed(1)}" width="${(c - 2*o).toFixed(1)}" height="${(c - 2*o).toFixed(1)}" rx="${rx}" fill="${fill}"${st}/>`;
}
function heatSwatch(lv, x4, today){ return `<svg width="11" height="11" style="display:block">${x4 ? HEAT_DEFS : ''}${heatCell(0, 0, 11, lv, x4, today)}</svg>`; }
W.year = {name:'Year in reading', icon:'grid', rel:'next', desc:'Every day of the past year as a dot: darker means more reading.',
  sizes:{m8c:[[4,2],[4,3]], x4:[[2,3],[2,2]]},
  render(t){
    const x4 = t.dev === 'x4'; const iw = t.w - 2*t.tp; const tall = t.h > 280;
    const days = HEAT.filter(v => v > 0).length; const g = x4 ? 2 : 2.5;
    const split = tall && iw / 52 < 10; const bigStats = tall && !split; let weeks = split ? 26 : 52;
    const availH = t.h - 2*t.tp - 22 - (bigStats ? 64 : 0) - 26 - (split ? 2*18 + 10 : 18);
    let cell = Math.floor(Math.min((iw - (weeks-1)*g) / weeks, (availH / (split ? 2 : 1) - 6*g) / 7) * 10) / 10;
    const gw = weeks*cell + (weeks-1)*g; const gh = 7*cell + 6*g;
    const band = (w0) => { let rects = ''; for (let w = 0; w < weeks; w++) for (let d = 0; d < 7; d++){ const i = (w0 + w)*7 + d; rects += heatCell((w*(cell+g)).toFixed(1), (d*(cell+g)).toFixed(1), cell, HEAT_LEVEL(HEAT[i]), x4, i === 363); } return `<svg width="${gw.toFixed(0)}" height="${gh.toFixed(0)}" style="display:block;margin-top:4px">${x4 ? HEAT_DEFS : ''}${rects}</svg>`; };
    const months = ['Dec','Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov'];
    const mlab = (ms) => `<div style="position:relative;height:14px;font-size:10.5px;color:var(--g1);font-weight:600">${ms.map((m, i) => `<span style="position:absolute;left:${(i * 52/12 * (cell+g)).toFixed(0)}px">${m}</span>`).join('')}</div>`;
    const legend = `<div style="display:flex;align-items:center;gap:4px;font-size:11px;color:var(--g1)">Less ${[0,1,2,3,4].map(l => heatSwatch(l, x4)).join('')} More<span style="width:10px"></span>${heatSwatch(2, x4, true)} Today</div>`;
    const bigs = bigStats ? `<div style="display:flex;gap:${x4 ? 18 : 30}px;margin:12px 0 4px">${[[days,'days read'],[REC.books,'books finished'],[REC.best,'longest streak']].map(([v, l]) => `<div><div class="num" style="font-size:${x4 ? 24 : 30}px;font-weight:700;line-height:1">${v}</div><div style="font-size:var(--fc);color:var(--g1);margin-top:3px">${l}</div></div>`).join('')}</div>` : '';
    return `<div class="tin">${head('Year in reading', bigStats ? '' : `${days} days read · ${REC.books} books`)}${bigs}<div style="flex:1"></div>
      <div style="align-self:center">${split ? mlab(months.slice(0, 6)) + band(0) + `<div style="height:10px"></div>` + mlab(months.slice(6)) + band(26) : mlab(months) + band(0)}</div>
      <div style="flex:1"></div><div style="display:flex;justify-content:flex-end;align-items:center;margin-top:8px">${legend}</div></div>`;
  }};

W.hours = {name:'When you read', icon:'sunmoon', rel:'later', desc:'The hours of the day you usually read.',
  sizes:{m8c:[[2,2],[2,3],[2,1],[4,1]], x4:[[2,2],[1,2],[2,1]]},
  render(t){
    const max = Math.max(...HOURS); const peak = HOURS.indexOf(max); const short = t.h < 120; const narrow = t.w < 260;
    const bars = HOURS.map((v, i) => `<div style="flex:1;height:${Math.max(v ? 4 : 1, Math.round(v / max * 100))}%;background:${i === peak ? '#000' : v ? 'var(--g2)' : 'var(--g3)'};border-radius:2px 2px 0 0"></div>`).join('');
    const axis = ['00','06','12','18',''].map((h, i) => `<span style="flex:${i < 4 ? 6 : 0};font-size:10.5px;color:var(--g1)">${h}</span>`).join('');
    return `<div class="tin"><div class="th"><span class="lab">When you read</span>${short ? `<span style="margin-left:auto;font-size:var(--fs);font-weight:700">Evenings</span>` : `<span style="margin-left:auto">${ic('sunmoon', 18, 2)}</span>`}</div>
      ${short ? '' : `<div style="font-size:22px;font-weight:700;margin-top:6px">Evenings</div><div style="font-size:var(--fc);color:var(--g1);margin-top:2px">Most at ${peak}:00${narrow ? '' : ' · 71% after 18:00'}</div>`}
      <div style="flex:1;display:flex;gap:${narrow ? 1 : 2}px;align-items:flex-end;margin-top:10px;border-bottom:1.5px solid #000;min-height:0">${bars}</div>${short ? '' : `<div style="display:flex;margin-top:4px">${axis}</div>`}</div>`;
  }};

W.records = {name:'Reading records', icon:'award', rel:'later', desc:'Pages turned, longest session, best day, books this year and your streak, in one place.',
  sizes:{m8c:[[3,2],[2,2],[4,1]], x4:[[2,2],[2,3]]},
  render(t){
    const x4 = t.dev === 'x4';
    const cmp = t.h < 260 && t.w < 420;
    const st = (v, l, extra = '') => `<div style="min-width:0"><div class="num" style="font-size:${cmp ? 17 : x4 ? 20 : 21}px;font-weight:700;line-height:1.05;white-space:nowrap">${v}</div><div style="font-size:var(--fc);color:var(--g1);margin-top:3px" class="ell">${l}</div>${extra}</div>`;
    const dots = `<div style="display:flex;gap:4px;margin-top:6px">${[1,1,1,1,1,1,1].map(() => `<i style="width:9px;height:9px;border-radius:9px;background:#000;display:block"></i>`).join('')}</div>`;
    const four = [st(fmtDur(REC.longest), 'longest session'), st(REC.bestDay + ' pp', 'best day · ' + REC.bestDayLabel), st(REC.books, 'books this year'), st(REC.streak + ' days', 'streak · best ' + REC.best, cmp || t.w > 420 ? '' : dots)];
    if (t.h < 120) return `<div class="tin">${head('Reading records')}<div style="flex:1;display:flex;align-items:flex-end;justify-content:space-between;gap:12px">${st(fmtN(REC.pages), 'pages turned')}${four.slice(0,3).join('')}</div></div>`;
    const big = `<div><div class="num" style="font-size:${cmp ? 30 : x4 ? 36 : 40}px;font-weight:700;letter-spacing:-.02em;line-height:1">${fmtN(REC.pages)}</div><div style="font-size:var(--fs);color:var(--g1);margin-top:4px">pages turned, all time</div></div>`;
    const streak = `<div style="display:flex;align-items:center;gap:6px;font-size:var(--fc);font-weight:700;white-space:nowrap">${ic('flame', 16)}Reading ${REC.streak} days running</div>`;
    if (t.w > 420 && t.h < 260){ // wide and short: the big number with the streak beside it, then one row of four
      return `<div class="tin">${head('Reading records')}<div style="display:flex;align-items:flex-end;justify-content:space-between;gap:12px;margin-top:8px">${big}${streak}</div><div class="hair" style="margin:12px 0"></div><div style="display:grid;grid-template-columns:repeat(4,1fr);gap:14px">${four.join('')}</div></div>`;
    }
    const grid = `<div style="display:grid;grid-template-columns:1fr 1fr;gap:${x4 ? 14 : 12}px 16px">${four.join('')}</div>`;
    const tallx = t.h > 260;
    return `<div class="tin">${head('Reading records')}<div style="margin-top:10px">${big}</div>${tallx ? '<div class="hair" style="margin:16px 0"></div>' : '<div style="flex:1;min-height:10px"></div>'}${grid}${tallx ? `<div style="flex:1"></div>${streak}` : ''}</div>`;
  }};

W.clock = {name:'Clock & battery', icon:'clock', rel:'opt', desc:'Time, date and battery in one widget. Optional.',
  sizes:{m8c:[[1,2],[2,1],[2,2]], x4:[[2,2],[1,1],[2,1]]},
  render(t){
    const wide = t.w > 260; const short = t.h < 120;
    const bat = `<div style="display:flex;align-items:center;gap:6px;font-size:var(--fc);font-weight:700">${ic('battery', 18, 2)}<span class="num">78%</span></div>`;
    if (short) return `<div class="tin" style="flex-direction:row;align-items:center;gap:14px"><div class="num" style="font-size:34px;font-weight:700;letter-spacing:-.02em">21:42</div><div style="flex:1"><div style="font-size:var(--fs);font-weight:700">Tuesday</div><div style="font-size:var(--fc);color:var(--g1)">25 November</div></div>${wide ? bat : ''}</div>`;
    if (!wide) return `<div class="tin"><div class="num" style="font-size:42px;font-weight:700;letter-spacing:-.03em;line-height:1">21:42</div><div style="font-size:var(--fb);font-weight:700;margin-top:8px">Tuesday</div><div style="font-size:var(--fs);color:var(--g1)">25 November</div>
      <div style="flex:1"></div><div style="display:flex;justify-content:space-between;font-size:var(--fc);font-weight:700"><span style="display:flex;gap:5px;align-items:center">${ic('battery', 16, 2)}Battery</span><span class="num">78%</span></div><div class="bar1" style="height:6px;margin-top:5px"><b style="width:78%"></b></div>
      <div style="display:flex;align-items:center;gap:6px;font-size:var(--fc);color:var(--g1);margin-top:10px">${ic(S.offline ? 'cloudoff' : 'wifi', 16, 2)}${S.offline ? 'Offline' : 'Synced 12 min ago'}</div></div>`;
    const strip = `<div style="display:flex;justify-content:space-between;margin-top:12px">${['M','T','W','T','F','S','S'].map((d, i) => `<div style="width:28px;height:40px;border-radius:9px;display:flex;flex-direction:column;align-items:center;justify-content:center;font-size:11px;font-weight:700;${i === 1 ? 'background:#000;color:#fff' : ''}">${d}<span class="num" style="font-size:13px">${24 + i > 30 ? 24 + i - 30 : 24 + i}</span></div>`).join('')}</div>`;
    return `<div class="tin"><div class="num" style="font-size:46px;font-weight:700;letter-spacing:-.03em;line-height:1">21:42</div><div style="font-size:var(--fs);font-weight:700;margin-top:6px">Tuesday</div><div style="font-size:var(--fc);color:var(--g1)">25 November</div>${strip}<div style="flex:1"></div><div style="display:flex;justify-content:space-between;align-items:center">${bat}<span style="font-size:var(--fc);color:var(--g1)">${S.offline ? 'Offline' : 'Synced 12 min ago'}</span></div></div>`;
  }};

W.recommend = {name:'Recommended for you', icon:'sparkle', rel:'later', placeholder:true, desc:'Coming later: picks based on what you\'ve read, rated and liked, using authors, tags and series. Not random.',
  sizes:{m8c:[[4,2],[2,2]], x4:[[2,2]]},
  render(t){ const n = t.w > 400 ? 4 : 2; return `<div class="tin" style="border:0">${head('Recommended for you', 'Coming later')}<div style="flex:1;display:flex;gap:16px;align-items:center;margin-top:8px">${Array.from({length:n}, () => `<div style="width:58px;height:87px;border:1.5px dashed var(--g2);border-radius:3px;flex:none"></div>`).join('')}<div style="font-size:var(--fc);color:var(--g1);line-height:1.4;min-width:0">Picks from your reading history, ratings, favourite authors and tags.</div></div></div>`; }};
const LATER = [['highlight','Highlight of the day','highlight'],['buddy','Reading buddy','buddy'],['discover','Discover (random)','dice'],['yearago','A year ago','rewind'],['word','Word of the day','word'],['light','Light','bulb']];
for (const [id, n, i] of LATER) W[id] = {name:n, icon:i, rel:'later', placeholder:true, dropped:true, desc:'Dropped from the default Home. Kept for later as an optional widget.', sizes:{m8c:[[2,1],[2,2]], x4:[[2,1]]},
  render(t){ return `<div class="tin"><div class="th"><span class="lab">${n}</span><span style="margin-left:auto">${ic(i, 18)}</span></div><div style="flex:1"></div><div style="font-size:var(--fc);color:var(--g1)">Later release · optional</div></div>`; }};
