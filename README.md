# seek-harness

A self-built, hardened **DeepSeek Harness (DSH)** container image.

It packages the **official npm release** of [`@deepseek-ai/dsh`](https://github.com/deepseek-ai/deepseek-harness) and combines the best of the two unofficial reference builds — **without** runzhliu's browser stack:

| Input | What is taken |
|---|---|
| **official** [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness) | `@deepseek-ai/dsh` npm package, pinned + verified at build time |
| **smanx** [`devtools-latest`](https://hub.docker.com/r/smanx/deepseek-harness) | complete devtools package set **+ the "0.0.0.0 fix"**: built-in Node reverse proxy (`0.0.0.0:3080 → 127.0.0.1:DSH_PORT`) with HTTP+WS forwarding, optional Basic Auth, `crypto.randomUUID` polyfill for non-secure LAN pages |
| **runzhliu** [deepseek-harness-docker](https://github.com/runzhliu/deepseek-harness-docker) | security hardening: non-root UID 1000, `tini` init, fixed pnpm, build-time version verification, `HOME=/workspace` dir-selector fix, `--expose-internals` only on the DSH main process, cap_drop ALL / no-new-privileges / read-only rootfs in compose. **NOT taken:** Chromium / Xvfb / noVNC / `@runzhliu/dsh-browser-desktop` (no browser) |
| **this repo** | Docker engine access: mounted `docker.sock` **or** Docker proxy over TCP via `DOCKER_HOST`; docker CLI + compose plugin inside the image; GitHub workflow that auto-follows the official repo and keeps `:latest` current |

## Why a reverse proxy? (the 0.0.0.0 fix)

`dsh web` serves `http://127.0.0.1:3080` and the CLI **intentionally refuses `--host 0.0.0.0`** (anti unauthenticated-RCE measure). A container port forward needs a non-loopback listener, so this image keeps DSH on `127.0.0.1:$DSH_PORT` inside the container and exposes a zero-dependency Node reverse proxy on `$PROXY_HOST:$PROXY_PORT` (smanx approach) that provides:

- HTTP **and** WebSocket forwarding (`/api/events.mux`, `/api/events.host`, ...)
- optional **HTTP Basic Auth** (enabled when `PROXY_USERNAME` *and* `PROXY_PASSWORD` are set; applies to HTTP and WS; `/manifest.webmanifest`, `/favicon.svg`, `/favicon.ico` are bypassed)
- a **`crypto.randomUUID` polyfill** injected into served HTML — pages opened over a LAN IP are a browser *non-secure context* where `randomUUID` is unavailable, which otherwise leaves the realtime WS channel pending forever
- `Host` rewritten to the loopback authority so DSH's `/api` browser-trust fence treats proxied traffic as local (add real authorities via `DSH_TRUSTED_HOSTS` when fronting with your own authenticated proxy)

## Quick start (compose)

```bash
cp .env.example .env            # edit: workspace path, bind, auth, docker access
docker compose pull
DSH_WORKSPACE=/abs/path/to/project docker compose up -d
# open http://127.0.0.1:3080/
```

## Quick start (plain docker run)

```bash
docker pull ghcr.io/OWNER/REPO:latest

docker run -d --name seek-harness \
  -p 3080:3080 \
  -v seek-harness-home:/home/node/.dsh \
  -v "$PWD":/workspace \
  --restart unless-stopped \
  ghcr.io/OWNER/REPO:latest
```

Other entrypoint forms:

```bash
# flags go straight to dsh (headless one-shot)
docker run --rm -v "$PWD":/workspace ghcr.io/OWNER/REPO:latest \
  --profile headless "summarize this repository"

# arbitrary command (shell into the devtools image)
docker run --rm -it --entrypoint bash ghcr.io/OWNER/REPO:latest
```

## Docker engine access (agent can run docker)

**Option A — Docker proxy over TCP (preferred):** point `DOCKER_HOST` at a filtered socket proxy, e.g. [tecnativa/docker-socket-proxy](https://hub.docker.com/r/tecnativa/docker-socket-proxy):

```yaml
# .env
DOCKER_HOST=tcp://docker-socket-proxy:2375
```

**Option B — host docker.sock:**

```bash
# on the HOST: get the docker group gid
stat -c %g /var/run/docker.sock     # e.g. 999

# .env
DOCKER_GID=999

# then run with the override
docker compose -f compose.yaml -f compose.docker.yaml up -d
```

> ⚠️ Mounting `docker.sock` is root-equivalent access to the host daemon. The TCP-proxy route with a filtered proxy is the safer pattern. Both keep the rest of the hardening intact (the docker CLI needs no capabilities).

Inside the container: `docker ps`, `docker compose version`, `docker build ...` all work via socket **or** `DOCKER_HOST`.

## Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `PROXY_PORT` | `3080` | Public proxy port (the only listening surface) |
| `DSH_PORT` | `3079` | DSH loopback port inside the container (must differ) |
| `PROXY_HOST` | `0.0.0.0` | Proxy bind address inside the container |
| `PROXY_USERNAME` / `PROXY_PASSWORD` | unset | Basic Auth (HTTP+WS); enabled only when **both** set |
| `PROXY_INJECT_POLYFILL` | `1` | Inject the `crypto.randomUUID` polyfill into HTML |
| `DSH_TRUSTED_HOSTS` | empty | Comma-list of extra `host[:port]` authorities for DSH's `/api` trust fence (advanced, behind your own auth proxy) |
| `DOCKER_HOST` | unset | Docker proxy over TCP (e.g. `tcp://socket-proxy:2375`) |
| `DOCKER_GID` | `999` | Host docker group gid for the `compose.docker.yaml` override |
| `DSH_WORKSPACE` | `./workspace` | Compose-only: workspace bind source |
| `DSH_BIND` | `127.0.0.1` | Compose-only: host publish address (`0.0.0.0` = LAN) |
| `DEEPSEEK_API_KEY` | unset | Runtime credential (or configure in the Web UI settings) |
| `DSH_TELEMETRY_DISABLED` | `1` | Hard-disabled locally by default (empty = upstream default) |
| `DSH_PERMISSION_MODE` | unset | `read-only` / `workspace-write` / `danger-full-access` |
| `DSH_TOOLS_MODE` | unset | `native` / `ptc` / `both` |
| `DSH_NODE_FLAGS` | `--expose-internals` | Node flags for the DSH main process only (agent children don't inherit) |

## What's inside (smanx devtools-latest set)

`git` `curl` `wget` `nano` `jq` `less` `ripgrep` `rsync` `procps` `ca-certificates` `unzip` `vim` `zip` `htop` `tmux` `tree` `openssl` `python3` `bash-completion` `build-essential` (via base image) · npm globals: **pnpm** (pinned) · **uv** (`uvx` for MCP servers) · **docker CLI + compose plugin** · `tini` · `bubblewrap` (DSH Linux sandbox backend)

No browser: no Chromium, no Xvfb, no noVNC, no `dsh-browser-desktop` plugin. DSH is launched with `--no-open` so it never tries to open a host browser.

## Auto-update workflow

`.github/workflows/docker-build.yml` keeps `:latest` in sync with the official repo:

- **every 6h** (cron) it resolves `dist-tags.latest` of `@deepseek-ai/dsh` on npm — the official release channel (`npx @deepseek-ai/dsh web`) — and compares it against what's already on GHCR
- build key = `dsh <version>` + this repo's commit SHA → rebuilds only when **either** upstream releases a new version **or** this repo's Dockerfile changes
- pushes `linux/amd64` + `linux/arm64` to `ghcr.io/<owner>/<repo>` with tags `latest`, `dsh-<version>`, `build-<version>-<sha8>`
- manual **Run workflow** button always available (`force_build` to bypass the skip check)
- uses only the built-in `GITHUB_TOKEN` — no secrets needed

Point your docker manager (watchtower/Portainer/etc.) at `ghcr.io/OWNER/REPO:latest` and it will pick up every upstream update.

## Security model

- **Non-root** (uid/gid 1000), rootfs read-only, `cap_drop: ALL`, `no-new-privileges`, `/tmp` tmpfs — in the provided `compose.yaml`
- DSH state (profiles/credentials/sessions/plugins) persists in the `dsh-home` volume at `/home/node/.dsh`; only `/workspace` (the agent's world) is a bind mount
- The Web UI has **no auth of its own and can execute code** — it is a single-user, localhost tool. For LAN use set `DSH_BIND=0.0.0.0` **and** Basic Auth; never expose to the public internet
- Docker socket access is opt-in and widens the trust boundary — prefer the filtered TCP proxy

## Smoke test

```bash
docker run --rm --entrypoint dsh ghcr.io/OWNER/REPO:latest --version   # prints pinned DSH version
docker run --rm --entrypoint bash ghcr.io/OWNER/REPO:latest -c \
  'docker --version && docker compose version && pnpm --version && uv --version && bwrap --version'
docker compose up -d && curl -fsS http://127.0.0.1:3080/ && docker compose ps   # healthy
```

## After adding the git remote

Replace the `OWNER/REPO` placeholders (`grep -rn "OWNER/REPO" .` → README, compose.yaml, Dockerfile LABEL) with your real `ghcr.io/<owner>/<repo>`. The workflow itself derives the image name from `github.repository`, so it needs no edits.

## Credits

- [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness) — the official project (MIT)
- [runzhliu/deepseek-harness-docker](https://github.com/runzhliu/deepseek-harness-docker) — hardening patterns
- [smanx/deepseek-harness](https://hub.docker.com/r/smanx/deepseek-harness) — devtools package set + reverse-proxy "0.0.0.0 fix"
