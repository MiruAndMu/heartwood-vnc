import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const read = (name) => fs.readFileSync(path.join(root, name), 'utf8');
const pkg = JSON.parse(read('package.json'));
const main = read('main.js');
const setup = read('mac-setup/heartwood-mac-setup.sh');
const readme = read('README.md');
const noVnc = JSON.parse(read('novnc/package.json'));

assert.equal(pkg.version, '1.0.0');
assert.equal(pkg.build.appId, 'com.miruandmu.heartwood-vnc');
assert.equal(pkg.build.portable.artifactName, 'HeartwoodVNC-${version}.exe');
assert.equal(pkg.devDependencies.electron, '43.4.1');
assert.equal(pkg.devDependencies['electron-builder'], '26.15.3');
assert.equal(pkg.devDependencies['@electron/asar'], '3.4.1');
assert.equal(noVnc.version, '1.5.0');
assert.ok(pkg.build.files.includes('LICENSE'));
assert.ok(pkg.build.files.includes('THIRD_PARTY.md'));
assert.ok(fs.statSync(path.join(root, 'build/icon.ico')).size > 10_000,
          'release icon is missing or implausibly small');

assert.match(setup, /websockify==0\.13\.0/);
assert.match(setup, /HEARTWOOD_VNC_PORT/);
assert.match(setup, /HEARTWOOD_AGENT_SUFFIX/);
assert.match(setup, /HEARTWOOD_HOME_OVERRIDE/);
assert.match(setup, /HEARTWOOD_AGENTS_OVERRIDE/);
assert.match(setup, /Port :\$port is already in use/);
assert.doesNotMatch(main, /passwordPlain/);
assert.match(main, /safeStorage\.isEncryptionAvailable\(\)/);
assert.match(main, /heartwood-debug\.log/);
assert.doesNotMatch(main, /lg-debug\.log/);

assert.match(readme, /bash ~\/Downloads\/heartwood-mac-setup\.sh/);
assert.match(readme, /bash mac-setup\/heartwood-mac-setup\.sh/);

console.log('release smoke: 22 assertions passed');
