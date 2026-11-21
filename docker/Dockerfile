# syntax=docker/dockerfile:1.7

# ---------------------------------------------------------------------------
# base: glibc runtime. Alpine/musl would break node-pty's linux prebuilds.
# ---------------------------------------------------------------------------
FROM node:24-trixie-slim AS base

ARG DEBIAN_FRONTEND=noninteractive

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update \
 && apt-get install -y --no-install-recommends \
      bash \
      ca-certificates \
      curl \
      git \
      less \
      openssh-client \
      python3 \
      tini \
      util-linux \
 && rm -rf /var/lib/apt/lists/*

ENV LANG=C.UTF-8 \
    NODE_ENV=production \
    SHELL=/bin/bash

# ---------------------------------------------------------------------------
# artifacts: install the published, fully prebuilt OpenChamber package.
# Bun is used only here; it never reaches the shipped image.
# Must run on the target architecture so optional native packages resolve.
#
# No lockfile on purpose: the image is rebuilt for every upstream release, and a
# lockfile pinned to one OpenChamber version fails the next build. Resolving the
# dependency ranges fresh each time is what keeps the release automatic.
# ---------------------------------------------------------------------------
FROM oven/bun:1.4.4-slim AS artifacts

ARG OPENCHAMBER_VERSION

WORKDIR /app

COPY docker/package.json /app/package.json

RUN --mount=type=cache,target=/root/.bun/install/cache,sharing=locked \
    bun -e "const fs=require('fs');const p='/app/package.json';const j=JSON.parse(fs.readFileSync(p,'utf8'));j.dependencies['@openchamber/web']=process.env.OPENCHAMBER_VERSION;fs.writeFileSync(p,JSON.stringify(j,null,2));" \
 && bun install --production \
 && test -f /app/node_modules/@openchamber/web/build/bin/cli.js \
 && test -f /app/node_modules/@openchamber/web/dist/index.html

# Prune here, not in the runtime stage: pruning after COPY would leave the
# un-pruned layer in the image and roughly double node_modules' footprint.
#
# Deliberately conservative. A directory named `doc` is real code in packages
# like yaml (yaml/dist/doc/*), so only clearly test-only paths are removed.
# bun-pty is imported only when the runtime is Bun (see loadTerminalPtyProvider);
# this image runs Node and uses node-pty, so bun-pty is dead weight.
ARG TARGETARCH
RUN set -eux; \
    case "${TARGETARCH}" in amd64) NT_ARCH=x64 ;; arm64) NT_ARCH=arm64 ;; *) echo "unsupported arch: ${TARGETARCH}" >&2; exit 1 ;; esac; \
    find /app/node_modules -type f -name '*.map' -delete; \
    for dir in /app/node_modules/node-pty/prebuilds/*; do \
      [ -d "$dir" ] || continue; \
      [ "$(basename "$dir")" = "linux-${NT_ARCH}" ] || rm -rf "$dir"; \
    done; \
    for dir in /app/node_modules/sherpa-onnx-*; do \
      [ -d "$dir" ] || continue; \
      case "$(basename "$dir")" in sherpa-onnx-node|"sherpa-onnx-linux-${NT_ARCH}") ;; *) rm -rf "$dir" ;; esac; \
    done; \
    rm -rf /app/node_modules/bun-pty; \
    find /app/node_modules -type d \( -name test -o -name tests -o -name __tests__ -o -name __mocks__ -o -name .github \) -prune -exec rm -rf {} +; \
    find /app/node_modules -type f \( -name '*.d.ts' -o -name '*.d.mts' -o -name '*.d.cts' \) -delete; \
    find /app/node_modules -type f \( -name 'CHANGELOG*' -o -name 'CHANGES*' \) -delete; \
    du -sh /app/node_modules

# ---------------------------------------------------------------------------
# runtime: node runtime + artifacts + the OpenCode binary for THIS arch.
# ---------------------------------------------------------------------------
FROM base AS runtime

ARG OPENCHAMBER_VERSION
ARG OPENCODE_VERSION
ARG TARGETARCH
ARG OPENCODE_BINARY_DIR=dist/opencode

COPY ${OPENCODE_BINARY_DIR}/opencode /usr/local/bin/opencode
RUN chmod 0755 /usr/local/bin/opencode \
 && ln -sf /usr/local/bin/opencode /usr/local/bin/opencode2 \
 && /usr/local/bin/opencode --version

RUN groupmod --new-name openchamber node \
 && usermod --login openchamber --home /home/openchamber --move-home node \
 && mkdir -p /home/openchamber \
 && chown -R 1000:1000 /home/openchamber

COPY --from=artifacts /app/node_modules /app/node_modules
COPY --from=artifacts /app/package.json /app/package.json

COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh

RUN set -eux; \
    chmod 0755 /usr/local/bin/entrypoint.sh; \
    mkdir -p /etc/ssh/ssh_known_hosts.d; \
    ssh-keyscan -t rsa,ecdsa,ed25519 github.com gitlab.com > /etc/ssh/ssh_known_hosts 2>/dev/null || true; \
    chmod 0644 /etc/ssh/ssh_known_hosts; \
    chown -R 1000:1000 /home/openchamber

# Bind-mounted directories are owned by the host user, so the app cannot write
# them. The entrypoint starts as root, fixes ownership, then drops to uid 1000
# before starting anything; the servers themselves never run as root.
ENV HOME=/home/openchamber \
    OPENCODE_CONFIG_DIR=/home/openchamber/.config/opencode \
    OPENCHAMBER_HOST=0.0.0.0 \
    OPENCHAMBER_OPENCODE_HOSTNAME=0.0.0.0 \
    OPENCODE_PORT=4096

WORKDIR /home/openchamber

LABEL org.opencontainers.image.title="OpenChamber self-host" \
      org.opencontainers.image.description="OpenChamber on :3000 and OpenCode on :4096 in one container" \
      org.opencontainers.image.source="https://github.com/openchamber/openchamber" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${OPENCHAMBER_VERSION}" \
      dev.openchamber.opencode.version="${OPENCODE_VERSION}"

EXPOSE 3000 4096

STOPSIGNAL SIGTERM

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD curl -fsS "http://127.0.0.1:${OPENCHAMBER_PORT:-3000}/health" | grep -q '"openCodeRunning"' || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
