#!/usr/bin/env bash
# check-version.sh <openchamber-version> <opencode-version>
# Exits 0 when the OpenCode version satisfies the OpenChamber package's
# engines.opencode floor and is a 2.x release. Used by CI before publishing.
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: check-version.sh <openchamber-version> <opencode-version>" >&2
  exit 2
fi

OPENCHAMBER_VERSION="$1" OPENCODE_VERSION="$2" python3 - <<'PY'
import json, os, re, sys, urllib.request

version = os.environ["OPENCHAMBER_VERSION"]
candidate = os.environ["OPENCODE_VERSION"]

with urllib.request.urlopen(f"https://registry.npmjs.org/@openchamber/web/{version}", timeout=30) as r:
    engine = json.load(r).get("engines", {}).get("opencode", "")

match = re.search(r"(\d+)\.(\d+)\.(\d+)", engine)
if not match:
    print(f"{version} has no parsable engines.opencode", file=sys.stderr)
    sys.exit(2)

floor = tuple(int(p) for p in match.groups())

if not re.fullmatch(r"2\.\d+\.\d+", candidate):
    print(f"{candidate} is not a 2.x release", file=sys.stderr)
    sys.exit(2)

if tuple(int(p) for p in candidate.split(".")) < floor:
    print(f"{candidate} is below engines.opencode {engine}", file=sys.stderr)
    sys.exit(2)

print(candidate)
PY
