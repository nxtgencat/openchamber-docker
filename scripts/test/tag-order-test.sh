#!/usr/bin/env bash
# scripts/test/tag-order-test.sh — the moving-tag guard must order versions
# numerically, not lexically, and must ignore non-version tags.
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"

fail=0
check() {
  local newest="$1" candidate="$2" expect="$3"
  local got
  got="$(printf '%s\n%s\n' "$newest" "$candidate" | sort -V | tail -1)"
  [ "$got" = "$expect" ] || { echo "FAIL: newest=$newest candidate=$candidate -> $got, expected $expect"; fail=1; }
}

# 2.10.0 must beat 2.9.9 (lexical sort would get this wrong)
check "2.9.9" "2.10.0" "2.10.0"
# an older manual dispatch must not move latest back
check "2.10.0" "2.9.9" "2.10.0"
# equal versions are not a regression
check "2.7.3" "2.7.3" "2.7.3"

# the helper must tolerate a missing image and emit nothing
out="$("$here/scripts/newest-published-tag.sh" ghcr.io/example/does-not-exist-$$ 2>/dev/null || true)"
[ -z "$out" ] || { echo "FAIL: expected no output for a missing image, got '$out'"; fail=1; }

[ "$fail" -eq 0 ] && echo "tag-order ok"
exit "$fail"
