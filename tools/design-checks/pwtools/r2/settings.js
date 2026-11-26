// ---------- BookSync settings (on the X4 these are the device's own settings for the same items) ----------
const SETV = {wsync:true, ssync:true, prog:0, pause:true, slimit:1, folder:0, keep:true, cat:1, covers:true,
  font2:0, margP:0, spaceP:0, contP:0, sbar:true, sbf:0, sbs:1, endsheet:true, home:0, slcov:0, slex:1, sltext:0, slbat:true, slplace:0,
  wifi:2, idle:1, chan:0};
const CAT_OPTS = ['100 MB','250 MB','500 MB','1 GB','2 GB','5 GB','10 GB','Unlimited'];
// Presets: two per setting plus Custom. Levels index into MARG / SPACE / contrast.
const MARG_P = [[0, 2], [0, 1], [1, 2]], SPACE_P = [[1, 2], [0, 1], [0, 2]], CONT_P = [[1, 2], [0, 1], [0, 2]];
const MARG_N = ['Narrow','Medium','Wide'], SPACE_N = ['Tight','Normal','Loose'], CONT_N = ['Soft','Normal','Dark'];
const pairName = (P, N) => P.map(([a, b]) => N[a] + ' and ' + N[b]);
const FONT_BOOK = {n:"Book's own", f:"Charter,'Bitstream Charter','Iowan Old Style',Georgia,serif"};
const FONT_CUSTOM = {n:'Custom', f:"Baskerville,'Baskerville Old Face','Hoefler Text',Georgia,serif"};
const fontOf = i => i === 0 ? FONT_BOOK : i === 1 ? FONTS[SETV.font2] : FONT_CUSTOM;
const CUSTOM = {font:'Baskerville, weight +1', marg:{m8c:46, x4:26}, space:1.42, cont:'Dark, +0.2 gamma'};
function effMarg(){ const rs = S.rs; return rs.margins === 2 ? CUSTOM.marg[dk()] : MARG[dk()][MARG_P[SETV.margP][rs.margins]]; }
function effSpace(){ const rs = S.rs; return rs.spacing === 2 ? CUSTOM.space : SPACE[SPACE_P[SETV.spaceP][rs.spacing]]; }
function effCont(){ const rs = S.rs; return rs.contrast === 2 ? 2 : CONT_P[SETV.contP][rs.contrast]; }
function presetNames(k){ if (k === 'margins') return [...MARG_P[SETV.margP].map(i => MARG_N[i]), 'Custom']; if (k === 'spacing') return [...SPACE_P[SETV.spaceP].map(i => SPACE_N[i]), 'Custom']; if (k === 'contrast') return [...CONT_P[SETV.contP].map(i => CONT_N[i]), 'Custom']; return [fontOf(0).n, fontOf(1).n, 'Custom']; }

// Row kinds: cyc (Select/tap steps through the options), tog, act (does something), nav, info (read-only).
function SETTINGS(){
  const x4 = dk() === 'x4'; const and = !x4;
  const R = (k, l, kind, o = {}) => ({k, l, kind, ...o});
  return [
    {id:'account', n:'Account & server', i:'user', sum:() => S.offline ? 'Offline · books.example.net' : 'Connected · books.example.net', rows:[
      R('st', 'Connection', 'info', {v:() => S.offline ? 'Offline' : 'Connected'}),
      R('srv', 'Server', 'info', {v:() => 'books.example.net'}),
      R('usr', 'Signed in as', 'info', {v:() => 'reader'}),
      R('resign', 'Sign in again…', 'act', {act:'modal:signin', sub:'If your password changed or sync says you are signed out'}),
      R('out', 'Sign out', 'act', {act:'toast:Sign out asks to confirm in the real build', sub:'Keeps your downloaded books'})]},
    {id:'sync', n:'Sync', i:'sync', sum:() => S.offline ? 'Waiting for Wi-Fi' : 'Synced 12 min ago', rows:[
      R('now', 'Sync now', 'act', {act:'sync', sub:() => S.offline ? 'Offline · will sync when Wi-Fi is back' : 'Last sync 12 min ago · 3 new books, 2 progress updates'}),
      R('ssync', 'Sync when the reader sleeps', 'tog'),
      R('wsync', 'Sync when it wakes', 'tog'),
      R('prog', 'Send reading progress', 'cyc', {opts:['Each chapter','Every 10 pages','Every page']}),
      R('pause', 'Pause sync while reading', 'tog', {sub:'Saves battery; catches up when you close the book'}),
      R('slimit', 'Sleep sync time limit', 'cyc', {opts:['30 s','60 s','2 min','5 min'], sub:'Stops a sleep sync that runs too long'})]},
    {id:'library', n:'Library & downloads', i:'download', sum:() => `${CAT_OPTS[SETV.cat]} catalog · ${['/Books','/BookSync','/Download'][SETV.folder]}`, rows:[
      R('folder', 'Download folder', 'cyc', {opts:x4 ? ['/Books','/BookSync'] : ['/Books','/BookSync','/Download']}),
      R('keep', 'Keep downloaded copies current', 'tog', {sub:'Re-download a book when the server copy changes'}),
      R('cat', 'Offline catalog storage', 'cyc', {opts:CAT_OPTS, sub:'Covers and details for browsing without Wi-Fi'}),
      R('covers', 'Mirror covers to this device', 'tog'),
      R('refresh', 'Full refresh', 'act', {act:'fullrefresh', sub:() => S.refresh != null ? `Refreshing… ${Math.round(S.refresh)}% · ${fmtN(Math.round(LIB.total * S.refresh / 100))} of ${fmtN(LIB.total)} books` : 'Re-reads the whole library from the server · about 2 min', bar:() => S.refresh})]},
    {id:'reading', n:'Reading', i:'type', sum:() => `${fontOf(1).n} · ${pairName(MARG_P, MARG_N)[SETV.margP].toLowerCase()} margins`, rows:[
      R('fontp', 'Font choices', 'info', {v:() => `Book's own · ${FONTS[SETV.font2].n} · Custom`, sub:'The three choices in the reading panel'}),
      R('font2', 'Your font', 'cyc', {opts:FONTS.map(f => f.n), sub:"Shown beside the book's own (embedded) font"}),
      R('margP', 'Margin choices', 'cyc', {opts:pairName(MARG_P, MARG_N)}),
      R('spaceP', 'Line spacing choices', 'cyc', {opts:pairName(SPACE_P, SPACE_N)}),
      R('contP', 'Contrast choices', 'cyc', {opts:pairName(CONT_P, CONT_N)}),
      R('custom', 'Custom', 'info', {v:() => 'From KOReader', sub:`${CUSTOM.font} · margins ${CUSTOM.marg[dk()]} px · spacing ${CUSTOM.space} · ${CUSTOM.cont}`}),
      R('sbar', 'Status bar', 'tog'),
      R('sbf', 'Status bar shows', 'cyc', {opts:['Chapter, pages left, page','Clock, battery, progress','Chapter and progress %','Everything']}),
      R('sbs', 'Status bar size', 'cyc', {opts:['Small','Medium','Large']}),
      R('endsheet', 'End of book sheet', 'tog', {sub:'Rating, stats and the next book when you finish'})]},
    {id:'home', n:'Home', i:'home', sum:() => `${['BookSync','BookOrbit'][SETV.home]} Home · ${S.layouts[dk()].length} pages`, rows:[
      R('edit', 'Edit layout', 'act', {act:'settings:edit', sub:'Move, resize, add and remove widgets'}),
      R('reset', 'Reset layout', 'act', {act:'editReset', sub:'Back to the default pages'}),
      R('home', 'Home screen', 'cyc', {opts:['BookSync','BookOrbit'], sub:'What you see when you leave a book'}),
      R('pages', 'Page names', 'info', {v:() => S.layouts[dk()].map(p => p.name).join(' · '), sub:'Rename a page in Edit layout'})]},
    {id:'sleep', n:'Sleep screen', i:'moon', sum:() => ['Current book','Recommended','From a list','Whole library'][SETV.slcov] + ' cover', rows:[
      R('slcov', 'Cover shown', 'cyc', {opts:['Current book','Recommended','From a list','Whole library']}),
      R('slex', 'Never show', 'cyc', {opts:['Nothing excluded','Books tagged “private”','Adult (18+) books']}),
      R('sltext', 'Text', 'cyc', {opts:['Title and author','Title, author and progress','No text']}),
      R('slbat', 'Battery level', 'tog'),
      R('slplace', 'Text placement', 'cyc', {opts:['Bottom band','Top band','Corner']})]},
    {id:'power', n:'Wi-Fi & power', i:'wifi', sum:() => ['Always on','Off while reading','Just in time'][SETV.wifi] + ` · ≈ ${fmtDH(BAT_LEFT())} left`, rows:[
      R('wifi', 'Wi-Fi', 'cyc', {opts:['Always on','Off while reading','Just in time'], sub:'Just in time turns it on only to sync'}),
      R('idle', 'Sleep after', 'cyc', {opts:['5 min idle','10 min idle','15 min idle','30 min idle','Never']}),
      R('bat', 'Battery', 'nav', {act:'nav:battery', v:() => `${BAT.level}% · ≈ ${fmtDH(BAT_LEFT())}`})]},
    {id:'updates', n:'Updates', i:'refresh', sum:() => `${['Stable','Preview'][SETV.chan]} · BookSync 0.12.0`, rows:[
      R('chan', 'Update channel', 'cyc', {opts:['Stable','Preview']}),
      R('check', 'Check now', 'act', {act:'toast:BookSync 0.12.0 is the latest stable version', sub:'Checked yesterday'}),
      R('ver', 'Installed', 'info', {v:() => 'BookSync 0.12.0'}),
      R('new', "What's new", 'act', {act:'modal:whatsnew'})]},
    {id:'about', n:'About & help', i:'info', sum:() => 'BookSync 0.12.0', rows:[
      R('ver2', 'Version', 'info', {v:() => 'BookSync 0.12.0'}),
      R('dev', 'This reader', 'info', {v:() => ({m8c:'M8C', x4pro:'Xteink X4 Pro', x4c:'Xteink X4'})[S.dev]}),
      R('help', 'Help and guides', 'act', {act:'toast:Opens the BookSync guide'}),
      ...(and ? [R('comp', 'Advanced: open companion app', 'act', {act:'toast:Opens the companion: Home app, battery optimisation, VPN, first-time setup', sub:'Home app, battery optimisation, VPN / Tailscale, first-time setup'})] : [])]},
  ];
}
function setValue(r){ if (r.kind === 'tog') return SETV[r.k]; if (r.kind === 'cyc') return r.opts[SETV[r.k]]; if (r.v) return r.v(); return ''; }
function setRow(r, h){
  const x4 = dk() === 'x4'; const sub = typeof r.sub === 'function' ? r.sub() : r.sub; const bar = r.bar && r.bar();
  const act = r.kind === 'cyc' ? `setc:${r.k}:${r.opts.length}` : r.kind === 'tog' ? `sett:${r.k}` : r.act;
  const right = r.kind === 'tog' ? `<div class="sw${SETV[r.k] ? ' on' : ''}"><i></i></div>`
    : r.kind === 'cyc' ? `<span style="display:flex;align-items:center;gap:4px;font-size:var(--fs);font-weight:700;text-align:right;max-width:52%">${esc(setValue(r))}${ic('chevR', 16, 2.6)}</span>`
    : r.kind === 'info' ? `<span class="meta" style="font-size:var(--fs);text-align:right;max-width:55%">${esc(setValue(r))}</span>`
    : `<span style="display:flex;align-items:center;gap:4px;font-size:var(--fs);font-weight:700">${r.v ? esc(r.v()) : ''}${ic('chevR', 16, 2.6)}</span>`;
  return `<div class="lrow" ${act ? `data-act="${act}" data-fk="set-${r.k}"` : ''} style="min-height:${h}px;border-bottom:1px solid var(--g3);gap:14px">
    <div style="flex:1;min-width:0;padding:6px 0"><div style="font-size:var(--fb);font-weight:${r.kind === 'act' ? 700 : 600}">${esc(r.l)}</div>${sub ? `<div class="meta" style="font-size:var(--fc);margin-top:2px;line-height:1.3">${esc(sub)}</div>` : ''}
    ${bar != null ? `<div class="bar1" style="height:6px;margin-top:6px"><b style="width:${bar}%"></b></div>` : ''}</div>${right}</div>`;
}
function settingsView(c, g){
  const x4 = dk() === 'x4'; const P = g.padx + 6; const groups = SETTINGS();
  if (c.grp == null){
    const rowH = Math.floor((g.H - 64 - 30) / groups.length);
    return shdr('BookSync settings', x4 ? 'Reader settings' : 'Everything day to day, without the companion') + `<div style="padding:4px ${P}px">${groups.map(gr => `<div class="lrow" data-act="setg:${gr.id}" data-fk="sg-${gr.id}" style="height:${rowH}px;border-bottom:1px solid var(--g3);gap:14px">
      <div class="well" style="width:40px;height:40px;border-radius:11px;background:var(--g4);display:grid;place-items:center;flex:none">${ic(gr.i, 22, 2)}</div>
      <div style="flex:1;min-width:0"><div style="font-size:var(--fb);font-weight:700">${gr.n}</div><div class="meta ell" style="font-size:var(--fc);margin-top:2px">${esc(gr.sum())}</div></div>${ic('chevR', 18, 2.6)}</div>`).join('')}</div>`;
  }
  const gr = groups.find(x => x.id === c.grp); const rowH = x4 ? 62 : 72; const pp = paged(gr.rows, rowH + 8, g.H - 64 - 30 - 64, 'set_' + gr.id);
  return shdr(gr.n, 'BookSync settings') + `<div style="padding:4px ${P}px">${pp.slice.map(r => setRow(r, rowH)).join('')}</div><div style="position:absolute;left:0;right:0;bottom:8px">${pagerRow(pp, 'set_' + gr.id)}</div>`;
}
