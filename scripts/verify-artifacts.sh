#!/usr/bin/env bash
# verify-artifacts.sh <opencode-version> <amd64|arm64> <dest-dir>
# Downloads the official OpenCode release for the target arch, verifies it
# against the release SHA256SUMS, extracts it, and prints the binary path.
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: verify-artifacts.sh <opencode-version> <amd64|arm64> <dest-dir>" >&2
  exit 2
fi

VERSION="$1"
ARCH="$2"
DEST="$3"

case "$ARCH" in
  amd64) RELEASE_ARCH="x64-baseline" ;;
  arm64) RELEASE_ARCH="arm64" ;;
  *)
    echo "unsupported arch: $ARCH (expected amd64 or arm64)" >&2
    exit 2
    ;;
esac

ASSET="opencode-linux-${RELEASE_ARCH}.tar.gz"
BASE_URL="https://github.com/anomalyco/opencode/releases/download/v${VERSION}"

mkdir -p "$DEST"
SUMS="$(mktemp)"
trap 'rm -f "$SUMS"' EXIT

curl -fsSL --retry 3 --retry-delay 2 "${BASE_URL}/SHA256SUMS" -o "$SUMS"
EXPECTED="$(sed -n "s/^\([0-9a-f]\{64\}\)[[:space:]]\{1,\}${ASSET}\$/\1/p" "$SUMS")"
if [ -z "$EXPECTED" ]; then
  echo "no checksum for ${ASSET} in SHA256SUMS of v${VERSION}" >&2
  exit 3
fi

ARCHIVE="${DEST}/${ASSET}"
curl -fsSL --retry 3 --retry-delay 2 "${BASE_URL}/${ASSET}" -o "$ARCHIVE"

ACTUAL="$(sha256sum "$ARCHIVE" | cut -d' ' -f1)"
if [ "$ACTUAL" != "$EXPECTED" ]; then
  echo "checksum mismatch for ${ASSET}: expected ${EXPECTED}, got ${ACTUAL}" >&2
  exit 3
fi

tar -xzf "$ARCHIVE" -C "$DEST"
rm -f "$ARCHIVE"
chmod +x "${DEST}/opencode"

echo "${DEST}/opencode"
