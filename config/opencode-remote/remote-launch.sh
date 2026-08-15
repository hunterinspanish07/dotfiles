#!/usr/bin/env bash
# remote-launch.sh — process owner for the opencode serve + telegram bridge stack.
# launchd (or ocremote) owns lifecycle; this script owns the two children and their
# join. When the bridge exits, serve is torn down with it — one unit, one fate.
# [LAW:decomposition] [LAW:single-enforcer]
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

APP_HOME="${OPENCODE_TG_HOME:-$HOME/Library/Application Support/opencode-telegram-bot}"
LOG_DIR="${OPENCODE_TG_LOG_DIR:-$APP_HOME/logs}"
ENV_FILE="$APP_HOME/.env"
mkdir -p "$LOG_DIR"

# [LAW:one-source-of-truth] port/URL live in the bot's .env; never hardcode a second copy.
API_URL="http://127.0.0.1:4096"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  set -a
  # Only pull the keys we need — never source secrets into a wider environment than required.
  # [LAW:effects-at-boundaries]
  API_URL=$(grep -E '^OPENCODE_API_URL=' "$ENV_FILE" | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'")
  set +a
  [[ -n "${API_URL:-}" ]] || API_URL="http://127.0.0.1:4096"
fi

# Health endpoint is the same origin the bot uses. [LAW:one-source-of-truth]
HEALTH_URL="${API_URL%/}/config"

die() { echo "ERROR: $*" >&2; exit 1; }

command -v opencode >/dev/null || die "opencode not on PATH"
command -v opencode-telegram >/dev/null || die "opencode-telegram not on PATH"
command -v curl >/dev/null || die "curl not on PATH"
[[ -f "$ENV_FILE" ]] || die "bot config missing: $ENV_FILE (run: opencode-telegram config)"

serve_healthy() {
  curl -sf --max-time 2 "$HEALTH_URL" >/dev/null 2>&1
}

# -s: prevent system sleep only on AC (battery still sleeps by design).
exec caffeinate -s bash -c '
  set -euo pipefail
  SERVE_PID=""
  OWNED_SERVE=0
  HEALTH_URL="'"$HEALTH_URL"'"
  API_URL="'"$API_URL"'"
  LOG_DIR="'"$LOG_DIR"'"

  cleanup() {
    if [[ "$OWNED_SERVE" -eq 1 && -n "$SERVE_PID" ]]; then
      kill "$SERVE_PID" 2>/dev/null || true
      wait "$SERVE_PID" 2>/dev/null || true
    fi
  }
  trap cleanup EXIT

  if curl -sf --max-time 2 "$HEALTH_URL" >/dev/null 2>&1; then
    echo "serve: reusing healthy server at $API_URL" >>"$LOG_DIR/serve.log"
  else
    # Parse host/port from API_URL without a second hardcoded default.
    # [LAW:one-source-of-truth]
    HOST=$(printf "%s" "$API_URL" | sed -E "s#https?://([^:/]+).*#\1#")
    PORT=$(printf "%s" "$API_URL" | sed -E "s#https?://[^:/]+:([0-9]+).*#\1#")
    [[ "$PORT" =~ ^[0-9]+$ ]] || PORT=4096
    [[ -n "$HOST" ]] || HOST=127.0.0.1

    opencode serve --port "$PORT" --hostname "$HOST" >>"$LOG_DIR/serve.log" 2>&1 &
    SERVE_PID=$!
    OWNED_SERVE=1

    # [LAW:no-ambient-temporal-coupling] wait for health, not a fixed sleep.
    ok=0
    for _ in $(seq 1 30); do
      if curl -sf --max-time 2 "$HEALTH_URL" >/dev/null 2>&1; then
        ok=1
        break
      fi
      # If serve died, fail loud instead of looping on a corpse. [LAW:no-silent-failure]
      if ! kill -0 "$SERVE_PID" 2>/dev/null; then
        echo "ERROR: opencode serve exited before becoming healthy (see $LOG_DIR/serve.log)" >&2
        exit 1
      fi
      sleep 1
    done
    if [[ "$ok" -ne 1 ]]; then
      echo "ERROR: opencode serve did not become healthy at $HEALTH_URL within 30s" >&2
      exit 1
    fi
  fi

  # Bridge in the foreground so launchd / the parent owns its lifetime.
  exec opencode-telegram start >>"$LOG_DIR/bot.log" 2>&1
'
