# OpenChamber self-host image

One container that runs **OpenChamber** and **OpenCode** together, for amd64 and arm64.
OpenChamber drives and supervises OpenCode, so both work out of the box — including the
terminal, sessions, search, git, and SSH.

| Port | What |
| --- | --- |
| `3000` | OpenChamber UI and API (the one you normally open) |
| `4096` | OpenCode's own web UI and API |

Both are protected by the same password.

> Unofficial community image. Not affiliated with the OpenChamber or OpenCode projects.

## Quick start

```bash
docker run -d --name openchamber \
  -p 3000:3000 -p 4096:4096 \
  -e OPENCHAMBER_UI_PASSWORD='change-me' \
  -v openchamber-config:/home/openchamber/.config/openchamber \
  -v opencode-data:/home/openchamber/.local/share/opencode \
  ghcr.io/<user>/openchamber:latest
```

Open <http://localhost:3000> and sign in with the password you set.

### With compose

```bash
export OPENCHAMBER_UI_PASSWORD="$(openssl rand -base64 24)"
docker compose up -d
docker compose logs -f
```

Then open <http://localhost:3000>.

## Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `OPENCHAMBER_UI_PASSWORD` | **required** | Password for both UIs. The container refuses to start without it. |
| `OPENCHAMBER_PORT` | `3000` | OpenChamber's internal port. |
| `OPENCODE_PORT` | `4096` | OpenCode's internal port. |
| `PUID` / `PGID` | `1000` / `1000` | uid/gid the app runs as. Set these to your host user when it is not 1000. |

Provider keys (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GEMINI_API_KEY`, …) are read by
OpenCode. Pass them the same way:

```bash
docker run -d -e ANTHROPIC_API_KEY=... -e OPENCHAMBER_UI_PASSWORD=... ...
```

## Volumes

| Container path | Contents |
| --- | --- |
| `/home/openchamber/.config/openchamber` | OpenChamber settings, themes, passkeys, JWT secret |
| `/home/openchamber/.local/share/opencode` | Sessions, database, provider logins |
| `/home/openchamber/.local/state/opencode` | OpenCode state |
| `/home/openchamber/.config/opencode` | OpenCode config (`opencode.json`, agents, skills) |
| `/home/openchamber/.ssh` | Git SSH keys |
| `/home/openchamber/workspaces` | Your projects |

The named volumes in the quick start persist settings and sessions. Mount specific
directories instead if you prefer to see the files.

### Ownership

The container starts as root, makes the mounted directories writable, then drops
to uid `1000` for both servers. Nothing serves traffic as root.

If your host user is not `1000`, set the ids and the entrypoint will use them:

```bash
docker run -d -e PUID=$(id -u) -e PGID=$(id -g) ...
```

Directories you bind-mount are chowned to that uid on start. `./workspaces` is
only chowned at its top level, so a large checkout is not walked on every boot.

## Upgrading

Pull the new tag and recreate the container:

```bash
docker compose pull && docker compose up -d
```

Do not use the in-app updater. It is built for a mutable npm install and cannot
replace an image layer; this image pins its versions on purpose. A new upstream
release appears as a new image tag within six hours of publishing.

## Tags

Tags carry the OpenChamber version and nothing else.

| Tag | Meaning |
| --- | --- |
| `latest` | Newest release |
| `2` | Newest `2.x` |
| `2.7` | Newest `2.7.x` |
| `2.7.3` | That exact release |

Every tag is the same multi-arch manifest, so pinning an exact version is the
reproducible choice. The OpenCode build it shipped with is recorded in the
`dev.openchamber.opencode.version` label and in the release notes, not in the tag.

## Verifying a release

```bash
docker buildx imagetools inspect ghcr.io/<user>/openchamber:latest
```

The manifest lists both `linux/amd64` and `linux/arm64`. The release notes record
which OpenCode version was bundled, and the image carries it in the
`dev.openchamber.opencode.version` label:

```bash
docker image inspect ghcr.io/<user>/openchamber:2.7.3 \
  --format '{{index .Config.Labels "dev.openchamber.opencode.version"}}'
```

## Troubleshooting

**Container exits with `OPENCHAMBER_UI_PASSWORD is required`.**
Set the variable. The image binds `0.0.0.0`, so it will not run unauthenticated.

**Permission denied writing to a mounted directory.**
The entrypoint fixes ownership on start. If it still fails, the mount is not
writable by root (NFS root-squash, read-only bind); `chown -R 1000:1000` it on the
host, or set `PUID`/`PGID` to the uid that owns it.

**Port 4096 already in use.**
Another OpenCode instance is running. Stop it, or change the published port with
`-p 14096:4096` and open that instead.

**`/health` says `openCodeRunning: false`.**
OpenCode failed to start. `docker logs <container>` shows the reason, usually a bad
config in `.config/opencode`.

**The UI loads but sessions are empty after an upgrade.**
Check that the `share` volume is still mounted at
`/home/openchamber/.local/share/opencode`.

## License

MIT. Both upstream projects are MIT-licensed.
