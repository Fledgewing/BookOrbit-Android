// Revision-16 prototype checks. Install isolated Playwright/Chromium and set NODE_PATH.
const {resolve, join} = require('node:path');
const {tmpdir} = require('node:os');
const {mkdtempSync} = require('node:fs');
const {spawnSync} = require('node:child_process');
const result = spawnSync(process.execPath, [
  resolve(__dirname, '../design-checks/run-suite.js'),
  resolve(__dirname, '../../docs/design/booksync-home/prototype.html'),
  process.argv[2] || mkdtempSync(join(tmpdir(), 'booksync-design-')),
], {stdio:'inherit'});
if (result.error) throw result.error;
process.exitCode = result.status ?? 1;
