import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { listPackage, extractFile } from '@electron/asar';

const asarPath = process.argv[2] || path.join('dist', 'win-unpacked', 'resources', 'app.asar');
assert.ok(fs.existsSync(asarPath), `app.asar not found: ${asarPath}`);

const entries = new Set(listPackage(asarPath).map((entry) => entry.replaceAll('\\', '/')));
for (const required of [
  '/index.html',
  '/main.js',
  '/preload.js',
  '/LICENSE',
  '/THIRD_PARTY.md',
  '/novnc/LICENSE.txt',
  '/novnc/AUTHORS',
  '/novnc/core/rfb.js',
]) {
  assert.ok(entries.has(required), `packaged app is missing ${required}`);
}
for (const forbidden of ['/tests', '/mac-setup', '/.git', '/README.md', '/package-lock.json']) {
  assert.ok(![...entries].some((entry) => entry === forbidden || entry.startsWith(`${forbidden}/`)),
            `packaged app unexpectedly contains ${forbidden}`);
}

const packaged = JSON.parse(extractFile(asarPath, 'package.json').toString('utf8'));
assert.equal(packaged.name, 'heartwood-vnc');
assert.equal(packaged.version, '1.0.0');
assert.equal(packaged.main, 'main.js');

console.log(`asar inspection: ${entries.size} entries; required files present; release-only files excluded`);
