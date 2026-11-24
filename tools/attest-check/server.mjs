// Reads a BookOrbit server source tree (server/src) with the TypeScript parser: every route with
// the decorator that puts app attestation on it (handler or controller level), and every place the
// attestation guard is installed globally (GLOBAL_GUARDS, APP_GUARD, useGlobalGuards).
import fs from 'node:fs';
import path from 'node:path';
import ts from 'typescript';

const HTTP = { Get: 'GET', Post: 'POST', Put: 'PUT', Patch: 'PATCH', Delete: 'DELETE', Head: 'HEAD', Options: 'OPTIONS', Search: 'SEARCH', All: '*' };
const GUARD = 'AppAttestGuard';
const DECORATOR = 'RequireAppAttest';

function walk(dir) {
  const out = [];
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) {
      if (e.name === 'node_modules' || e.name === '__tests__' || e.name === 'test' || e.name.startsWith('.')) continue;
      out.push(...walk(p));
    } else if (/\.ts$/.test(e.name) && !/\.(test|spec|d)\.ts$/.test(e.name)) {
      out.push(p);
    }
  }
  return out.sort();
}

function parse(root) {
  return walk(root).map((f) => ({
    file: f,
    rel: path.relative(path.dirname(path.dirname(root)), f).split(path.sep).join('/'),
    sf: ts.createSourceFile(f, fs.readFileSync(f, 'utf8'), ts.ScriptTarget.Latest, true, ts.ScriptKind.TS),
  }));
}

function visit(node, fn) {
  fn(node);
  ts.forEachChild(node, (c) => visit(c, fn));
}

function mentions(node, names) {
  let hit = false;
  visit(node, (n) => {
    if (!hit && ts.isIdentifier(n) && names.has(n.text)) hit = true;
  });
  return hit;
}

function lineOf(sf, node) {
  return sf.getLineAndCharacterOfPosition(node.getStart(sf)).line + 1;
}

/**
 * Names that put the guard on a route: RequireAppAttest, plus any decorator factory built from it
 * (`export const Attested = () => applyDecorators(RequireAppAttest())`), to a fixed point. Guard
 * names: AppAttestGuard plus any class extending one.
 */
function attestNames(files) {
  const guards = new Set([GUARD]);
  const decorators = new Set([DECORATOR]);
  for (let changed = true; changed;) {
    changed = false;
    for (const { sf } of files) {
      for (const st of sf.statements) {
        if (ts.isClassDeclaration(st) && st.name && !guards.has(st.name.text)) {
          const ext = st.heritageClauses?.find((h) => h.token === ts.SyntaxKind.ExtendsKeyword);
          if (ext && mentions(ext, guards)) { guards.add(st.name.text); changed = true; }
        }
        const fns = [];
        if (ts.isFunctionDeclaration(st) && st.name && st.body) fns.push([st.name.text, st.body]);
        if (ts.isVariableStatement(st)) {
          for (const d of st.declarationList.declarations) {
            if (ts.isIdentifier(d.name) && d.initializer && (ts.isArrowFunction(d.initializer) || ts.isFunctionExpression(d.initializer))) {
              fns.push([d.name.text, d.initializer.body]);
            }
          }
        }
        for (const [name, body] of fns) {
          if (decorators.has(name)) continue;
          if (mentions(body, decorators) || mentions(body, guards)) { decorators.add(name); changed = true; }
        }
      }
    }
  }
  return { guards, decorators };
}

/** Top-level `const X = 'literal'` across the tree, for paths given by a constant. */
function stringConsts(files) {
  const map = new Map();
  for (const { sf } of files) {
    for (const st of sf.statements) {
      if (!ts.isVariableStatement(st)) continue;
      for (const d of st.declarationList.declarations) {
        let init = d.initializer;
        while (init && (ts.isAsExpression(init) || ts.isSatisfiesExpression?.(init) || ts.isParenthesizedExpression(init))) init = init.expression;
        if (ts.isIdentifier(d.name) && init && (ts.isStringLiteral(init) || ts.isNoSubstitutionTemplateLiteral(init))) {
          map.set(d.name.text, map.has(d.name.text) && map.get(d.name.text) !== init.text ? null : init.text);
        }
      }
    }
  }
  return map;
}

/** Path strings of a @Controller/@Get argument; null entries are paths we cannot read. */
function paths(arg, consts) {
  if (!arg) return [''];
  if (ts.isStringLiteral(arg) || ts.isNoSubstitutionTemplateLiteral(arg)) return [arg.text];
  if (ts.isArrayLiteralExpression(arg)) return arg.elements.flatMap((e) => paths(e, consts));
  if (ts.isObjectLiteralExpression(arg)) {
    const p = arg.properties.find((x) => ts.isPropertyAssignment(x) && x.name.getText() === 'path');
    return p ? paths(p.initializer, consts) : [''];
  }
  if (ts.isIdentifier(arg) || ts.isPropertyAccessExpression(arg)) {
    const name = ts.isIdentifier(arg) ? arg.text : arg.name.text;
    const v = consts.get(name);
    return [typeof v === 'string' ? v : null];
  }
  if (ts.isAsExpression(arg) || ts.isParenthesizedExpression(arg)) return paths(arg.expression, consts);
  return [null];
}

function decoratorsOf(node) {
  return (ts.canHaveDecorators(node) ? ts.getDecorators(node) : undefined) || [];
}

function callee(dec) {
  const e = dec.expression;
  if (ts.isCallExpression(e)) return { name: ts.isIdentifier(e.expression) ? e.expression.text : ts.isPropertyAccessExpression(e.expression) ? e.expression.name.text : null, args: e.arguments };
  if (ts.isIdentifier(e)) return { name: e.text, args: [] };
  return { name: null, args: [] };
}

/** The decorator on `node` that requires attestation, as {text, line}, or null. */
function attestOn(node, sf, names) {
  for (const dec of decoratorsOf(node)) {
    const { name, args } = callee(dec);
    const hit = (name && names.decorators.has(name)) || (name === 'UseGuards' && args.some((a) => mentions(a, names.guards)));
    if (hit) return { text: dec.getText(sf).replace(/\s+/g, ' '), line: lineOf(sf, dec), unsigned: /unsignedOutsideProduction\s*:\s*true/.test(dec.getText(sf)) };
  }
  return null;
}

function join(...parts) {
  return '/' + parts.filter((p) => p !== '').join('/').split('/').filter(Boolean).join('/');
}

/** Every controller route: {method, path (null if unreadable), file, line, attest|null}. */
export function serverRoutes(files, names, consts) {
  const routes = [];
  for (const { sf, rel } of files) {
    visit(sf, (cls) => {
      if (!ts.isClassDeclaration(cls)) return;
      const ctrl = decoratorsOf(cls).map(callee).find((c) => c.name === 'Controller');
      if (!ctrl) return;
      const prefixes = paths(ctrl.args[0], consts);
      const classAttest = attestOn(cls, sf, names);
      for (const m of cls.members) {
        if (!ts.isMethodDeclaration(m)) continue;
        const handlerAttest = attestOn(m, sf, names);
        for (const dec of decoratorsOf(m)) {
          const { name, args } = callee(dec);
          if (!name || !(name in HTTP)) continue;
          for (const prefix of prefixes) {
            for (const sub of paths(args[0], consts)) {
              routes.push({
                method: HTTP[name],
                path: prefix === null || sub === null ? null : join(prefix, sub),
                file: rel,
                line: lineOf(sf, dec),
                controller: cls.name?.text || '(anonymous)',
                attest: handlerAttest ? { ...handlerAttest, where: 'handler' } : classAttest ? { ...classAttest, where: 'controller' } : null,
              });
            }
          }
        }
      }
    });
  }
  return routes;
}

/** Places the guard runs on every route: [{file, line, what}]. */
export function globalGuards(files, names) {
  const found = [];
  for (const { sf, rel } of files) {
    visit(sf, (n) => {
      // export const GLOBAL_GUARDS = [ …, AppAttestGuard ]
      if (ts.isVariableDeclaration(n) && ts.isIdentifier(n.name) && n.name.text === 'GLOBAL_GUARDS' && n.initializer && mentions(n.initializer, names.guards)) {
        found.push({ file: rel, line: lineOf(sf, n), what: 'AppAttestGuard is in GLOBAL_GUARDS' });
      }
      // { provide: APP_GUARD, useClass: AppAttestGuard }
      if (ts.isObjectLiteralExpression(n)) {
        const provide = n.properties.find((p) => ts.isPropertyAssignment(p) && p.name.getText(sf) === 'provide');
        if (provide && ts.isPropertyAssignment(provide) && provide.initializer.getText(sf).endsWith('APP_GUARD') && mentions(n, names.guards)) {
          found.push({ file: rel, line: lineOf(sf, n), what: 'AppAttestGuard is provided as an APP_GUARD' });
        }
      }
      // app.useGlobalGuards(new AppAttestGuard(…))
      if (ts.isCallExpression(n) && ts.isPropertyAccessExpression(n.expression) && n.expression.name.text === 'useGlobalGuards' && n.arguments.some((a) => mentions(a, names.guards))) {
        found.push({ file: rel, line: lineOf(sf, n), what: 'AppAttestGuard is installed with useGlobalGuards' });
      }
    });
  }
  return found;
}

export function readServer(root) {
  const files = parse(root);
  const names = attestNames(files);
  const consts = stringConsts(files);
  return { routes: serverRoutes(files, names, consts), globals: globalGuards(files, names) };
}

// ---- matching -----------------------------------------------------------------------------------

/** Route path without the global prefix, as segments. */
function segs(p) {
  return p.replace(/^\/?api\/v1(?=\/|$)/, '').split('/').filter(Boolean);
}

const isParam = (s) => s.startsWith(':') || s === '*' || s.includes('(') || s.includes('*');
const isRest = (s) => s.includes('*') || s.includes('(');

/** Can a call to Orbify route `a` (':p' = any segment) reach server route `b`? */
export function pathsMatch(a, b) {
  const x = segs(a);
  const y = segs(b);
  for (let i = 0; i < Math.max(x.length, y.length); i++) {
    const p = x[i];
    const q = y[i];
    if (q !== undefined && isRest(q)) return true; // a wildcard tail takes the rest
    if (p === undefined || q === undefined) {
      return p === undefined && q !== undefined && q.endsWith('?') && i === y.length - 1; // optional last param
    }
    if (p === ':p' || isParam(q)) continue;
    if (p !== q) return false;
  }
  return true;
}

function methodsMatch(a, b) {
  return a === '*' || b === '*' || a === b;
}

/**
 * The check. `orbify` is the manifest ([{method, path, sources, prefixOnly}]); returns
 * {errors: [string], unmatched: [manifest entries with no server route]}.
 */
export function check(orbify, server) {
  const errors = [];
  for (const g of server.globals) {
    errors.push(`${g.file}:${g.line}: ${g.what}, so every route Orbify calls requires app attestation. ` +
      'Only BookOrbit\'s official apps can pass attestation; Orbify cannot.');
  }
  const unmatched = [];
  for (const r of orbify) {
    const hits = server.routes.filter((s) => methodsMatch(r.method, s.method) && (s.path === null ? s.attest : pathsMatch(r.path, s.path)));
    const reachable = hits.filter((s) => s.path !== null);
    if (!reachable.length && !r.prefixOnly) unmatched.push(r);
    for (const s of hits) {
      if (!s.attest) continue;
      const where = s.path === null ? `${s.controller} (path not readable, so it may be this route)` : `${s.method} ${s.path}`;
      const prod = s.attest.unsigned ? ' (unsignedOutsideProduction only lets unsigned requests through outside production; real servers still demand attestation)' : '';
      errors.push(`${r.method === '*' ? 'ANY' : r.method} ${r.path} requires app attestation: ${s.attest.text} on the ${s.attest.where} at ` +
        `${s.file}:${s.attest.line} (route ${where}, ${s.file}:${s.line})${prod}. ` +
        `Only BookOrbit's official apps can pass attestation, so Orbify cannot call this route. Orbify calls it from ${r.sources.join(', ')}.`);
    }
  }
  return { errors, unmatched };
}
