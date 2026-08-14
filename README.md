# openchamber-docker

Docker image for [OpenChamber](https://github.com/openchamber/openchamber), automatically rebuilt on every upstream release.

The image is built hourly by a GitHub Actions workflow: it checks the latest [OpenChamber release](https://github.com/openchamber/openchamber/releases) and pushes a new image to GHCR whenever a new version is published. Tags follow the upstream version, e.g. `v1.18.3`, and `latest` always points to the newest build.

## Usage

Pull the image:

```bash
docker pull ghcr.io/nxtgencat/openchamber:latest
```

Or run with Docker Compose:

```yaml
services:
  openchamber:
    image: ghcr.io/nxtgencat/openchamber:latest
    container_name: openchamber
    ports:
      - "3000:3000"
    extra_hosts:
      - "host.docker.internal:host-gateway"
    volumes:
      - ./data/openchamber:/home/openchamber/.config/openchamber
      - ./data/opencode/share:/home/openchamber/.local/share/opencode
      - ./data/opencode/state:/home/openchamber/.local/state/opencode
      - ./data/opencode/config:/home/openchamber/.config/opencode
      - ./data/ssh:/home/openchamber/.ssh
      - ./workspaces:/home/openchamber/workspaces
    environment:
      OPENCHAMBER_UI_PASSWORD: ${OPENCHAMBER_UI_PASSWORD:?Set OPENCHAMBER_UI_PASSWORD before exposing OpenChamber through Docker}
    restart: unless-stopped
```

### Quick start

```bash
OPENCHAMBER_UI_PASSWORD="$(openssl rand -base64 24)" docker compose up -d
```

Then open [http://localhost:3000](http://localhost:3000) and log in with the generated password.

> **Security note**: Docker binds the container to `0.0.0.0`, exposing OpenChamber to your whole network (and port mappings beyond localhost). UI auth is therefore mandatory — `OPENCHAMBER_UI_PASSWORD` is required and Compose will refuse to start without it.

## Configuration

| Environment variable              | Description                                                                                                  |
| --------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| `OPENCHAMBER_UI_PASSWORD`       | **Required.** Password for the web UI.                                                                 |
| `OPENCHAMBER_HOST`              | Bind address. The Docker entrypoint defaults to`0.0.0.0`.                                                  |
| `OPENCHAMBER_TUNNEL_PROVIDER`   | Tunnel provider, e.g.`cloudflare`.                                                                         |
| `OPENCHAMBER_TUNNEL_MODE`       | `quick` (default), `managed-remote`, or `managed-local`.                                               |
| `OPENCHAMBER_TUNNEL_HOSTNAME`   | Tunnel hostname, e.g.`app.example.com` (required for `managed-remote`).                                  |
| `OPENCHAMBER_TUNNEL_TOKEN`      | Cloudflare tunnel token (required for`managed-remote`).                                                    |
| `OPENCHAMBER_TUNNEL_CONFIG`     | Path to a tunnel config, e.g.`/home/openchamber/.cloudflared/config.yml` (optional for `managed-local`). |
| `OH_MY_OPENCODE`                | Set to`true` to enable oh-my-opencode.                                                                     |
| `OPENCODE_HOST`                 | Connect to an external OpenCode server, e.g.`http://172.17.0.1:4096`.                                      |
| `OPENCODE_SKIP_START`           | Set to`true` to skip starting OpenCode.                                                                    |
| `OPENCHAMBER_OPENCODE_HOSTNAME` | Bind OpenCode to all interfaces, e.g.`0.0.0.0`.                                                            |

### Volumes

| Host path                  | Container path                              | Purpose                        |
| -------------------------- | ------------------------------------------- | ------------------------------ |
| `./data/openchamber`     | `/home/openchamber/.config/openchamber`   | OpenChamber configuration      |
| `./data/opencode/share`  | `/home/openchamber/.local/share/opencode` | OpenCode shared data           |
| `./data/opencode/state`  | `/home/openchamber/.local/state/opencode` | OpenCode state                 |
| `./data/opencode/config` | `/home/openchamber/.config/opencode`      | OpenCode configuration         |
| `./data/ssh`             | `/home/openchamber/.ssh`                  | SSH keys (e.g. for git access) |
| `./workspaces`           | `/home/openchamber/workspaces`            | Your project workspaces        |

## Building from source

To build the image yourself:

```bash
docker build -t openchamber .
```

## License

See the upstream [OpenChamber repository](https://github.com/openchamber/openchamber) for license details.
