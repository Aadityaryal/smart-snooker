#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Smart Snooker — one-click launcher.
#
# Starts the ML recommendation server (FastAPI/uvicorn), waits until it is ready,
# launches the game, and shuts the server down again when the game closes.
#
# This is the single entry point: run ./run_smart_snooker.sh and play. No need to
# start the Python server separately.
#
# Note: venv lives at the PROJECT ROOT (not inside recommendation-engine), so the
# server is started with an absolute python path and uvicorn --app-dir.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="$ROOT/venv/bin/python"
ENGINE="$ROOT/recommendation-engine"
GAME="$ROOT/recommendation-engine/smart_snooker.x86_64/smart_snooker.x86_64"
PORT="${SMART_SNOOKER_PORT:-8000}"
HEALTH="http://127.0.0.1:$PORT/health"

echo "── Smart Snooker ─────────────────────────────────────────"

if [ ! -x "$PY" ]; then
    echo "ERROR: Python venv not found at: $PY"
    echo "Create the environment, then: \"$PY\" -m pip install -r \"$ROOT/requirements.txt\""
    exit 1
fi

SERVER_PID=""
cleanup() {
    if [ -n "$SERVER_PID" ]; then
        echo "Stopping ML server (pid $SERVER_PID)…"
        kill "$SERVER_PID" 2>/dev/null
    fi
}
trap cleanup EXIT INT TERM

# Start the server only if one isn't already up on this port.
if curl -sf -m 2 "$HEALTH" >/dev/null 2>&1; then
    echo "ML server already running on port $PORT."
else
    echo "Starting ML server…"
    "$PY" -m uvicorn api.main:app --app-dir "$ENGINE" \
        --host 127.0.0.1 --port "$PORT" >"$ROOT/server.log" 2>&1 &
    SERVER_PID=$!
fi

# Wait for /health (up to ~15 s).
echo -n "Waiting for ML server"
UP=0
for _ in $(seq 1 30); do
    if curl -sf -m 2 "$HEALTH" >/dev/null 2>&1; then UP=1; echo " ready."; break; fi
    echo -n "."
    sleep 0.5
done
if [ "$UP" != 1 ]; then
    echo " not ready — the game will show an offline notice. See: $ROOT/server.log"
fi

# Launch the game: prefer the exported binary; fall back to running from source.
if [ -x "$GAME" ]; then
    echo "Launching game…"
    "$GAME"
elif command -v godot >/dev/null 2>&1; then
    echo "Exported binary not found — launching from source via godot…"
    godot --path "$ROOT/gamified-system"
else
    echo "ERROR: no game binary at $GAME, and 'godot' is not on PATH."
    exit 1
fi
