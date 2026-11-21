# Self-hosted OpenChamber + OpenCode container — design

Date: 2026-11-21
Status: approved (approach A — prebuilt artifacts)
Repo: `openchamber-docker` (new), publishes to GHCR

## Intent

One container that serves **both** OpenChamber and OpenCode, on amd64 and arm64,
built from official upstream artifacts, published to GHCR, and rebuilt
automatically when a new OpenChamber version appears.

Why: neither upstream project publishes a self-host image. OpenChamber has a
source-build Dockerfile only; OpenCode publishes a CLI-only image whose
entrypoint is the TUI (no port, no web server, no OpenChamber). Anyone wanting a
self-hosted OpenChamber-over-OpenCode today has to discover the correct wiring
themselves.

## What upstream actually provides (verified)

| Fact | Evidence |
| --- | --- |
| `@openchamber/web` npm package is fully prebuilt | tarball contains `build/server` (31 MB) and `dist/` frontend (66 MB); no compile step |
| Prebuilt package runs standalone | ran `serve --foreground`: UI 200, `/health` ok, spawned + supervised OpenCode |
| Prebuilt package needs no source tree | `dist/` served directly (`Serving static files from …/dist`) |
| OpenCode v2 `serve` serves its own web UI at `/` | `GET /` → 200 HTML, `GET /api/info` → 401 without auth |
| OpenCode image is CLI-only | `ENTRYPOINT ["opencode"]`, no `EXPOSE`, no web server |
| OpenChamber proxy owns `/` and `/api` | `/opencode` returns the OpenChamber SPA, so a second port is required |
| One shared password works for both | with `OPENCODE_SERVER_PASSWORD` + `OPENCHAMBER_UI_PASSWORD` set equal, OpenChamber manages OpenCode with no password rotation, both authenticate |
| Fixed OpenCode port + LAN bind work | `OPENCHAMBER_OPENCODE_PORT=14095`, `OPENCHAMBER_OPENCODE_HOSTNAME=0.0.0.0` honored |
| Native modules work | `node-pty` real PTY spawn passed; `@vscode/ripgrep-linux-x64` binary runs; only the base OS must be glibc |
| Production install is fast | clean `bun install --production` for the package: 4 s, 184 packages, 334 MB |
| Sourcemaps are pure waste at runtime | 17 MB of `.map` inside `@openchamber/web` |

## Goals

- Single `docker run` gives a working OpenChamber at `:3000` and OpenCode UI/API
  at `:4096`, both behind the same password.
- linux/amd64 + linux/arm64, published to GHCR on every upstream release.
- Fast, cache-friendly builds (no source compile; layered and registry-cached).
- Terminal, dictation, ripgrep search, git, SSH, tunnels all functional.

## Non-goals / anti-goals

- Not a desktop/Electron image, not a VS Code image, not mobile.
- Not a Kubernetes operator or Helm chart.
- No source patching of either upstream (approach A). If a patch is ever needed,
  that is a change of approach, not a tweak.

## Constraints

- OpenChamber requires Node ≥ 24.14 and OpenCode 2.x (`engines.opencode >= 2.2.4`,
  hard check for major 2). Base image must be glibc, so **not** alpine/musl.
- `node-pty` ships prebuilds; it must not fall back to `node-gyp` (no toolchain
  in the image).
- A managed OpenCode needs a fixed port and a non-loopback bind to be reachable
  from the host, so OpenChamber must not allocate a random port.
- Runtime image must run as a non-root user with a stable UID so bind mounts work.

## Architecture

```
┌──────────────────────── container (node:24-trixie-slim) ─────────────────────┐
│  tini (PID 1, signal forwarding, zombie reaping)                             │
│                                                                              │
│  openchamber serve --foreground --port 3000 --ui-password <PW>  (uid 1000)   │
│    • serves SPA + /api, proxies OpenCode                                   │
│    • spawns + supervises OpenCode as a child:                                │
│         opencode serve --hostname 0.0.0.0 --port 4096                        │
│         env: OPENCODE_SERVER_PASSWORD=<PW>   (same secret)                    │
│                                                                              │
│  :3000  OpenChamber UI + API      :4096  OpenCode UI + API                   │
└──────────────────────────────────────────────────────────────────────────────┘
```

OpenChamber manages the OpenCode lifecycle (start, health, restart, version
check). It also uses OpenCode's HTTP API internally, so a fixed port is required
and both processes share one password.

Exposure model: publish `3000` (primary) and `4096` (OpenCode's own UI/API).
Publishing `4096` is opt-in in the docs; compose shows both.

## Build design (fast + cacheable)

Multi-stage, but **no application compile**:

1. `base` = `node:24-trixie-slim` + `tini`, plus runtime OS packages:
   `git`, `openssh-client`, `ca-certificates`, `curl`, `bash`, `less`,
   `ripgrep`-fallback not needed (package ships its binary), `python3`.
   Single `apt-get` layer, lists removed.
2. `artifacts` = copies a tiny `package.json` generator + `bun.lock`, runs
   `bun install --production` for `@openchamber/web@<ver>` with
   `trustedDependencies: ["node-pty", "@vscode/ripgrep"]`. One `RUN`, cached on
   the lockfile + version arg.
3. `prune` = deletes `**/*.map`, non-target-arch `node-pty/prebuilds`,
   non-target-arch `sherpa-onnx-*`, docs/tests. Saves ~60–80 MB.
4. `runtime` = copies artifacts, adds the OpenCode binary for the target arch,
   entrypoint, `USER 1000`.

OpenCode binary comes from the official GitHub release tarball
(`opencode-linux-{x64-baseline|arm64}.tar.gz`), verified against upstream
`SHA256SUMS`. Baseline build is used for x64 for maximum CPU compatibility.
Alternative (npm `@opencode/cli` + trusted postinstall) is a fallback only; the
direct tarball avoids an install script.

Caching strategy:
- `# syntax=docker/dockerfile:1.7` with BuildKit cache mounts
  (`/root/.bun/install/cache`, apt cache) so rebuilds reuse downloads.
- Every layer ordered least- to most-volatile: OS → lockfile+version → prune → binary.
- CI uses `docker/build-push-action` with `cache-from/cache-to: type=gha,mode=max`.
- Native runners: amd64 on `ubuntu-24.04`, arm64 on `ubuntu-24.04-arm`
  (no QEMU emulation), then `imagetools create` to merge into one multi-arch tag.

## Version coupling

Two independent upstreams:

- **OpenChamber** drives the release: a new `@openchamber/web` version triggers
  a build.
- **OpenCode** is resolved independently, but must satisfy OpenChamber's
  `engines.opencode` and stay on major 2. The build reads the published
  `@openchamber/web` package's `engines.opencode` and pins OpenCode to the
  current latest 2.x that satisfies it. This is resolved at build time in the
  workflow, so a stale hardcoded pin cannot drift.
- Pins are recorded in `versions.json` (written into the image and layer label),
  exposed via OCI labels and printed at startup.

## Tags

Version-only. The OpenCode build is recorded in a label and the release notes,
never in the tag.

- `latest` — newest release.
- `2` — newest `2.x`.
- `2.7` — newest `2.7.x`.
- `2.7.3` — that exact release.

Every tag points at the same multi-arch manifest.

## Auto-release

`.github/workflows/release.yml`:
- `schedule: cron '0 */6 * * *'` polls the npm dist-tag for `@openchamber/web`.
- `workflow_dispatch` with optional version overrides.
- `repository_dispatch` supported.
- Guard: skip if the GHCR tag already exists (idempotent via `docker manifest inspect`).
- On success: multi-arch push, OCI labels, SBOM + provenance (`sbom: true`,
  `provenance: mode=max`), release notes with both pinned versions.

Also `ci.yml` builds amd64 with `load: true` and runs a smoke test on PRs
(non-root start, both UIs respond, terminal PTY works, auth enforced).

## Runtime contract

- `OPENCHAMBER_UI_PASSWORD` (required). No default: the entrypoint refuses to
  start without it since the server binds `0.0.0.0`.
- Optional: `OPENCODE_SERVER_PASSWORD` (defaults to the UI password),
  `OPENCHAMBER_PORT` (3000), `OPENCODE_PORT` (4096), `PUID/PGID` (default 1000),
  `TZ`, provider API keys passed straight through.
- Volumes:
  - `/home/openchamber/.config/openchamber` — settings, themes, JWT secret, passkeys
  - `/home/openchamber/.local/share/opencode` — sessions, DB, auth
  - `/home/openchamber/.local/state/opencode` — state
  - `/home/openchamber/.config/opencode` — OpenCode config
  - `/home/openchamber/.ssh` — keys
  - `/home/openchamber/workspaces` — projects
- `HEALTHCHECK` hits `/health` and asserts `openCodeRunning`.
- `STOPSIGNAL SIGTERM`, tini forwards to OpenChamber, which stops OpenCode.

## Self-update inside a container

OpenChamber's update route has a container branch (`/.dockerenv` detected): it
shells out to the package manager and does **not** auto-restart, which would
leave a half-updated process tree. The image pins versions in an immutable layer,
so in-app updates are not the supported path. Instead:
- The entrypoint sets `OPENCHAMBER_UPDATE_API_URL` to a local no-op or leaves
  the check visible but blocked. *Decision to make during implementation:* we
  should make the in-app update button report "update the image" rather than
  attempt a partial npm install. Cleanest is `isUnmanagedInstall()` returning
  true, which the UI already renders as `installBlocked: 'manual-install'`.
  Verify the exact detection path and, if needed, set the env/layout that
  triggers it.

## What's left to the builder

- Exact OS package list (keep minimal but complete for git/ssh/tunnels).
- Prune rules verified by a run of the smoke test after pruning.
- PUID/PGID remapping (entrypoint `usermod`/`groupmod` + chown).
- Whether to add a `slim` variant later (non-goal for v1).

## Testing plan

1. `docker build` both arches locally (buildx, native arm runner in CI).
2. Smoke test script:
   - container starts as uid 1000, no root
   - `GET :3000/` → 200; `GET :3000/health` → `openCodeRunning: true`
   - `POST :3000/auth/session` with password → 200; without → not authenticated
   - `GET :4096/` → 200; `:4096/api/info` with basic auth → 200, without → 401
   - terminal: open PTY over the websocket, run `echo ok`, expect output
   - restart container → sessions and settings persist
3. Compare image size against the ~1.0 GB budget; fail if > 1.3 GB.
