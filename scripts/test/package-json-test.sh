#!/usr/bin/env bash
# scripts/test/package-json-test.sh
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
python3 - "$here/docker/package.json" <<'PY'
import json, re, sys
d = json.load(open(sys.argv[1]))
assert d["private"] is True, "must be private"
deps = d["dependencies"]
assert list(deps) == ["@openchamber/web"], deps
assert re.fullmatch(r"\d+\.\d+\.\d+", deps["@openchamber/web"]), "pin must be exact"
assert set(d["trustedDependencies"]) == {"node-pty", "@vscode/ripgrep"}, d["trustedDependencies"]
print("package.json ok")
PY
