#!/usr/bin/env bash
# scripts/test/verify-artifacts-test.sh — uses the real release, amd64 only
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
bin="$("$here/scripts/verify-artifacts.sh" 2.3.2 amd64 "$tmp")"
test -x "$bin" || { echo "FAIL not executable: $bin"; exit 1; }
"$bin" --version | grep -q '2\.3\.2' || { echo "FAIL wrong version"; exit 1; }
echo "artifacts ok"
