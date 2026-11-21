#!/usr/bin/env bash
# smoke-test.sh [container-name] [password] [web-port] [opencode-port]
# Black-box verification of a running container.
set -euo pipefail

NAME="${1:-oc-smoke}"
PASS="${2:-smokepw}"
WEB="${3:-13001}"
OC="${4:-14097}"

pass=0
fail=0
ok() { echo "ok $1"; pass=$((pass + 1)); }
no() { echo "FAIL $1"; fail=$((fail + 1)); }

# The password is user input; build the JSON body safely.
body="$(PASS="$PASS" python3 -c 'import json,os; print(json.dumps({"password": os.environ["PASS"]}))')"
wrong_body='{"password":"definitely-not-the-password"}'

# 1. The servers run as the non-root user. PID 1 is root only long enough to
#    fix mount ownership; the node and opencode processes must be uid 1000.
#    Match on /proc/PID/comm so the probe's own shell cannot match itself.
uids="$(docker exec "$NAME" sh -c '
  for p in /proc/[0-9]*; do
    comm=$(cat "$p/comm" 2>/dev/null) || continue
    case "$comm" in
      node|opencode) stat -c %u "$p" ;;
    esac
  done | sort -u
' 2>/dev/null | tr '\n' ' ')"

if [ "$uids" = "1000 " ]; then
  ok "servers-run-as-uid-1000"
else
  no "servers-run-as-uid-1000 (got '${uids}')"
fi

# 2. OpenChamber UI
code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${WEB}/")"
[ "$code" = "200" ] && ok "openchamber-root-200" || no "openchamber-root (got $code)"

# 3. OpenChamber is supervising OpenCode
if curl -s "http://127.0.0.1:${WEB}/health" | grep -q '"openCodeRunning"[[:space:]]*:[[:space:]]*true'; then
  ok "opencode-managed-and-running"
else
  no "opencode-managed-and-running"
fi

# 4. auth is enforced and accepted
code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${WEB}/api/session")"
[ "$code" = "401" ] && ok "openchamber-auth-required" || no "openchamber-auth-required (got $code)"

jar="$(mktemp)"
trap 'rm -f "$jar"' EXIT
code="$(curl -s -c "$jar" -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
  -d "$body" "http://127.0.0.1:${WEB}/auth/session")"
[ "$code" = "200" ] && ok "openchamber-login-accepted" || no "openchamber-login (got $code)"

code="$(curl -s -b "$jar" -o /dev/null -w '%{http_code}' "http://127.0.0.1:${WEB}/api/session")"
[ "$code" = "200" ] && ok "openchamber-session-valid" || no "openchamber-session (got $code)"

wrong="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
  -d "$wrong_body" "http://127.0.0.1:${WEB}/auth/session")"
[ "$wrong" != "200" ] && ok "openchamber-wrong-password-rejected" || no "openchamber-wrong-password-rejected"

# 5. OpenCode UI is reachable on its own port
code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${OC}/")"
[ "$code" = "200" ] && ok "opencode-root-200" || no "opencode-root (got $code)"

# 6. OpenCode API uses the same password
code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${OC}/api/info")"
[ "$code" = "401" ] && ok "opencode-api-auth-required" || no "opencode-api-auth-required (got $code)"

code="$(curl -s -u "opencode:${PASS}" -o /dev/null -w '%{http_code}' "http://127.0.0.1:${OC}/api/info")"
[ "$code" = "200" ] && ok "opencode-shared-password-works" || no "opencode-shared-password (got $code)"

# 7. The app's own terminal backend allocates a real tty, as the server would.
if docker exec -u 1000 "$NAME" node -e "
const pty = require('/app/node_modules/node-pty');
const p = pty.spawn('sh', ['-c', 'echo PTY_OK; tty'], { name: 'xterm-256color', cols: 80, rows: 24 });
let out = '';
p.onData((d) => { out += d; });
setTimeout(() => { p.kill(); process.exit(out.includes('PTY_OK') && out.includes('/dev/pts/') ? 0 : 1); }, 2000);
" >/dev/null 2>&1; then
  ok "terminal-pty-works"
else
  no "terminal-pty-works"
fi

# 8. Restart recovers, and state actually persists on the data volume.
#    Assert on real content (the JWT secret), not on a directory listing.
secret_path=/home/openchamber/.config/openchamber/jwt-secret
before="$(docker exec "$NAME" sh -c "cat $secret_path 2>/dev/null | sha256sum" || true)"
[ -n "$before" ] && ok "config-written-before-restart" || no "config-written-before-restart"

docker restart "$NAME" >/dev/null
for _ in $(seq 1 45); do
  curl -fsS -o /dev/null "http://127.0.0.1:${WEB}/health" 2>/dev/null && break
  sleep 2
done
if curl -s "http://127.0.0.1:${WEB}/health" | grep -q '"openCodeRunning"[[:space:]]*:[[:space:]]*true'; then
  ok "restart-recovers"
else
  no "restart-recovers"
fi

after="$(docker exec "$NAME" sh -c "cat $secret_path 2>/dev/null | sha256sum" || true)"
if [ -n "$before" ] && [ "$before" = "$after" ]; then
  ok "restart-preserves-state"
else
  no "restart-preserves-state (before=$before after=$after)"
fi

echo "---"
echo "passed: ${pass}  failed: ${fail}"
[ "$fail" -eq 0 ]
