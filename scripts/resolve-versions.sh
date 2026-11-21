#!/usr/bin/env bash
# resolve-versions.sh <openchamber-version>
# Prints OPENCHAMBER_VERSION=<x> and OPENCODE_VERSION=<y> on stdout.
# Exits 2 when no compatible OpenCode 2.x exists.
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: resolve-versions.sh <openchamber-version>" >&2
  exit 2
fi

OPENCHAMBER_VERSION="$1"

OPENCODE_VERSION="$(
  OPENCHAMBER_VERSION="$OPENCHAMBER_VERSION" python3 - <<'PY'
import json, os, re, sys, urllib.request

version = os.environ["OPENCHAMBER_VERSION"]


def get(url):
    with urllib.request.urlopen(url, timeout=30) as response:
        return json.load(response)


try:
    manifest = get(f"https://registry.npmjs.org/@openchamber/web/{version}")
except Exception as error:  # noqa: BLE001
    print(f"cannot read @openchamber/web@{version}: {error}", file=sys.stderr)
    raise SystemExit(2)

engine = manifest.get("engines", {}).get("opencode", "")
match = re.search(r"(\d+)\.(\d+)\.(\d+)", engine)
if not match:
    print(f"@openchamber/web@{version} has no parsable engines.opencode", file=sys.stderr)
    raise SystemExit(2)
floor = tuple(int(part) for part in match.groups())

registry = get("https://registry.npmjs.org/@opencode/cli")
versions = [v for v in registry.get("versions", {}) if re.fullmatch(r"2\.\d+\.\d+", v)]
usable = [v for v in versions if tuple(int(p) for p in v.split(".")) >= floor]
if not usable:
    print(f"no OpenCode 2.x satisfies engines.opencode={engine}", file=sys.stderr)
    raise SystemExit(2)

usable.sort(key=lambda v: tuple(int(p) for p in v.split(".")))
latest = registry.get("dist-tags", {}).get("latest", "")
print(latest if latest in usable else usable[-1])
PY
)"

if [ -z "$OPENCODE_VERSION" ]; then
  echo "could not resolve an OpenCode version" >&2
  exit 2
fi

echo "OPENCHAMBER_VERSION=${OPENCHAMBER_VERSION}"
echo "OPENCODE_VERSION=${OPENCODE_VERSION}"
