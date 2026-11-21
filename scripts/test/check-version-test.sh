#!/usr/bin/env bash
# scripts/test/check-version-test.sh — an override must satisfy the engine floor.
set -uo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"

# a version at the floor passes
if ! "$here/scripts/check-version.sh" 2.7.3 2.3.2 >/dev/null 2>&1; then
  echo "FAIL: 2.3.2 should satisfy 2.7.3's engine floor"; exit 1
fi

# below the floor fails
if "$here/scripts/check-version.sh" 2.7.3 2.0.0 >/dev/null 2>&1; then
  echo "FAIL: 2.0.0 should be rejected"; exit 1
fi

# not 2.x fails
if "$here/scripts/check-version.sh" 2.7.3 3.0.0 >/dev/null 2>&1; then
  echo "FAIL: 3.0.0 should be rejected"; exit 1
fi

# malformed fails
if "$here/scripts/check-version.sh" 2.7.3 2.3 >/dev/null 2>&1; then
  echo "FAIL: 2.3 should be rejected"; exit 1
fi

echo "check-version ok"
