// node --test tools/attest-check/test/
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { extractFromSource, extractRepo, manifest, routeOf } from '../routes.mjs';
import { readServer, check, pathsMatch } from '../server.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../../..');
const fixture = (name) => path.join(here, 'fixtures', name, 'server/src');

// What BookSync's plugin calls on the catalog, as the extractor reports it.
const ORBIFY = manifest([
  { method: '*', path: '/koreader/plugin/catalog/books', file: 'ko/mirror.lua', line: 83 },
  { method: 'GET', path: '/koreader/plugin/catalog/books/:p', file: 'ko/sleepscreen.lua', line: 190 },
  { method: '*', path: '/koreader/plugin/catalog/books/:p/thumbnail', file: 'ko/cache.lua', line: 597 },
]);

const run = (name) => check(ORBIFY, readServer(fixture(name)));

test('a clean server passes', () => {
  const { errors, unmatched } = run('clean');
  assert.deepEqual(errors, []);
  assert.deepEqual(unmatched, []);
});

test('a guard on a route BookSync does not call passes', () => {
  assert.deepEqual(run('other-route').errors, []);
});

test('a handler-level guard fails with the route, file:line and why', () => {
  const { errors } = run('handler-guard');
  assert.equal(errors.length, 1);
  assert.match(errors[0], /\/koreader\/plugin\/catalog\/books\/:p\/thumbnail requires app attestation/);
  assert.match(errors[0], /@RequireAppAttest\(\) on the handler at server\/src\/modules\/koreader\/koreader-catalog.controller.ts:15/);
  assert.match(errors[0], /BookSync cannot call this route/);
  assert.match(errors[0], /ko\/cache.lua:597/);
});

test('a class-level guard fails every route of the controller', () => {
  const { errors } = run('class-guard');
  assert.equal(errors.length, 3);
  assert.ok(errors.every((e) => /on the controller at server\/src\/modules\/koreader\/koreader-catalog.controller.ts:6/.test(e)));
});

test('the unsignedOutsideProduction variant still fails', () => {
  const { errors } = run('unsigned');
  assert.equal(errors.length, 1);
  assert.match(errors[0], /RequireAppAttest\(\{ unsignedOutsideProduction: true \}\)/);
  assert.match(errors[0], /real servers still demand attestation/);
});

test('UseGuards(AppAttestGuard) and a decorator built on RequireAppAttest fail too', () => {
  assert.equal(run('use-guards').errors.length, 1);
  const w = run('wrapper').errors;
  assert.equal(w.length, 1);
  assert.match(w[0], /@AttestedRoute\(\)/);
});

test('AppAttestGuard in GLOBAL_GUARDS fails', () => {
  const { errors } = run('global-guard');
  assert.equal(errors.length, 1);
  assert.match(errors[0], /global-guards.ts:4: AppAttestGuard is in GLOBAL_GUARDS/);
});

test('AppAttestGuard as an APP_GUARD fails', () => {
  const { errors } = run('app-guard');
  assert.equal(errors.length, 1);
  assert.match(errors[0], /app.module.ts:9: AppAttestGuard is provided as an APP_GUARD/);
});

test('a manifest route the server lacks is reported', () => {
  const extra = manifest([{ method: 'GET', path: '/koreader/plugin/catalog/nope', file: 'x.lua', line: 1 }]);
  assert.equal(check(extra, readServer(fixture('clean'))).unmatched.length, 1);
});

test('path matching', () => {
  assert.ok(pathsMatch('/koreader/plugin/catalog/books/:p', '/koreader/plugin/catalog/books/:bookId'));
  assert.ok(pathsMatch('/koreader/plugin/catalog/sections/smart-scopes', '/koreader/plugin/catalog/sections/:section'));
  assert.ok(pathsMatch('/api/v1/opds/12/cover', '/opds/:bookId/cover'));
  assert.ok(pathsMatch('/koreader/x/y', '/koreader/(.*)'));
  assert.ok(!pathsMatch('/koreader/plugin/catalog/books', '/koreader/plugin/catalog/books/:bookId'));
  assert.ok(!pathsMatch('/koreader/plugin/catalog/books/:p', '/koreader/plugin/catalog/books/:bookId/thumbnail'));
});

// ---- the extractor ------------------------------------------------------------------------------

test('Lua: literals, concatenation, methods, constants, comments', () => {
  const src = [
    'local CATALOG = "/koreader/plugin/catalog"',
    '-- client:requestBlocking("GET", "/koreader/plugin/commented")',
    'local a = client:requestBlocking("PUT", "/koreader/plugin/catalog/books/" .. tostring(id) .. "/rating")',
    'local b = client:query(CATALOG .. "/sections/" .. section, { page = 1 })',
    'local c = server .. "/koreader/plugin/catalog/books?page=" .. n',
    'local d = "/koreader/settings/x" -- orbify:not-a-route',
    'local e = p:find("^/koreader/plugin/catalog/")',
  ].join('\n');
  const got = extractFromSource(src, 'lua', 'x.lua').filter((r) => !r.prefixOnly).map((r) => `${r.method} ${r.path} :${r.line}`);
  assert.deepEqual(got, [
    'PUT /koreader/plugin/catalog/books/:p/rating :3',
    '* /koreader/plugin/catalog/sections/:p :4',
    '* /koreader/plugin/catalog/books :5',
  ]);
});

test('Kotlin: templates, plus-concatenation, constants, comments', () => {
  const src = [
    'private const val CATALOG = "/koreader/plugin/catalog"',
    '/** GET "/koreader/plugin/commented" */',
    'fun thumb(id: Long) = get("$base${CATALOG}/books/${id}/thumbnail")',
    'fun detail(id: Long) = get(base + "/koreader/plugin/catalog/books/" + id)',
    'fun up() = request("POST", "/koreader/plugin/progress")',
    'val dir = File(root, "koreader/settings")',
  ].join('\n');
  const got = extractFromSource(src, 'kotlin', 'X.kt').filter((r) => !r.prefixOnly).map((r) => `${r.method} ${r.path} :${r.line}`);
  assert.deepEqual(got, [
    '* /koreader/plugin/catalog/books/:p/thumbnail :3',
    '* /koreader/plugin/catalog/books/:p :4',
    'POST /koreader/plugin/progress :5',
  ]);
});

test('routeOf only takes a route at the start, after a base URL or a host', () => {
  assert.equal(routeOf('/koreader/plugin/x'), '/koreader/plugin/x');
  assert.equal(routeOf('\0/api/v1/koreader/plugin/x'), '/koreader/plugin/x');
  assert.equal(routeOf('https://books.example/opds/1/cover'), '/opds/1/cover');
  assert.equal(routeOf('/sdcard/koreader/settings'), null);
});

test('the repo: BookSync\'s own calls are found', () => {
  const { routes } = extractRepo(repo, [{ dir: 'android/koreader/orbit.koplugin', ext: '.lua', lang: 'lua' }]);
  const paths = new Set(routes.map((r) => r.path));
  for (const p of ['/koreader/plugin/catalog/books', '/koreader/plugin/catalog/books/:p', '/koreader/plugin/catalog/books/:p/thumbnail']) {
    assert.ok(paths.has(p), `missing ${p}`);
  }
});

test('the repo against the pinned server (when tools/upstreams has fetched it)', (t) => {
  const server = path.join(repo, 'upstream/bookorbit/server/src');
  if (!fs.existsSync(server)) return t.skip('upstream/bookorbit not fetched');
  const { routes, missing } = extractRepo(repo);
  assert.deepEqual(missing, []);
  const { errors, unmatched } = check(manifest(routes), readServer(server));
  assert.deepEqual(errors, []);
  assert.deepEqual(unmatched.map((u) => u.path), []);
});
