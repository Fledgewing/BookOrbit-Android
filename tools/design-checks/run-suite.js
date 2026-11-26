// Run the reviewed probes and turn their diagnostic failure output into a gate.
const {OUT} = require('./runtime.js');
const {join} = require('node:path');
const {spawnSync} = require('node:child_process');
const {writeFileSync} = require('node:fs');
const checks = [
  'pwtools/verify.js', 'pwtools/sweep.js', 'pwtools/r2/move.js',
  'pwtools/r2/bl.js', 'pwtools/r2/flows.js', 'pwtools/r2/sync.js',
  'r3/flows3.js', 'r3/focus.js', 'critic-shots/measure.js',
  'critic-shots/classic.js', 'critic-shots/r2/m2.js',
  'critic-shots/r2/c2.js', 'critic-shots/r2/c3.js',
  'critic-shots/r2/c4.js', 'critic-shots/r2/fuzz.js',
  'critic-shots/r3/dark.js', 'critic-shots/r3/filt.js',
  'critic-shots/r3/filt2.js', 'critic-shots/r3/names.js',
];
let failures = 0;
for (const script of checks) {
  const result = spawnSync(process.execPath, [join(__dirname, script),
    process.argv[2], join(OUT, script.replaceAll('/', '-'))],
    {encoding:'utf8', timeout:180000, maxBuffer:8*1024*1024});
  const log = (result.stdout || '') + (result.stderr || '');
  writeFileSync(join(OUT, script.replaceAll('/', '-')+'.log'), log);
  const diagnostic = log.replace(/\bFAIL\s+0\b/g, '')
    .replace(/\b(?:ERR|ERRORS):?\s*(?:\[\s*\]|none)/g, '');
  const bad = result.status !== 0 || result.error ||
    /\b(?:FAIL|ERR|ERRORS|OVERFLOW)\b|NO FOCUS/.test(diagnostic) ||
    /\b(?:small:?\s+|overflow\s+|fails\s+)[1-9]\d*/i.test(diagnostic) ||
    /"bad"\s*:\s*\[(?!\])/.test(diagnostic);
  console.log(`${bad ? 'FAIL' : 'PASS'} ${script}`);
  if (bad) { failures++; console.error(log || result.error?.message); }
}
// The Pro touch-target audit uses the same probe with a second device class.
const pro = spawnSync(process.execPath, [join(__dirname,'critic-shots/r2/m2.js'),
  process.argv[2],join(OUT,'pro-targets')], {encoding:'utf8',timeout:180000,
  env:{...process.env,DEV:'x4pro'}});
const proLog=(pro.stdout||'')+(pro.stderr||'');
writeFileSync(join(OUT,'pro-targets.log'),proLog);
const proBad=pro.status!==0 || /\b(?:small|overflow)\s+[1-9]\d*/.test(proLog) ||
  !/ERR\s+\[\s*\]/.test(proLog);
console.log(`${proBad?'FAIL':'PASS'} X4 Pro touch-target audit`);
if(proBad) {failures++;console.error(proLog);}
process.exitCode = failures ? 1 : 0;
