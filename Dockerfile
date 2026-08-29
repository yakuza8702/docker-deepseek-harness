# syntax=docker/dockerfile:1
# =====================================================================
# seek-harness — hardened DeepSeek Harness container
#
# Provenance:
#   * Official upstream : @deepseek-ai/dsh npm package (deepseek-ai/deepseek-harness)
#   * smanx             : complete devtools package set + the "0.0.0.0 fix"
#                         (built-in Node reverse proxy 0.0.0.0 -> 127.0.0.1 with
#                         HTTP+WS forwarding, optional Basic Auth, and a
#                         crypto.randomUUID polyfill for non-secure LAN pages)
#   * runzhliu          : security hardening (non-root UID 1000, tini, fixed
#                         pnpm, build-time version pin+verify, HOME=/workspace
#                         dir-selector fix, --expose-internals only for the DSH
#                         main process). NO Chromium/Xvfb/noVNC browser stack.
#   * This repo         : Docker access — pass a mounted docker.sock (with
#                         group_add) OR a Docker proxy over TCP via
#                         DOCKER_HOST env var. docker CLI + compose plugin
#                         included.
#
# Base: node:24-trixie (Debian 13, glibc 2.41, non-slim buildpack-deps) —
# chosen by runzhliu so newer prebuilt agent binaries keep working.
# =====================================================================

ARG NODE_IMAGE=node:24-trixie

# ---------------------------------------------------------------------
# Stage 1 — obtain the OFFICIAL DeepSeek Harness release, pin and verify
# the exact version at build time (runzhliu pattern).
#
# Two channels (see README "Release channels"):
#   DSH_SOURCE_REF=""           -> npm channel: install @deepseek-ai/dsh
#                                  <DSH_VERSION> from the npm registry
#                                  (DEFAULT — what runzhliu & smanx do)
#   DSH_SOURCE_REF=<github tag> -> source channel: clone the official repo
#                                  at that tag (e.g. dsh-v0.1.2-alpha.1)
#                                  and build the monorepo. For GitHub
#                                  pre-releases/alphas that are not (yet)
#                                  published to npm. Slower, larger image.
# ---------------------------------------------------------------------
FROM ${NODE_IMAGE} AS dsh-fetch
ARG DSH_VERSION=latest
ARG DSH_SOURCE_REF
WORKDIR /opt/dsh
RUN mkdir -p /opt/dsh /src

# npm channel
RUN if [ -z "${DSH_SOURCE_REF}" ]; then \
      npm init -y >/dev/null 2>&1 \
   && npm install --omit=dev --no-audit --no-fund "@deepseek-ai/dsh@${DSH_VERSION}" \
   && node -p "require('/opt/dsh/node_modules/@deepseek-ai/dsh/package.json').version" > /opt/dsh/.dsh-version \
   && echo "fetched @deepseek-ai/dsh $(cat /opt/dsh/.dsh-version) (npm)" \
   && /opt/dsh/node_modules/.bin/dsh --version; \
    fi

# source channel (github tag, incl. pre-releases/alphas missing from npm)
RUN if [ -n "${DSH_SOURCE_REF}" ]; then \
      apt-get update && apt-get install -y --no-install-recommends git python3 \
   && rm -rf /var/lib/apt/lists/* \
   && git clone --depth 1 --branch "${DSH_SOURCE_REF}" https://github.com/deepseek-ai/deepseek-harness.git /src \
   && npm install -g --no-audit --no-fund pnpm@10 \
   && cd /src \
   && (pnpm install --frozen-lockfile || pnpm install) \
   && pnpm run build \
   && node -p "require('/src/package.json').version" > /src/.dsh-version \
   && echo "built @deepseek-ai/dsh $(cat /src/.dsh-version) (source ${DSH_SOURCE_REF})" \
   && node /src/apps/cli/lib/bin.js --version; \
    fi

# ---------------------------------------------------------------------
# Stage 2 — runtime
# ---------------------------------------------------------------------
FROM ${NODE_IMAGE}
ARG DSH_VERSION=latest
ARG DSH_SOURCE_REF
ARG PNPM_VERSION=10
ARG TARGETARCH=amd64
LABEL org.opencontainers.image.title="seek-harness" \
      org.opencontainers.image.description="Hardened DeepSeek Harness container — smanx devtools + 0.0.0.0 reverse-proxy fix + runzhliu hardening + docker.sock/TCP support, no browser" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.source="https://github.com/yakuza8702/docker-deepseek-harness" \
      org.opencontainers.image.version="${DSH_VERSION}"

ENV NPM_CONFIG_CACHE=/tmp/.npm-cache \
    NPM_CONFIG_UPDATE_NOTIFIER=false

# smanx devtools-latest package set (merged with runzhliu extras):
#   smanx devtools-latest : git curl wget nano jq procps ca-certificates unzip
#                           vim openssh-client zip htop tmux tree openssl
#                           python3 build-essential bash-completion + pnpm + uv
#   runzhliu extras       : less ripgrep rsync (build-essential/git/curl/...
#                           already ship inside node:24-trixie buildpack-deps)
#   this build            : docker-ce-cli + docker-compose-plugin (socket/TCP
#                           engine access), tini (init, orphan reaping),
#                           bubblewrap (DSH Linux bwrap sandbox backend)
RUN set -eux; \
    install -m 0755 -d /etc/apt/keyrings; \
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc; \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian trixie stable" \
      > /etc/apt/sources.list.d/docker.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      nano jq unzip vim zip htop tmux tree openssl python3 bash-completion \
      less ripgrep rsync procps ca-certificates \
      tini bubblewrap \
      docker-ce-cli docker-compose-plugin; \
    rm -rf /var/lib/apt/lists/*

# uv (static binary) — many community DSH MCP servers launch via "uvx"
RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin UV_NO_MODIFY_PATH=1 sh \
 && uv --version

# pnpm pinned at build (required by `dsh plugin ...` and plugin marketplaces)
RUN npm install -g --no-audit --no-fund "pnpm@${PNPM_VERSION}" \
 && pnpm --version

# Official DSH release from stage 1 + CLI on PATH (version re-verified here).
#   npm channel    -> /opt/dsh/node_modules/.bin/dsh
#   source channel -> /opt/dsh-src (cloned + built monorepo incl. node_modules)
COPY --from=dsh-fetch /opt/dsh /opt/dsh
COPY --from=dsh-fetch /src /opt/dsh-src
RUN if [ -f /opt/dsh/node_modules/.bin/dsh ]; then \
      ln -sfn /opt/dsh/node_modules/.bin/dsh /usr/local/bin/dsh \
   && echo "installed @deepseek-ai/dsh $(cat /opt/dsh/.dsh-version) (npm)"; \
    else \
      ln -sfn /opt/dsh-src/apps/cli/lib/bin.js /usr/local/bin/dsh \
   && echo "installed @deepseek-ai/dsh $(cat /opt/dsh-src/.dsh-version) (source)"; \
    fi \
 && dsh --version

# Landlock launcher binary. The source-channel monorepo links the workspace
# package native/landlock-run/packages/linux-<arch> but its bin/ only ships in
# the published platform npm package (the npm channel gets it automatically via
# optionalDependencies). Without this file DSH's sandbox probes unusable and
# workspace-write/read-only permission modes fail closed. Fetching the binary
# restores real sandboxing WITHOUT relaxing the container seccomp profile.
RUN if [ -n "${DSH_SOURCE_REF}" ]; then \
      P="linux-${TARGETARCH}"; D="/opt/dsh-src/native/landlock-run/packages/$P"; \
      if [ -d "$D" ] && [ ! -x "$D/bin/landlock-run" ]; then \
        V=$(node -p "require('$D/package.json').version" 2>/dev/null || echo latest); \
        cd /tmp && { \
          T=$(npm pack --silent "@deepseek-ai/node-addon-landlock-run-$P@${V}" | tail -n1) \
          && tar xzf "$T" package/bin/landlock-run \
          && mkdir -p "$D/bin" \
          && install -m 755 package/bin/landlock-run "$D/bin/landlock-run" \
          && rm -rf /tmp/package "/tmp/$T" \
          && echo "landlock launcher installed ($P ${V})"; \
        } || echo "WARNING: landlock launcher install failed - sandbox modes unavailable at runtime"; \
      fi; \
    fi

# Reverse proxy ("0.0.0.0 fix", smanx pattern) + entrypoint
COPY docker/proxy.mjs docker/entrypoint.sh /opt/seek-harness/
RUN chmod 0755 /opt/seek-harness/proxy.mjs /opt/seek-harness/entrypoint.sh \
 && ln -sfn /opt/seek-harness/entrypoint.sh /usr/local/bin/entrypoint.sh

ENV NODE_ENV=production \
    DSH_HOME=/home/node/.dsh \
    HOME=/workspace \
    DSH_PORT=3079 \
    PROXY_PORT=3080 \
    PROXY_HOST=0.0.0.0 \
    DSH_TELEMETRY_DISABLED=1

WORKDIR /workspace
RUN mkdir -p /workspace /home/node/.dsh \
 && chown -R node:node /home/node/.dsh /workspace /opt/seek-harness

# Non-root (runzhliu hardening): uid/gid 1000 = image "node" user
USER node:node

# entrypoint handles: `web` (default), `-`-prefixed dsh args, or arbitrary exec
ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["web"]

# Healthcheck probes the public proxy port; 502 while DSH is still booting.
HEALTHCHECK --interval=30s --timeout=5s --start-period=90s --retries=5 \
  CMD curl -s -o /dev/null "http://127.0.0.1:${PROXY_PORT}/" || exit 1
