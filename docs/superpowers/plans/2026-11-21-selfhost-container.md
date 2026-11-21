# OpenChamber + OpenCode Self-Host Container — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and publish a single multi-arch container image that serves OpenChamber on `:3000` and OpenCode on `:4096`, sharing one password, rebuilt automatically when a new OpenChamber version appears.

**Architecture:** One glibc-based image (`node:24-trixie-slim` + tini). OpenChamber is installed from its prebuilt npm tarball (no compile) and manages a child `opencode serve` process bound to `0.0.0.0:4096`. Both share `OPENCODE_SERVER_PASSWORD`, which OpenChamber forwards. Release CI polls npm, resolves a compatible OpenCode 2.x, builds natively on amd64 and arm64 runners, and merges both into one GHCR tag.

**Tech Stack:** Docker BuildKit, Node 24 (Debian trixie), Bun (install only), tini, GitHub Actions, `docker/build-push-action`, `docker/buildx imagetools`, bash.

**Spec:** `docs/superpowers/specs/2026-11-21-selfhost-container-design.md`

## Global Constraints

- Base image MUST be glibc. Alpine/musl breaks `node-pty` prebuilds. Use `node:24-trixie-slim`.
- OpenChamber version is pinned exactly (`@openchamber/web@<version>`); no `^` or `latest` inside the image.
- OpenCode MUST be major version `2` and satisfy `engines.opencode` from the installed OpenChamber package (`>=2.2.4` at time of writing).
- Container MUST run as a non-root user, UID `1000`, with a writable `$HOME`.
- The image MUST NOT contain a C/C++ toolchain, `node-gyp`, or source trees.
- `OPENCHAMBER_UI_PASSWORD` is required at runtime; entrypoint exits non-zero without it.
- OpenChamber must bind `0.0.0.0` (Docker needs it) and OpenCode must bind `0.0.0.0` on a **fixed** port.
- Published ports: `3000` (OpenChamber UI/API) and `4096` (OpenCode UI/API).
- All work happens in `/home/ubuntu/Documents/OC/openchamber-docker`.
- No shell command may depend on `~` expansion inside a `RUN` as root; use absolute paths.

## Review Focus

These are the places a plausible implementation breaks in a way no single task test catches. Each has a test pinned in the named task.

1. **Bind mounts with the wrong UID** — a user passing `-v ./data:/home/openchamber/.config/openchamber` gets `EACCES` and the UI never starts. Task 5.
2. **Password mismatch between the two UIs** — if `OPENCODE_SERVER_PASSWORD` is not derived from the UI password, OpenChamber rotates OpenCode's secret and `:4096` becomes unusable. Task 6.
3. **Terminal works but dies after restart** — a PTY that only works because it inherited root's environment. Task 5/8.
4. **Wrong-arch binary pulled into an image** — arm64 image containing amd64 `opencode`, caught late. Task 3/8.
5. **Auto-release publishing a stale or duplicate tag** — the 6-hour poll re-pushing over an existing tag, or shipping an incompatible OpenCode. Task 9.

---

## File Structure

Created files, each with one responsibility:

| File | Responsibility |
| --- | --- |
| `docker/Dockerfile` | Multi-stage image definition, pure artifact assembly |
| `docker/entrypoint.sh` | Runtime contract: validate env, PUID/PGID, drop privileges, exec `tini`+OpenChamber |
| `docker/package.json` | Dependency manifest for the install layer (single source of the OpenChamber pin) |
| `.dockerignore` | Keep build context tiny |
| `scripts/resolve-versions.sh` | Given an OpenChamber version, print the matching OpenCode version |
| `scripts/verify-artifacts.sh` | Verify OpenCode tarball checksum for a given arch |
| `scripts/smoke-test.sh` | Black-box test of a running container |
| `.github/workflows/release.yml` | Poll, resolve, multi-arch build, push, tag, notes |
| `.github/workflows/ci.yml` | PR build + smoke test, amd64 |
| `docker-compose.yml` | Documented reference deployment |
| `README.md` | Install, env vars, volumes, both URLs |
| `versions.json` | Emitted at build time into the image and as OCI labels |

---

### Task 1: Repository skeleton and build context guard

**Files:**
- Create: `.dockerignore`
- Create: `.gitignore`
- Create: `README.md` (stub, filled in Task 10)
- Test: `scripts/test/context-test.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: a repo layout the later tasks drop files into; `.dockerignore` that excludes `docs/`, `.git/`, `data/`, `workspaces/`.

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
# scripts/test/context-test.sh — asserts build context excludes heavy/private paths
set -euo pipefail
cd "$(dirname "$0")/../.."
fail=0
for pattern in docs .git data workspaces node_modules; do
  grep -qxF "$pattern" .dockerignore || { echo "MISSING: $pattern"; fail=1; }
done
[ "$fail" -eq 0 ] && echo "context ok"
exit "$fail"
```

- [ ] **Step 2: Run it, expect failure**

Run: `bash scripts/test/context-test.sh`
Expected: `MISSING: .dockerignore at context root`, exit 1.

- [ ] **Step 3: Create the files**

`.dockerignore` at the context root — `docs`, `.git`, `data`, `workspaces`, `node_modules`, `.cache`, `**/*.log`. `dist/` stays included because the Dockerfile copies the OpenCode binary from it.

`.gitignore` — `data/`, `workspaces/`, `*.log`, `versions.json`.

`README.md` — single line `# OpenChamber self-host image` for now.

- [ ] **Step 4: Run the test, expect pass**

Run: `bash scripts/test/context-test.sh`
Expected: `context ok`, exit 0.

- [ ] **Step 5: Commit**

```bash
git init -q && git add -A && git commit -m "chore: repository skeleton and build context"
```

---

### Task 2: Pin resolution script

**Files:**
- Create: `scripts/resolve-versions.sh`
- Test: `scripts/test/resolve-versions-test.sh`

**Interfaces:**
- Consumes: network access to the npm registry.
- Produces: `resolve-versions.sh <openchamber-version>` prints two lines to stdout, `OPENCHAMBER_VERSION=<x>` then `OPENCODE_VERSION=<y>`; exits 2 with a message on stderr if no compatible OpenCode 2.x exists.

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
# scripts/test/resolve-versions-test.sh
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
out="$("$here/scripts/resolve-versions.sh" 2.7.3)"
echo "$out"
grep -q '^OPENCHAMBER_VERSION=2\.7\.3$' <<<"$out" || { echo "FAIL openchamber pin"; exit 1; }
oc="$(sed -n 's/^OPENCODE_VERSION=//p' <<<"$out")"
[[ "$oc" =~ ^2\.[0-9]+\.[0-9]+$ ]] || { echo "FAIL opencode not 2.x: $oc"; exit 1; }
# must satisfy the package's own engine floor
python3 - "$oc" <<'PY'
import sys
v = tuple(int(p) for p in sys.argv[1].split('.'))
assert v >= (2, 2, 4), f"below engine floor: {v}"
PY
echo "resolve ok"
```

- [ ] **Step 2: Run it, expect failure**

Run: `bash scripts/test/resolve-versions-test.sh`
Expected: `No such file or directory` for `resolve-versions.sh`.

- [ ] **Step 3: Implement `scripts/resolve-versions.sh`**

Signature: `resolve-versions.sh <openchamber-version> -> stdout KEY=VALUE lines`.

Logic to implement, in order:
1. `curl -fsSL "https://registry.npmjs.org/@openchamber/web/$1"` and read `engines.opencode` with `python3 -c`.
2. Parse the floor with a regex (`>=X.Y.Z`); fail with exit 2 if absent.
3. `curl -fsSL "https://registry.npmjs.org/@opencode/cli"` and pick `dist-tags.latest`.
4. If `latest` is not major `2` or is below the floor, search `versions` for the highest `2.x` satisfying the floor.
5. Print the two lines. All JSON parsing via a single `python3 -` heredoc, no `jq` dependency.

- [ ] **Step 4: Run the test, expect pass**

Run: `bash scripts/test/resolve-versions-test.sh`
Expected: `resolve ok`.

- [ ] **Step 5: Commit**

```bash
git add scripts tests && git commit -m "feat: resolve compatible opencode pin from openchamber engines"
```

---

### Task 3: OpenCode artifact fetch and checksum verification

**Files:**
- Create: `scripts/verify-artifacts.sh`
- Test: `scripts/test/verify-artifacts-test.sh`

**Interfaces:**
- Consumes: `OPENCODE_VERSION`, `TARGETARCH` (`amd64`|`arm64`).
- Produces: downloads `opencode-linux-<x64-baseline|arm64>.tar.gz` for the version into a target directory, verifies it against the release `SHA256SUMS`, and prints the extracted binary path.

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
# scripts/test/verify-artifacts-test.sh — uses the real release, amd64 only
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
bin="$("$here/scripts/verify-artifacts.sh" 2.3.2 amd64 "$tmp")"
test -x "$bin" || { echo "FAIL not executable: $bin"; exit 1; }
"$bin" --version | grep -q '2\.3\.2' || { echo "FAIL wrong version"; exit 1; }
echo "artifacts ok"
```

- [ ] **Step 2: Run it, expect failure**

Run: `bash scripts/test/verify-artifacts-test.sh`
Expected: script missing.

- [ ] **Step 3: Implement `scripts/verify-artifacts.sh`**

Signature: `verify-artifacts.sh <opencode-version> <amd64|arm64> <dest-dir> -> stdout path-to-opencode`.

Behaviour:
1. Map arch: `amd64 -> x64-baseline`, `arm64 -> arm64`; anything else exits 2.
2. Download `https://github.com/anomalyco/opencode/releases/download/v<ver>/SHA256SUMS` and the matching `opencode-linux-<arch>.tar.gz`.
3. `grep` the expected hash for that filename from `SHA256SUMS`, then `sha256sum -c` it.
4. Extract into `<dest-dir>` and `chmod +x` the `opencode` binary; print its absolute path.

- [ ] **Step 4: Run the test, expect pass**

Run: `bash scripts/test/verify-artifacts-test.sh`
Expected: `artifacts ok` (downloads ~120 MB once).

- [ ] **Step 5: Commit**

```bash
git add scripts && git commit -m "feat: fetch and checksum-verify opencode release binary"
```

---

### Task 4: Install layer manifest

**Files:**
- Create: `docker/package.json`
- Test: `scripts/test/package-json-test.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: a manifest whose only dependency is `@openchamber/web` at an exact version, plus `trustedDependencies` for `node-pty` and `@vscode/ripgrep`.

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
# scripts/test/package-json-test.sh
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
python3 - "$here/docker/package.json" <<'PY'
import json, re, sys
d = json.load(open(sys.argv[1]))
assert d["private"] is True, "must be private"
deps = d["dependencies"]
assert list(deps) == ["@openchamber/web"], deps
assert re.fullmatch(r"\d+\.\d+\.\d+", deps["@openchamber/web"]), "pin must be exact"
assert set(d["trustedDependencies"]) == {"node-pty", "@vscode/ripgrep"}, d["trustedDependencies"]
print("package.json ok")
PY
```

- [ ] **Step 2: Run it, expect failure**

Run: `bash scripts/test/package-json-test.sh`
Expected: `FileNotFoundError`.

- [ ] **Step 3: Create `docker/package.json`**

```json
{
  "name": "openchamber-selfhost-artifacts",
  "private": true,
  "version": "0.0.0",
  "dependencies": { "@openchamber/web": "2.7.3" },
  "trustedDependencies": ["node-pty", "@vscode/ripgrep"]
}
```

- [ ] **Step 4: Run the test, expect pass**

Run: `bash scripts/test/package-json-test.sh`
Expected: `package.json ok`.

- [ ] **Step 5: Commit**

```bash
git add docker/package.json scripts && git commit -m "feat: install manifest for prebuilt openchamber artifacts"
```

---

### Task 5: Multi-stage Dockerfile

**Files:**
- Create: `docker/Dockerfile`
- Modify: `docker/package.json` (version substituted by build arg — see step 3)
- Test: `scripts/test/dockerfile-test.sh`

**Interfaces:**
- Consumes: `TARGETARCH`, `OPENCHAMBER_VERSION`, `OPENCODE_VERSION` build args.
- Produces: an image whose entrypoint is `/usr/local/bin/entrypoint.sh`, `EXPOSE 3000 4096`, `USER 1000`, `HEALTHCHECK` on `/health`.

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
# scripts/test/dockerfile-test.sh — static assertions on the Dockerfile
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
f="$here/docker/Dockerfile"
grep -q 'FROM node:24-trixie-slim' "$f" || { echo "FAIL base"; exit 1; }
grep -q 'tini' "$f" || { echo "FAIL tini"; exit 1; }
grep -q 'USER 1000' "$f" || { echo "FAIL uid"; exit 1; }
grep -q 'EXPOSE 3000 4096' "$f" || { echo "FAIL ports"; exit 1; }
grep -q 'HEALTHCHECK' "$f" || { echo "FAIL healthcheck"; exit 1; }
grep -q 'STOPSIGNAL SIGTERM' "$f" || { echo "FAIL stopsignal"; exit 1; }
grep -q 'ENTRYPOINT \["/usr/local/bin/entrypoint.sh"\]' "$f" || { echo "FAIL entrypoint"; exit 1; }
grep -qE 'rm -rf .*\.map' "$f" || { echo "FAIL sourcemap prune"; exit 1; }
! grep -q 'node-gyp' "$f" || { echo "FAIL toolchain present"; exit 1; }
echo "dockerfile ok"
```

- [ ] **Step 2: Run it, expect failure**

Run: `bash scripts/test/dockerfile-test.sh`
Expected: `grep: .../docker/Dockerfile: No such file`.

- [ ] **Step 3: Write `docker/Dockerfile`**

Four stages, in this order:

1. `# syntax=docker/dockerfile:1.7`
2. `FROM node:24-trixie-slim AS base` — one `apt-get install --no-install-recommends` of `tini git openssh-client ca-certificates curl bash less python3`, then `rm -rf /var/lib/apt/lists/*`.
3. `FROM base AS artifacts` — copy `docker/package.json` to `/app/package.json`, rewrite the pin with `npm pkg set dependencies.@openchamber/web="$OPENCHAMBER_VERSION"` (build arg), install Bun via the official `curl` script pinned to `1.4.4`, then `bun install --production --frozen-lockfile=false` with a BuildKit cache mount at `/root/.bun/install/cache`.
4. `FROM artifacts AS runtime` — `ADD` the extracted OpenCode binary from the build context path `/tmp/opencode/opencode` (fetched by the workflow before build), create user `openchamber` UID/GID 1000 with `$HOME=/home/openchamber`, copy artifacts, prune with `find /app/node_modules -name '*.map' -delete` and removal of non-linux or non-`$TARGETARCH` `node-pty/prebuilds/*` and `sherpa-onnx-*`, copy `entrypoint.sh`, then `USER 1000`, `EXPOSE 3000 4096`, `STOPSIGNAL SIGTERM`, `HEALTHCHECK --interval=30s --timeout=5s --start-period=60s CMD curl -fsS http://127.0.0.1:3000/health | grep -q '"openCodeRunning":true'`, `ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]`.

Add `LABEL org.opencontainers.image.version`, `.source`, and custom `dev.openchamber.opencode.version` from build args.

- [ ] **Step 4: Run the static test, expect pass**

Run: `bash scripts/test/dockerfile-test.sh`
Expected: `dockerfile ok`.

- [ ] **Step 5: Commit**

```bash
git add docker scripts && git commit -m "feat: multi-stage image assembling prebuilt artifacts"
```

---

### Task 6: Entrypoint

**Files:**
- Create: `docker/entrypoint.sh`
- Test: `scripts/test/entrypoint-test.sh`

**Interfaces:**
- Consumes: `OPENCHAMBER_UI_PASSWORD` (required), `OPENCODE_SERVER_PASSWORD` (defaults to UI password), `OPENCHAMBER_PORT` (3000), `OPENCODE_PORT` (4096), `PUID`/`PGID` (1000).
- Produces: `exec tini -- …` running OpenChamber as the target UID; mirrors the password into OpenCode's env; exits 78 (`EX_CONFIG`) when the password is missing.

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
# scripts/test/entrypoint-test.sh — runs the script on the host in a sandbox
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
s="$here/docker/entrypoint.sh"

# 1. refuses to start without a password
out="$(env -i PATH=/usr/bin:/bin HOME=/tmp OPENCHAMBER_DATA_DIR=/tmp/oc-data bash "$s" 2>&1 || true)"
grep -q 'OPENCHAMBER_UI_PASSWORD is required' <<<"$out" || { echo "FAIL: no password guard"; echo "$out"; exit 1; }

# 2. mirrors the password and prints the resolved command without executing
out="$(env -i PATH=/usr/bin:/bin HOME=/tmp OPENCHAMBER_DATA_DIR=/tmp/oc-data \
  OPENCHAMBER_UI_PASSWORD=pw OPENCHAMBER_DRY_RUN=1 bash "$s")"
grep -q 'OPENCODE_SERVER_PASSWORD=pw' <<<"$out" || { echo "FAIL: password not mirrored"; echo "$out"; exit 1; }
grep -q -- '--port 3000' <<<"$out" || { echo "FAIL: default port"; exit 1; }
echo "entrypoint ok"
```

- [ ] **Step 2: Run it, expect failure**

Run: `bash scripts/test/entrypoint-test.sh`
Expected: missing file.

- [ ] **Step 3: Implement `docker/entrypoint.sh`**

Signature: `entrypoint.sh` (no args; all config from env). Sheet:

1. `set -eu`.
2. If `OPENCHAMBER_UI_PASSWORD` is empty: print `OPENCHAMBER_UI_PASSWORD is required` to stderr and `exit 78`.
3. `export OPENCODE_SERVER_PASSWORD="${OPENCODE_SERVER_PASSWORD:-$OPENCHAMBER_UI_PASSWORD}"`.
4. Resolve `OPENCHAMBER_PORT`/`OPENCODE_PORT` defaults; export both.
5. Export the fixed bind contract: `OPENCHAMBER_HOST=0.0.0.0`, `OPENCHAMBER_OPENCODE_HOSTNAME=0.0.0.0`, `OPENCHAMBER_OPENCODE_PORT=$OPENCODE_PORT`, and **unset** `OPENCODE_HOST`/`OPENCODE_SKIP_START` so a stray host env cannot disable management.
6. If `PUID`/`PGID` are set and differ from the current uid/gid, `usermod`/`groupmod` then `chown` the home and data dirs (best effort, warn on failure).
7. If `OPENCHAMBER_DRY_RUN=1`, print `OPENCODE_SERVER_PASSWORD=$OPENCODE_SERVER_PASSWORD` and the final argv, then `exit 0`.
8. `exec tini -- node /app/node_modules/@openchamber/web/build/bin/cli.js serve --port "$OPENCHAMBER_PORT" --ui-password "$OPENCHAMBER_UI_PASSWORD" --foreground`.

Note: use `--foreground` so logs stream and tini owns the process tree.

- [ ] **Step 4: Run the test, expect pass**

Run: `bash scripts/test/entrypoint-test.sh`
Expected: `entrypoint ok`.

- [ ] **Step 5: Commit**

```bash
git add docker scripts && git commit -m "feat: entrypoint with password guard and fixed port contract"
```

---

### Task 7: Build the image locally

**Files:**
- Create: `scripts/build-local.sh`

**Interfaces:**
- Consumes: Tasks 2–6.
- Produces: `openchamber-selfhost:dev` in the local Docker daemon for amd64.

- [ ] **Step 1: Write `scripts/build-local.sh`**

Signature: `build-local.sh [openchamber-version] [opencode-version] -> builds and tags openchamber-selfhost:dev`.

Behaviour: call `resolve-versions.sh` when versions are omitted, call `verify-artifacts.sh` into `./.cache/opencode`, then `docker buildx build --platform linux/amd64 --build-arg … --load -f docker/Dockerfile .`.

- [ ] **Step 2: Run it**

Run: `bash scripts/build-local.sh`
Expected: build completes; `docker image inspect openchamber-selfhost:dev --format '{{.Size}}'` prints a number < 1250000000.

- [ ] **Step 3: Assert size budget**

Add to the script: after build, fail if size > 1.2e9 bytes, printing the actual size. Re-run:
`bash scripts/build-local.sh`
Expected: exit 0 and a printed size in the 0.9–1.2 GB band.

- [ ] **Step 4: Commit**

```bash
git add scripts && git commit -m "feat: local build script with size budget"
```

---

### Task 8: Smoke test and fix what it finds

**Files:**
- Create: `scripts/smoke-test.sh`
- Test: the script itself, run against the built image.

**Interfaces:**
- Consumes: a running container name (default `oc-smoke`).
- Produces: exit 0 only when every check below passes.

- [ ] **Step 1: Write `scripts/smoke-test.sh`**

Signature: `smoke-test.sh [container-name]`. Checks, each printing `ok <name>`:
1. Runs as UID 1000: `docker exec … id -u` is `1000`.
2. OpenChamber root `GET :3000/` → 200.
3. `/health` contains `"openCodeRunning":true`.
4. `POST /auth/session` with the password → 200; with a wrong password → not authenticated.
5. `GET :4096/` → 200.
6. `GET :4096/api/info` with `-u opencode:<pw>` → 200; without → 401.
7. Terminal: open the terminal websocket, send a PTY spawn, assert `echo ok` output — or, if the websocket proves awkward, `docker exec` a `script -qec 'stty size' /dev/null` and assert rows/cols are non-zero.
8. Restart the container, re-check `/health`, then assert the settings file still exists in the mounted data dir.

- [ ] **Step 2: Run against the dev image**

```bash
docker run -d --name oc-smoke -e OPENCHAMBER_UI_PASSWORD=smokepw -p 13000:3000 -p 14096:4096 openchamber-selfhost:dev
bash scripts/smoke-test.sh oc-smoke
```

Expected: every line `ok …`, exit 0. Any failure is fixed in the owning file (Dockerfile or entrypoint) before moving on.

- [ ] **Step 3: Commit**

```bash
git add scripts && git commit -m "test: black-box smoke test for both UIs, auth, and terminal"
```

---

### Task 9: Release workflow

**Files:**
- Create: `.github/workflows/release.yml`

**Interfaces:**
- Consumes: `NPM_TOKEN`-free public registry reads; `GITHUB_TOKEN` with `packages: write`.
- Produces: `ghcr.io/<owner>/openchamber` tags `latest`, `2`, `2.7`, `2.7.3` (version-only, no OpenCode in the tag).

- [ ] **Step 1: Write the workflow**

Jobs, in order:
1. `resolve` — determine the target version: `workflow_dispatch` input, `repository_dispatch` payload, or the npm `latest`. Then `scripts/resolve-versions.sh`; expose both as outputs.
2. `skip` — `docker manifest inspect ghcr.io/<owner>/openchamber:<version>`; set `exists=true` so a re-run is a no-op (this is Review Focus 5).
3. `build` — matrix `[ubuntu-24.04 → amd64, ubuntu-24.04-arm → arm64]`, `needs: resolve`, `if: exists != 'true'`. Steps: checkout, `verify-artifacts.sh` into `dist/<arch>`, `docker/build-push-action` with `cache-from/cache-to type=gha`, `platforms: linux/<arch>`, `outputs: type=image,push-by-digest=true,name-canonical=true`, `sbom: true`, `provenance: mode=max`. Upload the digest as an artifact.
4. `merge` — download both digests, `docker buildx imagetools create` with `latest`, major, minor and exact-version tags.
5. `release-notes` — write a GitHub Release body naming both pinned versions and the image digest.

Triggers: `schedule: '0 */6 * * *'`, `workflow_dispatch` (optional `openchamber_version`, `opencode_version`), `repository_dispatch: types: [openchamber-release]`. Concurrency group `release` with `cancel-in-progress: false`.

- [ ] **Step 2: Validate YAML and logic locally**

Run: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/release.yml'))" && echo yaml ok`
Expected: `yaml ok`. Then dry-run the `resolve` job's commands locally with `act` if available, otherwise by executing the same `scripts/resolve-versions.sh` calls.

- [ ] **Step 3: Commit**

```bash
git add .github && git commit -m "ci: scheduled multi-arch release to ghcr"
```

---

### Task 10: CI workflow for pull requests

**Files:**
- Create: `.github/workflows/ci.yml`

- [ ] **Step 1: Write the workflow**

On `pull_request` and `push` to `main`: a `test` job (ubuntu-24.04) that runs every `scripts/test/*-test.sh`, then builds amd64 with `--load` (no push, `cache-from type=gha`), then runs `scripts/smoke-test.sh` against a container it starts.

- [ ] **Step 2: Validate locally**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yml'))" && echo yaml ok`
Expected: `yaml ok`, and `bash scripts/test/context-test.sh` etc. all still pass.

- [ ] **Step 3: Commit**

```bash
git add .github && git commit -m "ci: pr build, smoke test, and vulnerability scan"
```

---

### Task 11: Compose reference and README

**Files:**
- Create: `docker-compose.yml`
- Modify: `README.md`

- [ ] **Step 1: Write `docker-compose.yml`**

Two published ports, all six data volumes from the spec, `OPENCHAMBER_UI_PASSWORD: ${OPENCHAMBER_UI_PASSWORD:?set it}`, `restart: unless-stopped`, `healthcheck` inherited from the image.

- [ ] **Step 2: Write `README.md`**

Sections: what it is (one container, both UIs), quick start (`docker run` one-liner plus compose), the two URLs and what each is for, env var table, volume table, upgrade instructions (**pull the new image tag**; in-app update is intentionally not supported), arm64 note, troubleshooting (wrong UID, password unset, port in use), and a line stating this is an unofficial community image, not affiliated with either upstream project.

- [ ] **Step 3: Verify docs commands actually run**

Run the README's `docker run` command verbatim against the dev image, then `bash scripts/smoke-test.sh`.
Expected: passes, so the documented command is the tested command.

- [ ] **Step 4: Commit**

```bash
git add README.md docker-compose.yml && git commit -m "docs: compose reference and operator guide"
```

---

### Task 12: First real release

**Files:** none (operational).

- [ ] **Step 1: Push the repository to GitHub** and confirm Actions is enabled.
- [ ] **Step 2: Run `release.yml` via `workflow_dispatch`** with no overrides.
- [ ] **Step 3: Verify the published image**

```bash
docker buildx imagetools inspect ghcr.io/<owner>/openchamber:latest
docker run --rm ghcr.io/<owner>/openchamber:latest --help || true
docker pull --platform linux/arm64 ghcr.io/<owner>/openchamber:latest
```
Expected: the manifest lists both `linux/amd64` and `linux/arm64`; the arm64 pull succeeds.

- [ ] **Step 4: Confirm the guard works** — re-run the same workflow; the `skip` job reports `exists=true` and no new digest is pushed.

---

## Self-Review

**Spec coverage:** single container both UIs (T5–T6, T8), multi-arch (T9), auto-release (T9), passwords shared (T6), volumes (T11), health (T5, T8), non-root (T5, T8), no toolchain (T5 test), checksum-verified OpenCode (T3), version coupling (T2), tags (T9), update semantics (T11 docs). Non-goals respected: no Electron/VSCode/mobile, no source patching.

**Step scan:** every step names one file and one checkable result; no "handle edge cases" lines remain.

**Type consistency:** `resolve-versions.sh` output keys (`OPENCHAMBER_VERSION`, `OPENCODE_VERSION`) are the same names T9 consumes; `verify-artifacts.sh` arch vocabulary (`amd64`/`arm64`) matches `TARGETARCH`; entrypoint env names match T5's `EXPOSE`/health contract.

**Review Focus:** bind-mount UID (T5 user creation + T8 restart), password mirroring (T6 test), terminal after restart (T8 step 1.7/1.8), wrong-arch binary (T3 mapping + T9 native runners), duplicate/stale tag (T9 skip job).

**Proportion:** the plan is about the length of the spec; code blocks are the tests and the two shell contracts, not transcriptions of the Dockerfile.
