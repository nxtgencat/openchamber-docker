#!/usr/bin/env bash
# scripts/test/prune-safety-test.sh [image]
# A pruned image must still load every dependency the app's entry imports.
#
# Without an argument this is a no-op when no image has been built yet, so it
# can sit in the same loop as the static tests. With an explicit image name it
# is a hard requirement: a missing image is a failure, not a skip.
set -euo pipefail

explicit=false
image="openchamber-selfhost:dev"
if [ "$#" -ge 1 ]; then
  image="$1"
  explicit=true
fi

if ! docker image inspect "$image" >/dev/null 2>&1; then
  if [ "$explicit" = true ]; then
    echo "FAIL: image '$image' not found" >&2
    exit 1
  fi
  echo "prune-safety skipped (no $image built yet; run it after a build)"
  exit 0
fi

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
