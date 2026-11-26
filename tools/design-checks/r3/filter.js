// ---------- Filter sheet: ONE component behind every filter button ----------
// Used by every List screen ("All ›" of a Book list, a List, Reading now, the Library grouped by author or series), by Search,
// and by a Book list's "Custom filter" source. Same sections, same order, same behaviour; a section that doesn't apply is hidden.
// It edits a neutral filter object. The UI hands that object to the BookSync library interface (books.query); each server
// adapter translates what it can, and anything it can't express (On this device, Group) runs locally on the cached catalog.
const F_SHOW = ['All', 'Unread', 'Reading', 'Finished'];
const F_WHERE = ['Anywhere', 'On this device', 'Server only'];
const F_LEN = [{n:'Any length'}, {n:'Short', d:'under 250 pages', a:0, b:249}, {n:'Medium', d:'250 to 450 pages', a:250, b:450}, {n:'Long', d:'over 450 pages', a:451, b:1e9}];
const F_RATE = ['Any rating', '3★ and up', '4★ and up', '5★ only'];
const F_ADDED = ['Any time', 'This week', 'This month', 'This year'];
const F_SORT = {order:'List order', match:'Best match', title:'Title', author:'Author', last:'Last read', added:'Added', rating:'Rating'};
const F_DIR = {order:['As listed', 'Reversed'], match:['Best first', 'Reversed'], title:['A to Z', 'Z to A'], author:['A to Z', 'Z to A'], last:['Most recent first', 'Oldest first'], added:['Newest first', 'Oldest first'], rating:['Highest first', 'Lowest first']};
const F_GROUP = ['None', 'Author', 'Series'];
const FSAVED = {}; let FSEQ = 0; // filters saved with Book lists (device-local)
// What applies where. Only these differ between contexts.
function fctx(c){
  if (c.n === 'search') return {name:'Search', sorts:['match', 'title', 'author', 'added', 'rating'], show:true, group:true, sort:true, save:true};
  if (c.n === 'cfg') return {name:'Book list', sorts:[], show:true, group:false, sort:false, save:false};
  if (c.src === 'reading') return {name:'Reading now', sorts:['last', 'title', 'author', 'added'], show:false, group:true, sort:true, save:true};
  return {name:c.title || srcName(c.src), sorts:['order', 'title', 'author', 'last', 'added', 'rating'], show:true, group:true, sort:true, save:true};
}
const fdef = c => ({show:0, wtr:false, where:0, authors:[], series:[], tags:[], len:0, rate:0, added:0, group:c.group || 0, sort:(fctx(c).sorts[0] || 'order'), dir:0});
const fOf = c => c.f || (c.f = fdef(c));
// Each active part of a filter, in sheet order: what the chips, the subtitle and the X3 line show.
function fparts(f, c){ const d = fdef(c); const out = [];
  if (f.show) out.push(['show', F_SHOW[f.show]]); if (f.wtr) out.push(['wtr', 'Want to read']);
  if (f.where) out.push(['where', f.where === 1 ? 'On device' : 'Server only']);
  f.authors.forEach(a => out.push(['authors:' + a, a])); f.series.forEach(s => out.push(['series:' + s, SERIES[s].name])); f.tags.forEach(t => out.push(['tags:' + t, t]));
  if (f.len) out.push(['len', F_LEN[f.len].n]); if (f.rate) out.push(['rate', F_RATE[f.rate]]); if (f.added) out.push(['added', 'Added ' + F_ADDED[f.added].toLowerCase()]);
  if (f.group !== d.group) out.push(['group', f.group ? 'By ' + F_GROUP[f.group].toLowerCase() : 'Not grouped']);
  if (f.sort !== d.sort || f.dir) out.push(['sort', F_SORT[f.sort] + (f.dir ? ' · ' + F_DIR[f.sort][1].toLowerCase() : '')]);
  return out; }
const fNarrows = (f, c) => fparts(f, c).some(([k]) => k !== 'group' && k !== 'sort');
function fApply(list, f){ return list.filter(b => {
    if (f.show === 1 && (b.prog != null || b.read)) return false; if (f.show === 2 && (b.prog == null || b.read)) return false; if (f.show === 3 && !b.read) return false;
    if (f.wtr && !b.wtr) return false; if (f.where === 1 && !b.dev) return false; if (f.where === 2 && b.dev) return false;
    if (f.authors.length && !f.authors.includes(b.a)) return false; if (f.series.length && !f.series.includes(b.series)) return false;
    if (f.tags.length && !(b.tags || []).some(t => f.tags.includes(t))) return false;
    if (f.len){ const L = F_LEN[f.len]; if (b.pages < L.a || b.pages > L.b) return false; }
    if (f.rate && (b.rate || 0) < [0, 3, 4, 5][f.rate]) return false;
    if (f.added && b.added >= [0, 7, 31, 365][f.added]) return false;
    return true; }); }
function fSort(list, f){ const l = list.slice(); const k = f.sort;
  if (k === 'title') l.sort((a, b) => a.t.localeCompare(b.t)); if (k === 'author') l.sort((a, b) => a.a.localeCompare(b.a));
  if (k === 'last') l.sort((a, b) => (a.last ?? 999) - (b.last ?? 999)); if (k === 'added') l.sort((a, b) => a.added - b.added); if (k === 'rating') l.sort((a, b) => (b.rate || 0) - (a.rate || 0));
  return f.dir ? l.reverse() : l; }
// The books a filter starts from in each context.
function fBase(c){ if (c.n === 'search'){ const q = (c.q || '').toLowerCase(); return q ? Object.values(B).filter(b => (b.t + ' ' + b.a + ' ' + b.tags.join(' ')).toLowerCase().includes(q)) : Object.values(B); }
  if (c.n === 'cfg') return Object.values(B); return srcBooks(c.src); }
const fResult = c => fSort(fApply(fBase(c), fOf(c)), fOf(c));
const fCount = c => c.n !== 'search' && c.n !== 'cfg' && !fNarrows(fOf(c), c) ? srcCount(c.src) : fApply(fBase(c), fOf(c)).length;
const fSummary = c => fparts(fOf(c), c).map(p => p[1]).map((s, i) => i ? s.charAt(0).toLowerCase() + s.slice(1) : s).join(' · ');
// The header button: filled when anything differs from this context's defaults.
const fBtn = c => { const on = fparts(fOf(c), c).length; return `<div class="iconbtn${on ? '' : ' flat'}" data-act="filter" data-fk="s-filter" title="Filter, group and sort">${ic(on ? 'filterf' : 'filter', 22, 2.2)}</div>`; };
// Active filters as removable chips in one row under the header. No row at all when nothing is active.
function fChips(c, P){ const ps = fparts(fOf(c), c); if (!ps.length) return ''; const x4 = dk() === 'x4'; const room = GEO[dk()].W - 2*P - 70; let used = 0; const shown = [];
  for (const p of ps){ const w = p[1].length * (x4 ? 7.6 : 8.2) + 50; if (used + w > room && shown.length) break; shown.push(p); used += w + 8; }
  const more = ps.length - shown.length;
  return `<div style="display:flex;gap:8px;padding:${x4 ? 8 : 10}px ${P}px 0;overflow:hidden;align-items:center">${shown.map(([k, l]) => `<span class="chip" data-act="fx:${esc(k)}" data-fk="fx-${k.replace(/[^a-z0-9]/gi, '')}" style="gap:6px;padding:0 10px 0 14px;flex:none">${esc(l)}${ic('x', 15, 2.6)}</span>`).join('')}${more ? `<span class="chip" data-act="filter" data-fk="fx-more" style="flex:none">+${more}</span>` : ''}</div>`; }
// Which screen or Book list the open sheet is editing.
function fTarget(){ const m = S.modal; if (m && m.ret) return {n:'cfg', f:FSAVED[m.ret.cfg.fid]}; return cur(); }
function filterView(m, g){
  const x4 = dk() === 'x4'; const c = fTarget(); const f = fOf(c); const cx = fctx(c); const W2 = x4 ? 460 : 640; const H2 = x4 ? 740 : 860; const U = x4 ? 54 : 58;
  const lib = fBase(c);
  if (m.pick){ // Author / Series / Tags: a paged list with counts; Select toggles
    const k = m.pick; const vals = k === 'series' ? Object.keys(SERIES) : [...new Set(lib.flatMap(b => k === 'authors' ? [b.a] : b.tags || []))].sort();
    const cnt = v => lib.filter(b => k === 'series' ? b.series === v : k === 'authors' ? b.a === v : (b.tags || []).includes(v)).length;
    const pp = paged(vals, U, H2 - 200, 'fpick' + k);
    const rows = pp.slice.map(v => { const on = f[k].includes(v); return `<div class="lrow" data-act="fpick:${esc(v)}" data-fk="fp-${String(v).replace(/[^a-z0-9]/gi, '')}" style="height:${U}px;border-bottom:1px solid var(--g3);gap:12px"><span style="width:22px;height:22px;border:2px solid #000;border-radius:5px;display:grid;place-items:center;flex:none;${on ? 'background:#000;color:#fff' : ''}">${on ? ic('check', 15, 3) : ''}</span><span style="flex:1;font-size:var(--fb);font-weight:${on ? 800 : 500}" class="ell">${esc(k === 'series' ? SERIES[v].name : v)}</span><span class="num meta" style="font-size:var(--fs)">${cnt(v)}</span></div>`; }).join('');
    return `<div class="scrim" data-act="fpickdone"></div><div class="card fsheet" style="left:50%;top:50%;transform:translate(-50%,-50%);width:${W2}px;height:${H2}px;padding:0;border-radius:18px;display:flex;flex-direction:column">
      <div style="display:flex;align-items:center;gap:8px;padding:10px 12px 8px 8px;border-bottom:1px solid var(--g3)"><div class="backbtn" data-act="fpickdone" data-fk="fp-back">${ic('chevL', 22, 2.6)}Filter</div><b style="font-size:var(--fm);flex:1">${({authors:'Author', series:'Series', tags:'Tags'})[k]}</b>${f[k].length ? `<span class="chip" data-act="fpickclear" data-fk="fp-clear">Clear ${f[k].length}</span>` : ''}</div>
      <div style="flex:1;padding:0 ${x4 ? 16 : 22}px">${rows}</div>${pageFoot(pp.p, pp.pages, 'fpick' + k)}</div>`;
  }
  const seg = (k, opts, fkp) => `<div class="sg" style="margin:${Math.round(U * .08)}px 0">${opts.map((o, i) => `<div class="${f[k] === i ? 'on' : ''}" data-act="fset:${k}:${i}" data-fk="${fkp}-${i}">${o}</div>`).join('')}</div>`;
  const row = (l, v, act, fk, sub) => `<div class="lrow" data-act="${act}" data-fk="${fk}" style="height:${U}px;border-bottom:1px solid var(--g3);gap:12px"><div style="flex:1;min-width:0"><div style="font-size:var(--fb);font-weight:600">${l}</div>${sub ? `<div class="meta" style="font-size:var(--fc)">${sub}</div>` : ''}</div><span style="font-size:var(--fs);font-weight:700;text-align:right;max-width:55%" class="ell">${v}</span>${ic('chevR', 16, 2.6)}</div>`;
  const tog = (l, k, fk) => `<div class="lrow" data-act="ftog:${k}" data-fk="${fk}" style="height:${U}px;border-bottom:1px solid var(--g3);gap:12px"><span style="flex:1;font-size:var(--fb);font-weight:600">${l}</span><span class="sw${f[k] ? ' on' : ''}"><i></i></span></div>`;
  const many = (k, none) => f[k].length === 0 ? none : f[k].length === 1 ? esc(k === 'series' ? SERIES[f[k][0]].name : f[k][0]) : f[k].length + ' chosen';
  const sec = t => ({kind:'sec', span:.62, h:`<div class="cap" style="padding:${x4 ? 10 : 12}px 0 2px">${t}</div>`});
  const it = (h, span = 1) => ({span, h});
  const items = [];
  if (cx.show){ items.push(sec('Show'), it(seg('show', x4 ? ['All', 'Unread', 'Reading', 'Done'] : F_SHOW, 'f-show'), 1.16), it(tog('Want to read only', 'wtr', 'f-wtr'))); }
  items.push(sec('Where'), it(seg('where', x4 ? ['Anywhere', 'On device', 'Server'] : F_WHERE, 'f-where'), 1.16));
  items.push(sec('Refine'), it(row('Author', many('authors', 'Any'), 'fpickopen:authors', 'f-authors')), it(row('Series', many('series', 'Any'), 'fpickopen:series', 'f-series')), it(row('Tags', many('tags', 'Any'), 'fpickopen:tags', 'f-tags')),
    it(row('Length', F_LEN[f.len].n + (f.len ? ` <span class="meta" style="font-weight:500">${F_LEN[f.len].d}</span>` : ''), 'fcyc:len:4', 'f-len')), it(row('Rating', F_RATE[f.rate], 'fcyc:rate:4', 'f-rate')), it(row('Added', F_ADDED[f.added], 'fcyc:added:4', 'f-added')));
  // Language and Format rows appear only when the library has more than one of each; this synthetic library has one of each.
  if (cx.group) items.push(sec('Group'), it(seg('group', F_GROUP, 'f-group'), 1.16));
  if (cx.sort) items.push(sec('Sort'), it(row('Sort by', F_SORT[f.sort], 'fsort', 'f-sort')), it(row('Order', F_DIR[f.sort][f.dir], 'fdir', 'f-dir')));
  if (cx.save) items.push(sec('Keep it'), it(`<div class="lrow" data-act="fsave" data-fk="f-save" style="height:${U}px;gap:12px;font-size:var(--fb);font-weight:700">${ic('plus', 20, 2.6)}<span style="flex:1">Save as a Book list on Home</span>${ic('chevR', 16, 2.6)}</div>`));
  const pp = pagedSpan(items, x => x.span, U, H2 - (x4 ? 196 : 206), 'fsheet');
  const n = c.n === 'cfg' ? fApply(fBase(c), f).length : fCount(c);
  return `<div class="scrim" data-act="fdone"></div><div class="card fsheet" style="left:50%;top:50%;transform:translate(-50%,-50%);width:${W2}px;height:${H2}px;padding:0;border-radius:18px;display:flex;flex-direction:column">
    <div style="display:flex;align-items:center;gap:10px;padding:12px 10px 10px ${x4 ? 16 : 22}px;border-bottom:1px solid var(--g3)">${ic('filter', 22, 2.2)}<div style="flex:1;min-width:0"><div style="font-size:var(--fm);font-weight:800">Filter</div><div class="meta ell" style="font-size:var(--fc)">${esc(cx.name)}</div></div><div class="iconbtn flat" data-act="fdone" data-fk="f-close" title="Close and apply">${ic('x', 22, 2.4)}</div></div>
    <div style="flex:1;min-height:0;padding:0 ${x4 ? 16 : 22}px">${pp.slice.map(x => x.h).join('')}</div>
    ${pp.pages > 1 ? pageFoot(pp.p, pp.pages, 'fsheet') : ''}
    <div style="display:flex;gap:10px;padding:10px ${x4 ? 16 : 22}px 14px;border-top:1px solid var(--g3)"><div class="pill wh${fparts(f, c).length ? '' : ' dis'}" data-act="freset" data-fk="f-reset" style="flex:none;padding:0 18px">Reset</div><div class="pill" data-act="fdone" data-fk="f-apply" style="flex:1">${n === 0 ? 'No books match' : `Show ${fmtN(n)} book${n === 1 ? '' : 's'}`}</div></div></div>`;
}
