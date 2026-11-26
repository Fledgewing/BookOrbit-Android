// ---------- Book list: one widget, driven by its configuration {title, src, style, sort, cap} ----------
// "Recently added", "Want to read", "Also reading" and "Finished" are only preset configurations of it.
const BL_SORTS = ['List order','Title','Author','Last read'];
const BL_CAPS = ['No caption','Date added','Progress','Author'];
const BL_STYLES = ['Cover shelf','Rows with progress'];
const BL_SIZES = {m8c:[[2,2],[4,2],[2,3],[4,3],[2,1]], x4:[[2,2],[1,2],[2,3],[2,4],[2,1]]};
function srcBooks(src){
  const all = Object.values(B); const [k, v] = src.split(':');
  if (k === 'recent') return RECENT(); if (k === 'wtr') return WTR(); if (k === 'reading') return IN_PROGRESS_ORDER().filter(b => b.id !== S.hero);
  if (k === 'finished') return all.filter(b => b.read); if (k === 'device') return all.filter(b => b.dev); if (k === 'all') return all;
  if (k === 'list'){ const s = SCOPES.find(x => x.id === v); const r = rng(s.c); return all.filter(() => r() > .35); }
  if (k === 'series') return SERIES[v].books.map(x => B[x]); if (k === 'author') return all.filter(b => b.a === decodeURIComponent(v));
  return all;
}
function srcName(src){ const [k, v] = src.split(':'); return ({recent:'Recently added', wtr:'Want to read', reading:'Reading now', finished:'Finished', device:'On this device', all:'Library'})[k]
  || (k === 'list' ? SCOPES.find(x => x.id === v).n : k === 'series' ? SERIES[v].name : decodeURIComponent(v)); }
function srcCount(src){ const [k, v] = src.split(':'); if (k === 'wtr') return WTR_COUNT(); if (k === 'all') return LIB.total; if (k === 'device') return LIB.device; if (k === 'list') return SCOPES.find(x => x.id === v).c; return srcBooks(src).length; }
function srcIcon(src){ const k = src.split(':')[0]; return ({recent:'inbox', wtr:'bookmark', reading:'layers', finished:'check', device:'device', all:'books', list:'filter', series:'stack', author:'user'})[k]; }
function sortBooks(list, s){ const l = list.slice(); if (s === 1) l.sort((a, b) => a.t.localeCompare(b.t)); if (s === 2) l.sort((a, b) => a.a.localeCompare(b.a)); if (s === 3) l.sort((a, b) => (a.last ?? 999) - (b.last ?? 999)); return l; }
function capText(b, c){ if (c === 1) return b.added === 0 ? 'Today' : b.added === 1 ? 'Yesterday' : b.added < 30 ? b.added + ' days ago' : 'Earlier'; if (c === 2) return b.read ? 'Finished' : b.prog != null ? Math.round(curPage(b) / b.pages * 100) + '%' : 'Not started'; if (c === 3) return b.a; return ''; }
const allAct = cfg => `lst:${cfg.src}|${encodeURIComponent(cfg.title)}|${cfg.style}`;
const fkBase = src => ({recent:'recent', wtr:'wtr', reading:'also'})[src] || 'bl';
W.booklist = {name:'Book list', icon:'stack', rel:'now', desc:'Any list of books, with your own title: recently added, want to read, reading now, finished, on this device, one of your Lists, a series or an author. Shown as a cover shelf or as rows with progress.',
  sizes:BL_SIZES,
  render(t){
    const cfg = t.cfg || {title:'Book list', src:'recent', style:0, sort:0, cap:1};
    const list = sortBooks(srcBooks(cfg.src), cfg.sort); const fb = fkBase(cfg.src); const n0 = srcCount(cfg.src);
    if (cfg.style === 0){
      const meta = cfg.src === 'recent' ? (t.w > 300 ? `${list.filter(b => b.added < 7).length} this week` : '') : t.w > 300 || t.h > 200 ? fmtN(n0) : '';
      return coverRow(t, list, esc(cfg.title), meta, allAct(cfg), fb + '-all', cfg.cap ? b => capText(b, cfg.cap) : null);
    }
    // rows with progress (what Also reading was)
    const x4 = t.dev === 'x4'; const hd = head(esc(cfg.title), '', `All ${fmtN(n0)}`, allAct(cfg), fb + '-all'); const ih = t.h - 2*t.tp - 24;
    const pctOf = b => b.prog != null ? Math.round(curPage(b) / b.pages * 100) : null;
    if (t.w > 500){
      const ch = ih - 34, cw = Math.round(ch * 2/3); const n = Math.min(list.length, Math.floor((t.w - 2*t.tp + 16) / (cw + 16)));
      return `<div class="tin">${hd}<div style="flex:1;display:flex;gap:16px;margin-top:10px;justify-content:space-between">${list.slice(0, n).map(b => { const p = pctOf(b); return `<div style="width:${cw}px">${coverEl(b, cw, ch)}${p != null ? `<div class="bar1" style="margin-top:9px;height:4px"><b style="width:${p}%"></b></div><div class="num" style="font-size:11px;font-weight:700;margin-top:4px">${p}%</div>` : `<div class="ell" style="font-size:11px;font-weight:700;margin-top:9px">${esc(capText(b, cfg.cap || 3))}</div>`}</div>`; }).join('')}</div></div>`;
    }
    const narrow = t.w < 260;
    const n = Math.min(list.length, clamp(Math.floor(ih / 64), 1, 4)); const rowH = Math.floor(ih / Math.max(1, n));
    const rows = list.slice(0, n).map(b => { const p = pctOf(b); const th = rowH - 6; const cap = cfg.cap === 2 || (cfg.cap === 0 && p != null) ? null : capText(b, cfg.cap || 3);
      return `<div class="lrow" style="height:${rowH}px;gap:${narrow ? 10 : 14}px" data-act="book:${b.id}" data-book="${b.id}" data-fk="${fb === 'also' ? 'also' : 'bl'}-${b.id}">
      ${coverEl(b, Math.round(th*2/3), th, {noact:true})}
      <div style="flex:1;min-width:0"><div style="font-size:var(--fs);font-weight:700;line-height:1.2;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden">${esc(b.t)}</div>
      ${cap != null ? `<div class="ell" style="font-size:var(--fc);color:var(--g1);margin-top:4px">${esc(cap)}</div>` : narrow ? `<div class="num" style="font-size:var(--fc);color:var(--g1);margin-top:4px">${p}% · ${b.last} d ago</div>` :
      `<div style="display:flex;align-items:center;gap:8px;margin-top:7px"><div class="bar1" style="width:${x4 ? 80 : 70}px;height:5px"><b style="width:${p}%"></b></div><span class="num" style="font-size:var(--fc);font-weight:700">${p}%</span></div><div style="font-size:var(--fc);color:var(--g1);margin-top:3px">${b.last === 0 ? 'Read today' : 'Read ' + b.last + ' days ago'}${b.dev ? '' : ' · on server'}</div>`}</div>
      ${narrow ? '' : `<div style="color:#000">${ic(b.dev ? 'chevR' : 'clouddl', 18, 2.2)}</div>`}</div>`; }).join('');
    return `<div class="tin">${hd}<div style="margin-top:4px;display:flex;flex-direction:column">${rows}</div></div>`;
  }};
// Picker presets: friendly names that add a preconfigured Book list.
const BL_PRESET = (title, src, style, sort, cap, icon, rel, desc) => ({preset:true, name:title, icon, rel, desc, sizes:BL_SIZES, cfg:{title, src, style, sort, cap}, render(t){ return W.booklist.render({...t, cfg:this.cfg}); }});
W.also = BL_PRESET('Also reading', 'reading', 1, 3, 2, 'layers', 'now', 'Book list preset: Reading now, rows with progress, without the book in Continue reading.');
W.recent = BL_PRESET('Recently added', 'recent', 0, 0, 1, 'inbox', 'now', 'Book list preset: the newest books on your server, as a cover shelf captioned with the date added.');
W.wtr = BL_PRESET('Want to read', 'wtr', 0, 0, 0, 'bookmark', 'now', 'Book list preset: books you marked to read next, as a cover shelf.');
W.finished = BL_PRESET('Finished', 'finished', 0, 3, 3, 'check', 'now', 'Book list preset: books you have finished, most recent first.');
const tileName = tl => tl.cfg ? tl.cfg.title : W[tl.w].name;
const tileIcon = tl => tl.cfg ? srcIcon(tl.cfg.src) : W[tl.w].icon;
const asBooklist = tl => W[tl.w] && W[tl.w].preset ? {w:'booklist', x:tl.x, y:tl.y, cw:tl.cw, ch:tl.ch, cfg:{...W[tl.w].cfg}} : tl;

// Configuration sheet (paged, no scrolling; every row works with Prev/Next/Select).
function blcfgView(m, g){
  const x4 = dk() === 'x4'; const c = m.cfg; const classic = S.dev === 'x4c'; const w = x4 ? 460 : 620;
  const row = (l, v, act, fk, extra = '') => `<div class="lrow" data-act="${act}" data-fk="${fk}" style="min-height:60px;border-bottom:1px solid var(--g3);gap:12px"><span style="flex:1;font-size:var(--fb);font-weight:600">${l}</span><span style="display:flex;align-items:center;gap:6px;font-size:var(--fs);font-weight:700;text-align:right">${v}${extra}${ic('chevR', 16, 2.6)}</span></div>`;
  let body;
  if (!m.pg){
    body = `<div style="display:flex;align-items:center;gap:12px;min-height:64px;border-bottom:1px solid var(--g3)"><span style="font-size:var(--fb);font-weight:600;flex:none">Title</span>
        ${classic ? `<div data-act="bltitle" data-fk="cfg-title" style="flex:1;text-align:right;font-size:var(--fs);font-weight:700;height:var(--tap);display:flex;align-items:center;justify-content:flex-end;gap:6px">${esc(c.title)}<span class="meta" style="font-weight:500">· Select for ideas</span></div>`
          : `<input id="blt" value="${esc(c.title)}" style="flex:1;min-width:0;height:var(--tap);border:2px solid #000;border-radius:12px;padding:0 12px;font:700 var(--fb) var(--sans)" data-fk="cfg-title-in">`}</div>
      ${row('Source', `${ic(srcIcon(c.src), 18, 2.2)}${esc(srcName(c.src))}`, 'blpg:1', 'cfg-src')}
      <div style="min-height:64px;border-bottom:1px solid var(--g3);display:flex;align-items:center;gap:12px"><span style="font-size:var(--fb);font-weight:600;flex:none">Style</span><div class="sg" style="flex:1">${BL_STYLES.map((s, i) => `<div class="${c.style === i ? 'on' : ''}" data-act="blset:style:${i}" data-fk="cfg-style-${i}">${x4 ? s.split(' ')[0] : s}</div>`).join('')}</div></div>
      ${row('Sort', BL_SORTS[c.sort], 'blcyc:sort:' + BL_SORTS.length, 'cfg-sort')}
      ${row('Caption under each book', BL_CAPS[c.cap], 'blcyc:cap:' + BL_CAPS.length, 'cfg-cap')}
      <div style="display:flex;gap:10px;margin-top:18px"><div class="pill wh" style="flex:1" data-act="closeModal" data-fk="cfg-cancel">Cancel</div><div class="pill" style="flex:1" data-act="bldone" data-fk="cfg-done">${ic('check', 18, 2.6)}Done</div></div>`;
  } else {
    const items = [...['recent','wtr','reading','finished','device'].map(s => ({s, sec:'Built in'})), ...SCOPES.map(s => ({s:'list:' + s.id, sec:'Your lists'})), ...Object.keys(SERIES).map(k => ({s:'series:' + k, sec:'Series'})), ...[...new Set(Object.values(B).map(b => b.a))].sort().slice(0, 8).map(a => ({s:'author:' + encodeURIComponent(a), sec:'Authors'}))];
    const pp = paged(items, 52, x4 ? 470 : 560, 'blsrc');
    let last = ''; body = pp.slice.map(it => { const h = it.sec !== last ? (last = it.sec, `<div class="cap" style="padding:10px 0 2px">${it.sec}</div>`) : ''; return h + `<div class="lrow" data-act="blsrc:${it.s}" data-fk="src-${it.s.replace(/[^a-z0-9]/gi, '')}" style="height:52px;border-bottom:1px solid var(--g3);gap:12px;${it.s === c.src ? 'font-weight:800' : ''}">${ic(srcIcon(it.s), 18, 2.2)}<span style="flex:1" class="ell">${esc(srcName(it.s))}</span><span class="num meta">${fmtN(srcCount(it.s))}</span>${it.s === c.src ? ic('check', 18, 2.8) : ''}</div>`; }).join('') + pagerRow(pp, 'blsrc');
  }
  return `<div class="scrim" data-act="closeModal"></div><div class="card" style="left:50%;top:50%;transform:translate(-50%,-50%);width:${w}px;padding:${x4 ? 16 : 22}px;border-radius:18px">
    <div style="display:flex;align-items:center;gap:10px;margin-bottom:6px">${m.pg ? `<div class="iconbtn flat" data-act="blpg:0" data-fk="cfg-back">${ic('chevL', 22, 2.6)}</div>` : ''}<div class="ser" style="font-size:var(--fm);font-weight:700;flex:1">${m.pg ? 'Choose a source' : 'Configure Book list'}</div></div>${body}</div>`;
}

// The shared List screen: every source, every widget's "All". Group by none / author / series; sort; pages.
function listView(c, g){
  const x4 = dk() === 'x4'; const P = g.padx + 6; const shh = x4 ? 54 : 64; const grp = c.group || 0;
  const books = sortBooks(srcBooks(c.src), c.sort || 0); const title = c.title || srcName(c.src);
  const ctl = `<div style="display:flex;gap:10px;align-items:center;padding:12px ${P}px 0"><span style="font-size:var(--fc);font-weight:700;flex:none">Group</span><div class="sg" style="flex:1">${['None','Author','Series'].map((s, i) => `<div class="${grp === i ? 'on' : ''}" data-act="grp:${i}" data-fk="grp-${i}">${s}</div>`).join('')}</div></div>
    <div style="display:flex;gap:8px;padding:10px ${P}px 0;overflow:hidden">${BL_SORTS.map((s, i) => `<span class="chip${(c.sort || 0) === i ? ' on' : ''}" data-act="sort:${i}" data-fk="sort-${i}">${x4 && i === 3 ? 'Last read' : s}</span>`).join('')}</div>`;
  const avail = g.H - shh - 140 - 60; const key = 'L' + c.src + grp;
  let body;
  if (grp){
    const map = new Map(); for (const b of books){ const k = grp === 1 ? b.a : (b.series || '~'); if (!map.has(k)) map.set(k, []); map.get(k).push(b); }
    let groups = [...map.entries()].map(([k, bs]) => ({k, bs:grp === 2 && k !== '~' ? bs.sort((a, b) => a.no - b.no) : bs}));
    groups.sort((a, b) => a.k === '~' ? 1 : b.k === '~' ? -1 : (grp === 2 ? SERIES[a.k].name.localeCompare(SERIES[b.k].name) : a.k.localeCompare(b.k)));
    const cw = x4 ? 52 : 62, ch = Math.round(cw * 1.5); const gh = 50 + ch + 18;
    const pp = paged(groups, gh, avail, key);
    body = pp.slice.map(gr => { const ser = grp === 2 && gr.k !== '~' ? SERIES[gr.k] : null; const max = Math.floor((g.W - 2*P + 10) / (cw + 10));
      const dots = ser ? `<div style="display:flex;gap:4px;width:${x4 ? 70 : 110}px">${ser.books.map(x => { const b = B[x]; return `<div style="flex:1;height:8px;border-radius:4px;border:1.5px solid #000;background:${b.read ? '#000' : b.prog != null ? 'linear-gradient(90deg,#000 50%,#fff 50%)' : '#fff'}"></div>`; }).join('')}</div>` : '';
      const hdAct = ser ? `series:${gr.k}` : grp === 1 ? `lst:author:${encodeURIComponent(gr.k)}|${encodeURIComponent(gr.k)}|0` : '';
      return `<div style="border-bottom:1px solid var(--g3);padding-bottom:10px"><div class="lrow" ${hdAct ? `data-act="${hdAct}" data-fk="gh-${encodeURIComponent(gr.k).replace(/[^a-z0-9]/gi, '')}"` : ''} style="height:50px;gap:10px">${ic(grp === 1 ? 'user' : 'stack', 18, 2.2)}<b style="font-size:var(--fb);flex:1;min-width:0" class="ell">${esc(ser ? ser.name : gr.k === '~' ? 'Not in a series' : gr.k)}</b>${dots}<span class="num meta" style="font-size:var(--fc)">${gr.bs.length}</span>${hdAct ? ic('chevR', 16, 2.6) : ''}</div>
        <div style="display:flex;gap:10px">${gr.bs.slice(0, max).map(b => coverEl(b, cw, ch)).join('')}</div></div>`; }).join('') + `<div style="position:absolute;left:0;right:0;bottom:8px">${pagerRow(pp, key)}</div>`;
  } else if (c.src === 'reading'){
    const all = IN_PROGRESS_ORDER(); const active = all.filter(b => b.last < 21), paused = all.filter(b => b.last >= 21); const rowH = x4 ? 92 : 104;
    const extra = b => { const pct = Math.round(curPage(b)/b.pages*100); const f = forecast(b); return `<div style="display:flex;align-items:center;gap:8px;margin-top:7px"><div class="bar1" style="width:${x4 ? 90 : 140}px;height:6px"><b style="width:${pct}%"></b></div><span class="num" style="font-size:var(--fc);font-weight:700">${pct}%</span><span style="font-size:var(--fc);color:var(--g1)">${fmtDur(f.left)} left</span></div>`; };
    const sec = (t) => `<div class="cap" style="color:var(--g1);padding:12px 0 4px">${t}</div>`;
    const items = [{h:'Active · last 3 weeks'}, ...active, {h:'Put down · not opened in 3+ weeks'}, ...paused];
    const per = Math.floor(avail / rowH); body = `<div style="padding:0 ${P}px">${items.slice(0, per + 1).map(it => it.h ? sec(it.h) : bookRow(it, rowH, extra)).join('')}</div>`;
  } else {
    const cg = coverGrid(books, g, avail + 20, key); body = cg.html + `<div style="position:absolute;left:0;right:0;bottom:8px">${pagerRow(cg.pp, key)}</div>`;
  }
  return shdr(title, `${fmtN(srcCount(c.src))} books${c.src.startsWith('list:') ? ' · ' + SCOPES.find(x => 'list:' + x.id === c.src).d : ''}`, searchBtn()) + ctl + (grp ? `<div style="padding:4px ${P}px 0">${body}</div>` : body);
}
