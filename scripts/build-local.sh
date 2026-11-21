#!/usr/bin/env bash
# build-local.sh [openchamber-version] [opencode-version]
# Builds and loads openchamber-selfhost:dev for the host arch, enforces size budget.
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"

BUDGET_BYTES=1250000000

if [ "$#" -ge 2 ]; then
  OPENCHAMBER_VERSION="$1"
  OPENCODE_VERSION="$2"
else
  eval "$(scripts/resolve-versions.sh "${1:-2.7.3}")"
fi

case "$(uname -m)" in
  x86_64) HOST_ARCH=amd64; PLATFORM=linux/amd64 ;;
  aarch64|arm64) HOST_ARCH=arm64; PLATFORM=linux/arm64 ;;
  *) echo "unsupported host arch: $(uname -m)" >&2; exit 2 ;;
esac

echo "Building OpenChamber ${OPENCHAMBER_VERSION} + OpenCode ${OPENCODE_VERSION} for ${PLATFORM}"

mkdir -p .cache dist/opencode
BIN="$(scripts/verify-artifacts.sh "$OPENCODE_VERSION" "$HOST_ARCH" ".cache/opencode-${HOST_ARCH}")"
echo "Verified OpenCode binary: ${BIN}"
install -m 0755 "$BIN" dist/opencode/opencode

docker buildx build \
  --platform "$PLATFORM" \
  --build-arg "OPENCHAMBER_VERSION=${OPENCHAMBER_VERSION}" \
  --build-arg "OPENCODE_VERSION=${OPENCODE_VERSION}" \
  --build-arg "TARGETARCH=${HOST_ARCH}" \
  -f docker/Dockerfile \
  --tag "openchamber-selfhost:dev" \
  --load \
  .

SIZE="$(docker image inspect openchamber-selfhost:dev --format '{{.Size}}')"
MB=$(( SIZE / 1000 / 1000 ))
echo "Image size: ${MB} MB (${SIZE} bytes)"
if [ "$SIZE" -gt "$BUDGET_BYTES" ]; then
  echo "FAIL: image exceeds budget of $((BUDGET_BYTES / 1000 / 1000)) MB" >&2
  exit 1
fi
echo "build-local ok"
