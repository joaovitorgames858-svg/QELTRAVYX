'use strict';
// No network, hooks, shell, native builds or external tar command.
const fs = require('fs');
const path = require('path');
const assert = require('assert');
const {spawnSync} = require('child_process');
const cli = process.argv[2];
function npm(args) {
  const result = spawnSync(process.execPath, [cli, ...args,
    '--offline', '--ignore-scripts', '--no-audit', '--no-fund',
    '--update-notifier=false', '--userconfig=/dev/null', '--globalconfig=/dev/null'], {
    cwd: process.cwd(), encoding: 'utf8', timeout: 25000, maxBuffer: 16384,
    env: {...process.env, HOME: process.cwd(), npm_config_cache: path.join(process.cwd(), 'cache')}
  });
  assert.ifError(result.error);
  assert.strictEqual(result.status, 0, result.stderr);
  return result.stdout;
}
console.log(npm(['--version']).trim());
fs.writeFileSync('package.json', JSON.stringify({name: 'qel-runtime-smoke', version: '1.0.0', private: true}));
console.log(npm(['install', './qel-js-demo-1.0.0.tgz']).trim());
assert.strictEqual(require(path.join(process.cwd(), 'node_modules/qel-js-demo'))(2, 3), 5);
assert.strictEqual(fs.existsSync('LIFECYCLE_RAN'), false);
assert.strictEqual(fs.existsSync('node_modules/qel-js-demo/LIFECYCLE_RAN'), false);
assert.ok(fs.existsSync('package-lock.json'));
console.log('QELTRAVYX NPM OK: offline tarball installed/imported; lifecycle blocked');
