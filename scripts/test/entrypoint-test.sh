#!/usr/bin/env bash
# scripts/test/entrypoint-test.sh — exercises the entrypoint's contract without
# starting a server. The script is expected to fail after validation on a host
# that has no /app/node_modules, so the assertions read its output, not its exit.
set -uo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
s="$here/docker/entrypoint.sh"

# 1. refuses to start without a password
out="$(env -i PATH=/usr/bin:/bin HOME=/tmp bash "$s" 2>&1 || true)"
grep -q 'OPENCHAMBER_UI_PASSWORD is required' <<<"$out" || { echo "FAIL: no password guard"; echo "$out"; exit 1; }

# 2. a divergent OpenCode password is overridden, never honored
out="$(env -i PATH=/usr/bin:/bin HOME=/tmp \
  OPENCHAMBER_UI_PASSWORD=pw OPENCODE_SERVER_PASSWORD=other bash "$s" 2>&1 || true)"
grep -q 'ignoring OPENCODE_SERVER_PASSWORD' <<<"$out" || { echo "FAIL: divergence not reported"; echo "$out"; exit 1; }

# 3. the password guard runs before any filesystem work, so a container with an
#    unwritable mount still fails for the reason the operator can act on.
out="$(env -i PATH=/usr/bin:/bin HOME=/nonexistent-readonly bash "$s" 2>&1 || true)"
grep -q 'OPENCHAMBER_UI_PASSWORD is required' <<<"$out" || { echo "FAIL: guard order"; echo "$out"; exit 1; }

echo "entrypoint ok"
