#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SETUP="$ROOT/mac-setup/heartwood-mac-setup.sh"
QA_ROOT="$(mktemp -d /private/tmp/heartwood-mac-install.XXXXXX)"
QA_HW="$QA_ROOT/heartwood-home"
QA_AGENTS="$QA_ROOT/agents"
QA_SUFFIX="qa0824"
QA_VNC_PORT=15900
QA_BRIDGE_PORT=15901
QA_WS_PORT=15902
UID_NUM="$(id -u)"

export HEARTWOOD_HOME_OVERRIDE="$QA_HW"
export HEARTWOOD_AGENTS_OVERRIDE="$QA_AGENTS"
export HEARTWOOD_AGENT_SUFFIX="$QA_SUFFIX"
export HEARTWOOD_VNC_PORT="$QA_VNC_PORT"
export HEARTWOOD_BRIDGE_PORT="$QA_BRIDGE_PORT"
export HEARTWOOD_WS_PORT="$QA_WS_PORT"

cleanup() {
  bash "$SETUP" --uninstall >/dev/null 2>&1 || true
  if [[ -n "${COLLISION_PID:-}" ]]; then
    kill "$COLLISION_PID" >/dev/null 2>&1 || true
    wait "$COLLISION_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "${FAKE_PID:-}" ]]; then
    kill "$FAKE_PID" >/dev/null 2>&1 || true
    wait "$FAKE_PID" >/dev/null 2>&1 || true
  fi
  rm -rf "$QA_ROOT"
}
trap cleanup EXIT

for port in "$QA_VNC_PORT" "$QA_BRIDGE_PORT" "$QA_WS_PORT"; do
  if lsof -nP -iTCP:"$port" -sTCP:LISTEN -t >/dev/null 2>&1; then
    printf 'test port already occupied: %s\n' "$port" >&2
    exit 1
  fi
done

python3 "$ROOT/tests/fake-vnc-probe.py" "$QA_VNC_PORT" &
FAKE_PID=$!
sleep 1

bash "$SETUP"
bash "$SETUP" --status

# A bare TCP open at websockify must stop at the WebSocket handshake and never
# reach the bridge (the release-checklist "port knock" boundary).
BRIDGE_LOG="$QA_HW/logs/com.heartwood.bridge.$QA_SUFFIX.log"
BEFORE_KNOCKS="$(grep -c 'bridge: client from' "$BRIDGE_LOG" 2>/dev/null || true)"
nc -z 127.0.0.1 "$QA_WS_PORT"
sleep 1
AFTER_KNOCKS="$(grep -c 'bridge: client from' "$BRIDGE_LOG" 2>/dev/null || true)"
test "$BEFORE_KNOCKS" = "$AFTER_KNOCKS"

bash "$SETUP"  # repair/idempotence pass

launchctl print "gui/$UID_NUM/com.heartwood.bridge.$QA_SUFFIX" | grep -q 'state = running'
launchctl print "gui/$UID_NUM/com.heartwood.websockify.$QA_SUFFIX" | grep -q 'state = running'
test -x "$QA_HW/venv/bin/websockify"
test -f "$QA_HW/vnc-bridge.py"
test -f "$QA_AGENTS/com.heartwood.bridge.$QA_SUFFIX.plist"
test -f "$QA_AGENTS/com.heartwood.websockify.$QA_SUFFIX.plist"

bash "$SETUP" --uninstall
! launchctl print "gui/$UID_NUM/com.heartwood.bridge.$QA_SUFFIX" >/dev/null 2>&1
! launchctl print "gui/$UID_NUM/com.heartwood.websockify.$QA_SUFFIX" >/dev/null 2>&1
test ! -e "$QA_HW"
test ! -e "$QA_AGENTS/com.heartwood.bridge.$QA_SUFFIX.plist"
test ! -e "$QA_AGENTS/com.heartwood.websockify.$QA_SUFFIX.plist"

# A foreign listener must produce a clear refusal, never a false-green install.
python3 -m http.server "$QA_BRIDGE_PORT" --bind 127.0.0.1 >/dev/null 2>&1 &
COLLISION_PID=$!
sleep 1
if COLLISION_OUTPUT="$(bash "$SETUP" 2>&1)"; then
  printf 'setup unexpectedly succeeded over an occupied bridge port\n' >&2
  exit 1
fi
grep -q "Port :$QA_BRIDGE_PORT is already in use" <<<"$COLLISION_OUTPUT"
kill "$COLLISION_PID" >/dev/null 2>&1 || true
wait "$COLLISION_PID" >/dev/null 2>&1 || true
COLLISION_PID=""

printf 'mac installer: fresh install, status, bare-knock, repair, collision refusal, launchd, and uninstall checks passed\n'
