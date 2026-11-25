// The BookOrbit routes BookSync calls, read from the code (never a hand-kept list): every string
// literal, or concatenation of literals and expressions, that starts with a server route prefix in
// the KOReader plugin's Lua and the companion's Kotlin, plus the stock BookOrbit plugin BookSync runs
// on. An expression becomes a `:p` segment; a constant that holds a literal is inlined.
// A line with the comment `orbify:not-a-route` is skipped (a local path that looks like a route).
import fs from 'node:fs';
import path from 'node:path';

/** Where BookSync's server calls live, relative to the repo root. */
export const SOURCES = [
  { dir: 'android/koreader/orbit.koplugin', ext: '.lua', lang: 'lua' },
  { dir: 'android/companion', ext: '.kt', lang: 'kotlin', under: '/src/main/' },
  // The stock plugin makes the server calls the BookSync plugin hooks (docs/server-contract.md).
  { dir: 'upstream/bookorbit/koreader-plugin/bookorbit.koplugin', ext: '.lua', lang: 'lua', upstream: true },
];

// A route starts with one of these (an optional /api/v1 global prefix in front).
const ROUTE_START = /\/(?:api\/v1\/)?(?:koreader|opds)(?=[/?#\0]|$)/g;
const METHODS = new Set(['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD', 'OPTIONS']);
const IGNORE = 'orbify:not-a-route';

// ---- lexer --------------------------------------------------------------------------------------
// Tokens: {t:'str', parts:[string | {expr:name|null}], line} | {t:'id', v, line} | {t:'op', v, line}

function lex(src, lang) {
  const toks = [];
  const ignored = new Set();
  let i = 0;
  let line = 1;
  const n = src.length;
  const comment = (text) => {
    if (text.includes(IGNORE)) ignored.add(line);
  };
  while (i < n) {
    const c = src[i];
    if (c === '\n') { line++; i++; continue; }
    if (c === ' ' || c === '\t' || c === '\r') { i++; continue; }
    // comments
    if (lang === 'lua' && src.startsWith('--', i)) {
      const lb = src.slice(i + 2).match(/^\[(=*)\[/);
      if (lb) {
        const close = `]${lb[1]}]`;
        const end = src.indexOf(close, i);
        const stop = end < 0 ? n : end + close.length;
        const text = src.slice(i, stop);
        comment(text);
        line += (text.match(/\n/g) || []).length;
        i = stop;
      } else {
        const end = src.indexOf('\n', i);
        const stop = end < 0 ? n : end;
        comment(src.slice(i, stop));
        i = stop;
      }
      continue;
    }
    if (lang === 'kotlin' && src.startsWith('//', i)) {
      const end = src.indexOf('\n', i);
      const stop = end < 0 ? n : end;
      comment(src.slice(i, stop));
      i = stop;
      continue;
    }
    if (lang === 'kotlin' && src.startsWith('/*', i)) {
      const end = src.indexOf('*/', i + 2);
      const stop = end < 0 ? n : end + 2;
      const text = src.slice(i, stop);
      comment(text);
      line += (text.match(/\n/g) || []).length;
      i = stop;
      continue;
    }
    // Lua long strings: never routes, skipped whole
    if (lang === 'lua' && c === '[') {
      const lb = src.slice(i).match(/^\[(=*)\[/);
      if (lb) {
        const close = `]${lb[1]}]`;
        const end = src.indexOf(close, i);
        const stop = end < 0 ? n : end + close.length;
        line += (src.slice(i, stop).match(/\n/g) || []).length;
        toks.push({ t: 'str', parts: [''], line, long: true });
        i = stop;
        continue;
      }
    }
    if (c === '"' || (c === "'" && lang === 'lua')) {
      const startLine = line;
      const raw = lang === 'kotlin' && src.startsWith('"""', i);
      const parts = [];
      let buf = '';
      i += raw ? 3 : 1;
      while (i < n) {
        if (raw ? src.startsWith('"""', i) : src[i] === c) { i += raw ? 3 : 1; break; }
        if (!raw && src[i] === '\n') break; // unterminated: stop at the line end
        if (src[i] === '\n') line++;
        if (src[i] === '\\' && !raw) {
          const e = src[i + 1];
          buf += e === 'n' ? '\n' : e === 't' ? '\t' : e;
          i += 2;
          continue;
        }
        if (lang === 'kotlin' && src[i] === '$') {
          if (src[i + 1] === '{') {
            let depth = 1;
            let j = i + 2;
            while (j < n && depth > 0) {
              if (src[j] === '{') depth++;
              else if (src[j] === '}') depth--;
              j++;
            }
            const inner = src.slice(i + 2, j - 1).trim();
            parts.push(buf, { expr: /^[A-Za-z_][\w.]*$/.test(inner) ? inner : null });
            buf = '';
            i = j;
            continue;
          }
          const m = src.slice(i + 1).match(/^[A-Za-z_]\w*/);
          if (m) {
            parts.push(buf, { expr: m[0] });
            buf = '';
            i += 1 + m[0].length;
            continue;
          }
        }
        buf += src[i];
        i++;
      }
      parts.push(buf);
      toks.push({ t: 'str', parts, line: startLine });
      continue;
    }
    if (lang === 'kotlin' && c === "'") { // char literal
      const m = src.slice(i).match(/^'(?:\\.|[^'\\])*'/);
      i += m ? m[0].length : 1;
      continue;
    }
    const id = src.slice(i).match(/^[A-Za-z_]\w*/);
    if (id) { toks.push({ t: 'id', v: id[0], line }); i += id[0].length; continue; }
    const num = src.slice(i).match(/^\d[\w.]*/);
    if (num) { toks.push({ t: 'num', v: num[0], line }); i += num[0].length; continue; }
    const op = src.slice(i).match(/^(\.\.\.|\.\.|::|==|~=|!=|<=|>=|->|\?\.|!!|[-+*/%^#&|~<>=(){}\[\];:,.?!@$])/);
    if (op) { toks.push({ t: 'op', v: op[0], line }); i += op[0].length; continue; }
    i++;
  }
  return { toks, ignored };
}

// ---- constants and concatenation chains ---------------------------------------------------------

function pureLiteral(tok) {
  return tok && tok.t === 'str' && tok.parts.length === 1 && !tok.long ? tok.parts[0] : null;
}

/** Name -> literal, for `local X = "…"` / `X = "…"` (Lua) and `val X = "…"` (Kotlin). */
function constants(files) {
  const map = new Map();
  for (const f of files) {
    const { toks, lang } = f;
    const concat = lang === 'lua' ? '..' : '+';
    for (let k = 0; k + 2 < toks.length; k++) {
      let name = null;
      let rhs = -1;
      if (toks[k].t === 'id' && toks[k + 1].t === 'op' && toks[k + 1].v === '=') {
        name = toks[k].v; rhs = k + 2;
      } else if (lang === 'kotlin' && toks[k].t === 'id' && toks[k + 1].t === 'op' && toks[k + 1].v === ':' &&
                 toks[k + 2].t === 'id' && toks[k + 2].v === 'String' && toks[k + 3]?.v === '=') {
        name = toks[k].v; rhs = k + 4;
      }
      if (name === null) continue;
      const lit = pureLiteral(toks[rhs]);
      if (lit === null) continue;
      const next = toks[rhs + 1];
      if (next && next.t === 'op' && next.v === concat) continue;
      // A name assigned two different literals is ambiguous: treat it as unknown.
      map.set(name, map.has(name) && map.get(name) !== lit ? null : lit);
      toks[rhs].constDef = name;
    }
  }
  return map;
}

const OPEN = { '(': ')', '[': ']', '{': '}' };

/** Skips one operand (a name, call chain, literal or parenthesised expression); returns its end. */
function operandEnd(toks, k) {
  const tok = toks[k];
  if (!tok) return k;
  let j = k;
  if (tok.t === 'op' && OPEN[tok.v]) {
    j = skipGroup(toks, k);
  } else if (tok.t === 'op' && (tok.v === '-' || tok.v === '#' || tok.v === '!')) {
    return operandEnd(toks, k + 1);
  } else {
    j = k + 1;
  }
  // suffixes: .name :name ?.name (args) [index] !!
  for (;;) {
    const s = toks[j];
    if (!s || s.t !== 'op') break;
    if ((s.v === '.' || s.v === ':' || s.v === '?.' || s.v === '::') && toks[j + 1]?.t === 'id') { j += 2; continue; }
    if (s.v === '(' || s.v === '[') { j = skipGroup(toks, j); continue; }
    if (s.v === '!!') { j++; continue; }
    break;
  }
  // Lua call sugar: f"str" / f{...}
  return j;
}

function skipGroup(toks, k) {
  let depth = 0;
  for (let j = k; j < toks.length; j++) {
    const v = toks[j].t === 'op' ? toks[j].v : null;
    if (v && OPEN[v]) depth++;
    else if (v === ')' || v === ']' || v === '}') { depth--; if (depth === 0) return j + 1; }
  }
  return toks.length;
}

/** The literal text of a chain, with '\0' for each unknown expression. */
function chainText(toks, k, lang, consts, used) {
  const concat = lang === 'lua' ? '..' : '+';
  let text = '';
  const addStr = (tok) => {
    used.add(tok);
    for (const p of tok.parts) {
      if (typeof p === 'string') text += p;
      else text += resolve(p.expr, consts);
    }
  };
  // Leading names before the literal: `CATALOG .. "/books"`, `base + "/koreader/…"`.
  let s = k;
  for (;;) {
    if (!(toks[s - 1]?.t === 'op' && toks[s - 1].v === concat)) break;
    let b = s - 2;
    if (toks[b]?.t !== 'id') break;
    while (toks[b - 1]?.t === 'op' && toks[b - 1].v === '.' && toks[b - 2]?.t === 'id') b -= 2;
    if (toks[b - 1]?.t === 'op' && (toks[b - 1].v === '.' || toks[b - 1].v === ':' || toks[b - 1].v === concat)) break;
    s = b;
  }
  for (let b = s; b < k - 1;) {
    let e = b + 1;
    while (toks[e]?.t === 'op' && toks[e].v === '.') e += 2;
    text += resolve(toks.slice(b, e).filter((t) => t.t === 'id').map((t) => t.v).join('.'), consts);
    b = e + 1; // past the concat operator
  }
  let j = k;
  addStr(toks[j]);
  j++;
  while (toks[j] && toks[j].t === 'op' && toks[j].v === concat) {
    const start = j + 1;
    const end = operandEnd(toks, start);
    if (end === start + 1 && toks[start].t === 'str') {
      addStr(toks[start]);
    } else if (end === start + 1 && toks[start].t === 'id') {
      text += resolve(toks[start].v, consts);
    } else if (end > start + 1 && toks.slice(start, end).every((t) => t.t === 'id' || (t.t === 'op' && t.v === '.'))) {
      text += resolve(toks.slice(start, end).filter((t) => t.t === 'id').map((t) => t.v).join('.'), consts);
    } else {
      text += '\0';
    }
    j = end;
  }
  return text;
}

function resolve(expr, consts) {
  if (!expr) return '\0';
  const last = expr.split('.').pop();
  const v = consts.get(last);
  return typeof v === 'string' ? v : '\0';
}

/** Route pattern from a chain's text, or null: '/koreader/plugin/catalog/books/:p'. */
export function routeOf(text) {
  ROUTE_START.lastIndex = 0;
  let m;
  while ((m = ROUTE_START.exec(text))) {
    const before = text.slice(0, m.index);
    // At the start, after an expression (a base URL), or right after a URL's host.
    if (before === '' || before.endsWith('\0') || /^[a-z]+:\/\/[^/]*$/i.test(before)) {
      let p = text.slice(m.index).split(/[?#]/)[0];
      p = p.replace(/^\/api\/v1(?=\/)/, '');
      const segs = p.split('/').slice(1);
      if (segs.length && segs[segs.length - 1] === '') segs.pop();
      return '/' + segs.map((s) => (s.includes('\0') ? ':p' : s)).join('/');
    }
  }
  return null;
}

/** Every route call in one source file: [{method, path, file, line}]. */
export function extractFromSource(src, lang, file, consts = new Map()) {
  return extractFiles([{ src, lang, file }], consts);
}

function extractFiles(inputs, extraConsts = new Map()) {
  const files = inputs.map(({ src, lang, file }) => ({ ...lex(src, lang), lang, file }));
  const consts = new Map([...constants(files), ...extraConsts]);
  const out = [];
  for (const f of files) {
    const { toks, lang, ignored, file } = f;
    const used = new Set();
    for (let k = 0; k < toks.length; k++) {
      const tok = toks[k];
      if (tok.t !== 'str' || used.has(tok) || tok.long) continue;
      if (ignored.has(tok.line)) continue;
      const text = chainText(toks, k, lang, consts, used);
      const route = routeOf(text);
      if (!route) continue;
      // A constant holding a route prefix is inlined where it is used; only report it if it is
      // also a whole route (check.mjs decides that against the server).
      const prefixOnly = Boolean(tok.constDef);
      let method = '*';
      const a = toks[k - 1];
      const b = toks[k - 2];
      if (a && a.t === 'op' && a.v === ',' && pureLiteral(b) !== null && METHODS.has(pureLiteral(b))) method = pureLiteral(b);
      out.push({ method, path: route, file, line: tok.line, prefixOnly });
    }
  }
  return out;
}

function walk(dir, ext, under) {
  const out = [];
  if (!fs.existsSync(dir)) return out;
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) {
      if (e.name === 'build' || e.name === 'node_modules' || e.name.startsWith('.')) continue;
      out.push(...walk(p, ext, under));
    } else if (e.name.endsWith(ext) && (!under || p.split(path.sep).join('/').includes(under))) {
      out.push(p);
    }
  }
  return out;
}

/** BookSync's routes, read from the repo. Missing source dirs are reported in `missing`. */
export function extractRepo(root, sources = SOURCES) {
  const inputs = [];
  const missing = [];
  for (const s of sources) {
    const dir = path.join(root, s.dir);
    if (!fs.existsSync(dir)) { missing.push(s.dir); continue; }
    for (const f of walk(dir, s.ext, s.under).sort()) {
      inputs.push({ src: fs.readFileSync(f, 'utf8'), lang: s.lang, file: path.relative(root, f) });
    }
  }
  return { routes: extractFiles(inputs), missing };
}

/** Groups calls by method + path: [{method, path, sources:[file:line], prefixOnly}]. */
export function manifest(calls) {
  const byKey = new Map();
  for (const c of calls) {
    const key = `${c.method} ${c.path}`;
    const e = byKey.get(key) || { method: c.method, path: c.path, sources: [], prefixOnly: true };
    e.sources.push(`${c.file}:${c.line}`);
    e.prefixOnly = e.prefixOnly && c.prefixOnly;
    byKey.set(key, e);
  }
  return [...byKey.values()].sort((x, y) => (x.path + x.method).localeCompare(y.path + y.method));
}
