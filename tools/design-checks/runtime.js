const {resolve, sep} = require('node:path');
const {pathToFileURL} = require('node:url');
const {mkdirSync, existsSync} = require('node:fs');
if (!process.argv[2] || !process.argv[3]) throw new Error('Usage: node check.js <prototype.html> <output-directory> [check arguments]');
const prototype = resolve(process.argv[2]);
if (!existsSync(prototype)) throw new Error('Prototype file does not exist');
const OUT = resolve(process.argv[3]) + sep;
for (const sub of ['', 'shots', 'shots/focus', 'sweep', 'r2/s', 'critic-shots', 'critic-shots/r2', 'critic-shots/r3', 'critic-shots/r5']) mkdirSync(resolve(OUT, sub), {recursive:true});
module.exports = {prototypeURL:pathToFileURL(prototype).href, OUT};
