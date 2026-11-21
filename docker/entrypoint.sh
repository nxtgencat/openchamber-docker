#!/usr/bin/env bash
# Runtime entrypoint. Starts as root only long enough to make the data
# directories writable by the host user, then drops privileges for good.
set -eu

APP_HOME=/home/openchamber
APP_ENTRY=/app/node_modules/@openchamber/web/build/bin/cli.js

if [ -z "${OPENCHAMBER_UI_PASSWORD:-}" ]; then
  echo "OPENCHAMBER_UI_PASSWORD is required" >&2
  echo "Docker publishes this port, so the UI must not run without a password." >&2
  exit 78
fi

# One secret for both UIs, always. OpenChamber forwards this to the OpenCode it
# manages; if the two differ, OpenChamber rotates OpenCode's password and :4096
# stops accepting the password the user knows.
if [ -n "${OPENCODE_SERVER_PASSWORD:-}" ] && [ "$OPENCODE_SERVER_PASSWORD" != "$OPENCHAMBER_UI_PASSWORD" ]; then
  echo "[entrypoint] ignoring OPENCODE_SERVER_PASSWORD: both UIs share OPENCHAMBER_UI_PASSWORD" >&2
fi
export OPENCODE_SERVER_PASSWORD="$OPENCHAMBER_UI_PASSWORD"

OPENCHAMBER_PORT="${OPENCHAMBER_PORT:-3000}"
OPENCODE_PORT="${OPENCODE_PORT:-4096}"
export OPENCHAMBER_PORT OPENCODE_PORT

# Fixed bind contract. A managed OpenCode must be reachable from outside the
# container and on a known port, and a stray OPENCODE_HOST would make
# OpenChamber treat it as external and stop managing it.
export OPENCHAMBER_HOST=0.0.0.0
export OPENCHAMBER_OPENCODE_HOSTNAME=0.0.0.0
export OPENCHAMBER_OPENCODE_PORT="$OPENCODE_PORT"
export HOME="${APP_HOME}"
export OPENCODE_CONFIG_DIR="${OPENCODE_CONFIG_DIR:-${APP_HOME}/.config/opencode}"
unset OPENCODE_HOST OPENCODE_SKIP_START OPENCHAMBER_SKIP_OPENCODE_START

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

# Everything the app writes lives under these paths, so they must exist before
# the user switch. Fail loudly rather than starting a server that cannot save.
DATA_DIRS="
${APP_HOME}/.config/openchamber
${APP_HOME}/.config/opencode
${APP_HOME}/.local/share/opencode
${APP_HOME}/.local/state/opencode
${APP_HOME}/.ssh
${APP_HOME}/workspaces
"

for dir in $DATA_DIRS; do
  if ! mkdir -p "$dir" 2>/dev/null; then
    echo "[entrypoint] cannot create ${dir}" >&2
    echo "[entrypoint] the mount is not writable; chown it to ${PUID}:${PGID} on the host" >&2
    exit 78
  fi
done

if [ "$(id -u)" = "0" ]; then
  if [ "$PUID" != "1000" ] || [ "$PGID" != "1000" ]; then
    groupmod -o -g "$PGID" openchamber 2>/dev/null || echo "[entrypoint] warning: could not set gid ${PGID}" >&2
    usermod -o -u "$PUID" -g "$PGID" openchamber 2>/dev/null || echo "[entrypoint] warning: could not set uid ${PUID}" >&2
  fi

  # Recursive over the small config trees; shallow for workspaces, which hold
  # the user's own repositories and can be large.
  for dir in $DATA_DIRS; do
    case "$dir" in
      "${APP_HOME}/workspaces") chown "$PUID:$PGID" "$dir" 2>/dev/null || true ;;
      *) chown -R "$PUID:$PGID" "$dir" 2>/dev/null || true ;;
    esac
  done
  chown "$PUID:$PGID" "$APP_HOME" 2>/dev/null || true

  # git refuses to operate on a repository owned by another uid.
  for cfg in "${APP_HOME}/.gitconfig"; do
    git config --file "$cfg" --replace-all safe.directory '*' 2>/dev/null || true
    chown "$PUID:$PGID" "$cfg" 2>/dev/null || true
  done

  exec_as=(setpriv --reuid "$PUID" --regid "$PGID" --init-groups)
else
  exec_as=()
  if [ "$PUID" != "$(id -u)" ]; then
    echo "[entrypoint] running as uid:$(id -u); to remap to ${PUID}:${PGID} the container must start as root" >&2
  fi
  if [ ! -w "${APP_HOME}/.config/openchamber" ]; then
    echo "[entrypoint] ${APP_HOME}/.config/openchamber is not writable; settings cannot be saved" >&2
  fi
fi

# Children inherit this environment, so they must not see stale root values.
export USER=openchamber LOGNAME=openchamber SHELL=/bin/bash

ARGV=(node "$APP_ENTRY" serve --port "$OPENCHAMBER_PORT" --ui-password "$OPENCHAMBER_UI_PASSWORD" --foreground)

echo "[entrypoint] OpenChamber :${OPENCHAMBER_PORT}  OpenCode :${OPENCODE_PORT}  uid:${PUID} gid:${PGID}"

exec tini -- "${exec_as[@]}" "${ARGV[@]}"
