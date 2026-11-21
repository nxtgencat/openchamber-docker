#!/usr/bin/env bash
# newest-published-tag.sh <image>
# Prints the highest \d+.\d+.\d+ tag currently published for the image, or nothing.
# Used to keep latest/major/minor from moving backwards. Works for GHCR without a
# local Docker login, using the registry token endpoint.
set -euo pipefail

IMAGE="${1:?usage: newest-published-tag.sh <registry>/<owner>/<name>}"

registry="${IMAGE%%/*}"
rest="${IMAGE#*/}"
owner="${rest%%/*}"
name="${rest#*/}"

case "$registry" in
  ghcr.io) token_url="https://ghcr.io/token?scope=repository:${owner}/${name}:pull&service=ghcr.io" ;;
  docker.io|index.docker.io)
    registry="registry-1.docker.io"
    token_url="https://auth.docker.io/token?service=registry.docker.io&scope=repository:${owner}/${name}:pull"
    ;;
  *) echo "unsupported registry: $registry" >&2; exit 2 ;;
esac

token="$(curl -fsSL "$token_url" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("token") or json.load(sys.stdin).get("access_token"))' 2>/dev/null || true)"
[ -n "$token" ] || exit 0

curl -fsSL -H "Authorization: Bearer $token" \
  "https://${registry}/v2/${owner}/${name}/tags/list?n=1000" 2>/dev/null \
| python3 -c '
import json, re, sys
try:
    tags = json.load(sys.stdin).get("tags") or []
except ValueError:
    sys.exit(0)
versions = [t for t in tags if re.fullmatch(r"\d+\.\d+\.\d+", t)]
if not versions:
    sys.exit(0)
versions.sort(key=lambda v: tuple(int(p) for p in v.split(".")))
print(versions[-1])
'
