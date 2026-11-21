#!/usr/bin/env bash
# scripts/test/context-test.sh — asserts the build context stays small.
# BuildKit reads .dockerignore from the context root, so it must live there.
set -euo pipefail
cd "$(dirname "$0")/../.."

fail=0
[ -f .dockerignore ] || { echo "MISSING: .dockerignore at context root"; exit 1; }
[ ! -f docker/.dockerignore ] || { echo "STALE: docker/.dockerignore is inert; remove it"; fail=1; }

for pattern in .git docs data workspaces node_modules .cache; do
  grep -qxF "$pattern" .dockerignore || { echo "MISSING: $pattern"; fail=1; }
done

# dist/ must stay in the context: the Dockerfile copies the OpenCode binary from it.
! grep -qxF 'dist' .dockerignore || { echo "FAIL: dist/ is excluded but required by the Dockerfile"; fail=1; }

[ "$fail" -eq 0 ] && echo "context ok"
exit "$fail"
