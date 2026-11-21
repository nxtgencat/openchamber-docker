#!/usr/bin/env bash
# scripts/test/resolve-versions-test.sh
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
out="$("$here/scripts/resolve-versions.sh" 2.7.3)"
echo "$out"
grep -q '^OPENCHAMBER_VERSION=2\.7\.3$' <<<"$out" || { echo "FAIL openchamber pin"; exit 1; }
oc="$(sed -n 's/^OPENCODE_VERSION=//p' <<<"$out")"
[[ "$oc" =~ ^2\.[0-9]+\.[0-9]+$ ]] || { echo "FAIL opencode not 2.x: $oc"; exit 1; }
# must satisfy the package's own engine floor
python3 - "$oc" <<'PY'
import sys
v = tuple(int(p) for p in sys.argv[1].split('.'))
assert v >= (2, 2, 4), f"below engine floor: {v}"
PY
echo "resolve ok"
