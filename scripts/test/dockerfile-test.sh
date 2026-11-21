#!/usr/bin/env bash
# scripts/test/dockerfile-test.sh — static assertions on the Dockerfile
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
f="$here/docker/Dockerfile"

grep -q 'FROM node:24-trixie-slim' "$f" || { echo "FAIL base"; exit 1; }
grep -q 'tini' "$f" || { echo "FAIL tini"; exit 1; }
grep -q 'EXPOSE 3000 4096' "$f" || { echo "FAIL ports"; exit 1; }
grep -q 'STOPSIGNAL SIGTERM' "$f" || { echo "FAIL stopsignal"; exit 1; }
grep -q 'ENTRYPOINT \["/usr/local/bin/entrypoint.sh"\]' "$f" || { echo "FAIL entrypoint"; exit 1; }

# The health check must follow the runtime port, not hardcode 3000.
grep -q 'OPENCHAMBER_PORT:-3000' "$f" || { echo "FAIL healthcheck is not port-aware"; exit 1; }

# Pruning must happen in the artifacts stage, before node_modules is copied,
# or the untrimmed tree stays in the image as an extra layer.
grep -qE "find .*\.map' -delete" "$f" || { echo "FAIL sourcemap prune"; exit 1; }
awk '/^FROM artifacts AS runtime/{exit} /find \/app\/node_modules/{found=1} END{exit !found}' "$f" \
  || { echo "FAIL pruning is not in the artifacts stage"; exit 1; }

! grep -q 'node-gyp' "$f" || { echo "FAIL toolchain present"; exit 1; }

# No package upgrades: the image must follow the base image, not pin its own.
! grep -q 'apt-get upgrade' "$f" || { echo "FAIL apt-get upgrade pinning"; exit 1; }
! grep -q 'npm install -g npm@' "$f" || { echo "FAIL npm is pinned"; exit 1; }

echo "dockerfile ok"
