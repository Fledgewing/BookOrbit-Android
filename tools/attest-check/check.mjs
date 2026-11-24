#!/usr/bin/env node
// Fails when the pinned BookOrbit server requires app attestation on a route Orbify calls, or
// installs the attestation guard globally. Only BookOrbit's official apps can pass attestation, so
// such a route breaks Orbify. See docs/server-contract.md "App attestation".
//
//   node tools/attest-check/check.mjs [--repo DIR] [--server DIR] [--list]
//     --repo    Orbify checkout (default: this one)
//     --server  BookOrbit server/src (default: <repo>/upstream/bookorbit/server/src, from tools/upstreams)
//     --list    print the routes Orbify calls (the manifest, read from the code) and where
import path from 'node:path';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';
import { extractRepo, manifest } from './routes.mjs';
import { readServer, check } from './server.mjs';

const args = process.argv.slice(2);
const opt = (name) => {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : undefined;
};
const repo = path.resolve(opt('--repo') || path.join(path.dirname(fileURLToPath(import.meta.url)), '../..'));
const server = path.resolve(opt('--server') || path.join(repo, 'upstream/bookorbit/server/src'));

if (!fs.existsSync(server)) {
  console.error(`attest-check: no BookOrbit server source at ${server}; run tools/upstreams sync bookorbit`);
  process.exit(2);
}
const { routes, missing } = extractRepo(repo);
if (missing.length) {
  console.error(`attest-check: missing source folders: ${missing.join(', ')} (run tools/upstreams sync bookorbit)`);
  process.exit(2);
}
const calls = manifest(routes);
if (!calls.length) {
  console.error('attest-check: found no BookOrbit route in Orbify\'s code; the extractor is broken');
  process.exit(2);
}
if (args.includes('--list')) {
  for (const c of calls) console.log(`${c.method.padEnd(6)} ${c.path}${c.prefixOnly ? '  (prefix constant)' : ''}\n         ${c.sources.join('\n         ')}`);
}

const srv = readServer(server);
const { errors, unmatched } = check(calls, srv);
for (const u of unmatched) {
  errors.push(`${u.method === '*' ? 'ANY' : u.method} ${u.path} (called from ${u.sources.join(', ')}) matches no route on the pinned server: ` +
    'BookOrbit removed or moved it, or tools/attest-check/routes.mjs misread the call (mark a non-route literal with `orbify:not-a-route`).');
}
const attested = srv.routes.filter((r) => r.attest).length;
if (errors.length) {
  for (const e of errors) console.error(`ERROR: ${e}`);
  console.error(`attest-check: ${errors.length} problem(s); ${calls.length} Orbify routes checked against ${srv.routes.length} server routes (${attested} require attestation).`);
  process.exit(1);
}
console.log(`attest-check: ok. ${calls.length} Orbify routes, none requires app attestation; ` +
  `${srv.routes.length} server routes read, ${attested} require it, no global attestation guard.`);
