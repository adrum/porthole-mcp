'use strict';
// Copy the Swift harness (apple/) into native/ so the npm package carries it.
const fs = require('fs');
const path = require('path');

const repo = path.resolve(__dirname, '..', '..');
const out = path.resolve(__dirname, '..', 'native');
fs.rmSync(out, { recursive: true, force: true });
fs.mkdirSync(out, { recursive: true });
for (const entry of ['Sources', 'Package.swift']) {
  fs.cpSync(path.join(repo, 'apple', entry), path.join(out, entry), { recursive: true });
}
fs.copyFileSync(path.join(repo, 'LICENSE'), path.join(out, 'LICENSE'));
// The package's test target isn't shipped.
const pkg = path.join(out, 'Package.swift');
fs.writeFileSync(pkg, fs.readFileSync(pkg, 'utf8').replace(/\n\s*\.testTarget\([^\n]*\n/, '\n'));
console.log(`synced harness sources into ${path.relative(process.cwd(), out) || out}`);
