#!/usr/bin/env bash
# scripts/test/prune-safety-test.sh — a pruned image must still load its deps.
# Runs a require() of every top-level dependency the app's entry imports.
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
image="${1:-openchamber-selfhost:dev}"

docker run --rm --entrypoint node "$image" -e "
const { createRequire } = require('node:module');
const req = createRequire('/app/node_modules/@openchamber/web/build/bin/cli.js');
const names = ['yaml', 'zod', 'express', 'luxon', 'ws', 'node-pty', 'openai', 'simple-git', 'jsonc-parser', 'cron-parser', 'compression', 'jose', '@octokit/rest', '@gitbeaker/rest', '@vscode/ripgrep', 'sherpa-onnx-node'];
const bad = [];
for (const name of names) {
  try { req(name); } catch (error) { bad.push(name + ': ' + error.message.split('\n')[0]); }
}
if (bad.length) { console.error(bad.join('\n')); process.exit(1); }
console.log('prune-safe ok');
"
