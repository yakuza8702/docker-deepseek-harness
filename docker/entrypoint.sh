#!/usr/bin/env bash
# =====================================================================
# seek-harness entrypoint
#
#   docker run image                     -> DSH web + reverse proxy
#   docker run image web [extra args]    -> extra args forwarded to `dsh web`
#   docker run image --profile headless "task"
#                                        -> flags passed straight to `dsh`
#   docker run image bash                -> arbitrary command exec
#
# Docker engine access (this container's docker CLI):
#   * TCP proxy :  -e DOCKER_HOST=tcp://docker-proxy:2375
#   * socket    :  -v /var/run/docker.sock:/var/run/docker.sock
#                  + compose.docker.yaml override (group_add DOCKER_GID)
# =====================================================================
set -euo pipefail

DSH_PORT="${DSH_PORT:-3079}"
PROXY_PORT="${PROXY_PORT:-3080}"
PROXY_HOST="${PROXY_HOST:-0.0.0.0}"
DSH_NODE_FLAGS="${DSH_NODE_FLAGS---expose-internals}"
DSH_BIN="${DSH_BIN:-/usr/local/bin/dsh}"
PROXY_SCRIPT="${PROXY_SCRIPT:-/opt/seek-harness/proxy.mjs}"

log() { echo "[seek-harness] $*"; }
fatal() {
  echo "[seek-harness] FATAL: $*" >&2
  # never leave a half-started stack behind
  if [[ -n "${DSH_PID:-}" ]]; then
    kill -TERM "$DSH_PID" ${PROXY_PID:+"$PROXY_PID"} 2>/dev/null || true
  fi
  exit 1
}

if [[ "$DSH_PORT" == "$PROXY_PORT" ]]; then
  fatal "DSH_PORT (${DSH_PORT}) must differ from PROXY_PORT (${PROXY_PORT})."
fi

# ---------------------------------------------------------------------
# Docker access diagnostics (non-fatal — purely informational)
# ---------------------------------------------------------------------
if [[ -n "${DOCKER_HOST:-}" ]]; then
  log "docker: engine via TCP proxy — DOCKER_HOST=${DOCKER_HOST}"
elif [[ -S /var/run/docker.sock ]]; then
  if [[ -w /var/run/docker.sock ]]; then
    log "docker: /var/run/docker.sock is mounted and writable"
  else
    log "WARN: /var/run/docker.sock mounted but NOT writable by uid=$(id -u)."
    log "      Fix: compose.docker.yaml override with group_add: [\"${DOCKER_GID:-999}\"]"
    log "      (run 'stat -c %g /var/run/docker.sock' on the HOST to get the gid)."
  fi
else
  log "docker: no DOCKER_HOST and no /var/run/docker.sock — CLI available, no engine access (ok if unintended)"
fi

# ---------------------------------------------------------------------
# Arg dispatch
# ---------------------------------------------------------------------
cmd="${1:-web}"

if [[ "$cmd" != "web" ]]; then
  if [[ "$cmd" == -* ]]; then
    log "forwarding flags to dsh: dsh $*"
    # DSH main process gets the same node flags as the web stack
    declare -a _nf=()
    [[ -n "$DSH_NODE_FLAGS" ]] && read -r -a _nf <<< "$DSH_NODE_FLAGS"
    exec node "${_nf[@]}" "$DSH_BIN" "$@"
  else
    log "exec: $*"
    exec "$@"
  fi
fi
shift || true

# ---------------------------------------------------------------------
# Start the stack: DSH on loopback + proxy on 0.0.0.0 (the 0.0.0.0 fix)
# ---------------------------------------------------------------------
declare -a trusted_args=()
if [[ -n "${DSH_TRUSTED_HOSTS:-}" ]]; then
  IFS=',' read -r -a _hosts <<< "$DSH_TRUSTED_HOSTS"
  for h in "${_hosts[@]}"; do
    h="${h#"${h%%[![:space:]]*}"}"; h="${h%"${h##*[![:space:]]}"}"
    [[ -n "$h" ]] && trusted_args+=(--trusted-host "$h")
  done
fi

declare -a node_flags=()
[[ -n "$DSH_NODE_FLAGS" ]] && read -r -a node_flags <<< "$DSH_NODE_FLAGS"

log "starting DSH web on 127.0.0.1:${DSH_PORT} (DSH_HOME=${DSH_HOME:-unset}, HOME=${HOME})"
node "${node_flags[@]}" "$DSH_BIN" web \
  --no-open --host 127.0.0.1 --port "$DSH_PORT" \
  ${trusted_args[@]+"${trusted_args[@]}"} "$@" &
DSH_PID=$!

log "starting reverse proxy on ${PROXY_HOST}:${PROXY_PORT}"
node "$PROXY_SCRIPT" &
PROXY_PID=$!

terminate() {
  log "signal received — stopping DSH (${DSH_PID}) and proxy (${PROXY_PID})"
  kill -TERM "$DSH_PID" "$PROXY_PID" 2>/dev/null || true
}
trap terminate TERM INT

# Wait for DSH to accept HTTP on its loopback port (profile boot can take a while)
for i in $(seq 1 120); do
  if curl -s -o /dev/null "http://127.0.0.1:${DSH_PORT}/"; then
    break
  fi
  if ! kill -0 "$DSH_PID" 2>/dev/null; then
    fatal "dsh exited during startup (exit=$?) — check logs above"
  fi
  sleep 1
done

AUTH_STATE="OFF"
[[ -n "${PROXY_USERNAME:-}" && -n "${PROXY_PASSWORD:-}" ]] && AUTH_STATE="ON"

# Bail out early (rather than printing a misleading ready banner) if either
# process died while we were waiting for DSH to boot.
if ! kill -0 "$DSH_PID" 2>/dev/null; then fatal "dsh exited during startup — check logs above"; fi
if ! kill -0 "$PROXY_PID" 2>/dev/null; then fatal "proxy exited during startup — check logs above"; fi

log "=============================================================="
log " DeepSeek Harness is ready (no browser stack included)"
log "   local : http://127.0.0.1:${PROXY_PORT}/"
log "   LAN   : http://<host-ip>:${PROXY_PORT}/   (basic auth: ${AUTH_STATE})"
log "   WS channels are forwarded automatically by the proxy"
log "   DSH pid=${DSH_PID}  proxy pid=${PROXY_PID}"
log "=============================================================="

# Supervise: if either process exits, stop the other and propagate status.
set +e
wait -n "$DSH_PID" "$PROXY_PID"
status=$?
log "a managed process exited (status=${status}) — shutting down"
terminate
wait "$DSH_PID" "$PROXY_PID" 2>/dev/null
exit "$status"
