#!/bin/bash
# ============================================================================
# Heartwood VNC — Mac setup (the one command)
#
#   ./heartwood-mac-setup.sh            install / repair
#   ./heartwood-mac-setup.sh --status   show what's running
#   ./heartwood-mac-setup.sh --uninstall  remove everything cleanly
#
# What it does (all inside ~/.heartwood — nothing touches your system):
#   1. Checks Screen Sharing is on (walks you through it if not — that's a
#      security setting only YOU can flip; we never automate those).
#   2. Verifies the "VNC viewers may control screen with password" option by
#      actually speaking the VNC protocol to your Mac and checking it offers
#      classic password auth.
#   3. Installs a tiny relay pair, kept alive across reboots by launchd:
#        websockify  :5902 → :5901   (WebSocket door the viewer app knocks on)
#        auth bridge :5901 → :5900   (pass-through — stores NO password;
#                                     your Mac alone judges every login)
#   4. Tells you your Mac's name — the one thing you type into Heartwood VNC
#      on your PC, along with the password YOU set in System Settings.
#
# Test mode (developer): HEARTWOOD_WS_PORT / HEARTWOOD_BRIDGE_PORT /
# HEARTWOOD_VNC_PORT / HEARTWOOD_AGENT_SUFFIX / HEARTWOOD_HOME_OVERRIDE /
# HEARTWOOD_AGENTS_OVERRIDE let a disposable test install run beside a
# production one.
# ============================================================================
set -euo pipefail

HW_HOME="${HEARTWOOD_HOME_OVERRIDE:-$HOME/.heartwood}"
WS_PORT="${HEARTWOOD_WS_PORT:-5902}"
BRIDGE_PORT="${HEARTWOOD_BRIDGE_PORT:-5901}"
VNC_PORT="${HEARTWOOD_VNC_PORT:-5900}"
AGENT_SUFFIX="${HEARTWOOD_AGENT_SUFFIX:-}"
[[ "$AGENT_SUFFIX" =~ ^[A-Za-z0-9-]*$ ]] || { printf '  ❌ Invalid HEARTWOOD_AGENT_SUFFIX.\n' >&2; exit 1; }
LABEL_BRIDGE="com.heartwood.bridge${AGENT_SUFFIX:+.$AGENT_SUFFIX}"
LABEL_WS="com.heartwood.websockify${AGENT_SUFFIX:+.$AGENT_SUFFIX}"
AGENTS="${HEARTWOOD_AGENTS_OVERRIDE:-$HOME/Library/LaunchAgents}"
UID_NUM="$(id -u)"

say()  { printf '%s\n' "$*"; }
ok()   { printf '  ✅ %s\n' "$*"; }
warn() { printf '  ⚠️  %s\n' "$*"; }
die()  { printf '  ❌ %s\n' "$*" >&2; exit 1; }
agent_loaded() { launchctl print "gui/$UID_NUM/$1" >/dev/null 2>&1; }
agent_running() { launchctl print "gui/$UID_NUM/$1" 2>/dev/null | grep -q 'state = running'; }
port_listener() { lsof -nP -iTCP:"$1" -sTCP:LISTEN -t 2>/dev/null | head -n 1 || true; }

# ---------------------------------------------------------------- uninstall
if [[ "${1:-}" == "--uninstall" ]]; then
  say "Removing Heartwood from this Mac…"
  launchctl bootout "gui/$UID_NUM/$LABEL_BRIDGE" 2>/dev/null && ok "bridge agent stopped" || true
  launchctl bootout "gui/$UID_NUM/$LABEL_WS" 2>/dev/null && ok "websockify agent stopped" || true
  rm -f "$AGENTS/$LABEL_BRIDGE.plist" "$AGENTS/$LABEL_WS.plist"
  rm -rf "$HW_HOME"
  ok "removed $HW_HOME and both launch agents"
  say "Done. (Screen Sharing itself is yours — turn it off in System Settings if you no longer want it.)"
  exit 0
fi

# ------------------------------------------------------------------- status
if [[ "${1:-}" == "--status" ]]; then
  say "Heartwood on this Mac:"
  agent_running "$LABEL_BRIDGE" && ok "bridge agent running" || warn "bridge agent not running"
  agent_running "$LABEL_WS" && ok "websockify agent running" || warn "websockify agent not running"
  nc -z localhost "$VNC_PORT" 2>/dev/null && ok "Screen Sharing answering on :$VNC_PORT" || warn "nothing on :$VNC_PORT — Screen Sharing off?"
  nc -z localhost "$BRIDGE_PORT" 2>/dev/null && ok "bridge answering on :$BRIDGE_PORT" || warn "bridge not answering on :$BRIDGE_PORT"
  nc -z localhost "$WS_PORT" 2>/dev/null && ok "websockify answering on :$WS_PORT" || warn "websockify not answering on :$WS_PORT"
  say ""
  say "Your Mac's address for the Heartwood app:  $(hostname -s).local"
  exit 0
fi

# ------------------------------------------------------------------ install
say "🪵 Heartwood VNC — Mac setup"
say ""

# 1. macOS + python3 sanity
[[ "$(uname)" == "Darwin" ]] || die "This script is for macOS."
if ! command -v python3 >/dev/null 2>&1; then
  die "python3 not found. macOS will offer to install developer tools the first time you run 'python3' in Terminal — do that, then re-run this script."
fi
# A bare python3 shim can still trigger the CLT popup; probe it actually runs.
if ! python3 -c 'import sys' >/dev/null 2>&1; then
  die "python3 isn't usable yet. If a 'developer tools' popup appeared, click Install, wait for it to finish, then re-run this script."
fi
ok "macOS + python3 present"

# 2. Screen Sharing on?
if ! nc -z localhost "$VNC_PORT" 2>/dev/null; then
  say ""
  warn "Screen Sharing is OFF (nothing answering on :$VNC_PORT)."
  say ""
  say "  Turn it on (about 20 seconds):"
  say "    System Settings → General → Sharing → Screen Sharing → ON"
  say "  Then click the (i) next to it and enable:"
  say "    \"VNC viewers may control screen with password\" — and set a password."
  say "  That password is what you'll type into the Heartwood app on your PC."
  say ""
  die "Re-run this script once Screen Sharing is on."
fi
ok "Screen Sharing is on"

# 3. Does it offer classic VNC password auth (security type 2)?
#    We check by speaking RFB to the real server — no guessing.
TYPES_OK=$(python3 - "$VNC_PORT" <<'PYEOF'
import socket, sys
port = int(sys.argv[1])
try:
    s = socket.create_connection(("127.0.0.1", port), 4); s.settimeout(4)
    def recvn(n):
        b = b""
        while len(b) < n:
            c = s.recv(n - len(b))
            if not c: raise ConnectionError
            b += c
        return b
    recvn(12)
    s.sendall(b"RFB 003.008\n")
    n = recvn(1)[0]
    types = list(recvn(n))
    s.close()
    print("yes" if 2 in types else "no")
except Exception:
    print("err")
PYEOF
)
if [[ "$TYPES_OK" == "yes" ]]; then
  ok "\"VNC viewers with password\" is enabled"
elif [[ "$TYPES_OK" == "no" ]]; then
  say ""
  warn "Screen Sharing is on, but the VNC-password option is off."
  say ""
  say "  Enable it (about 15 seconds):"
  say "    System Settings → General → Sharing → Screen Sharing → (i) →"
  say "    \"VNC viewers may control screen with password\" — set a password."
  say ""
  die "Re-run this script once that's enabled."
else
  die "Couldn't probe Screen Sharing on :$VNC_PORT — is something else using that port?"
fi

# 4. Heartwood home + venv + websockify
mkdir -p "$HW_HOME/logs"
if [[ ! -x "$HW_HOME/venv/bin/websockify" ]]; then
  say "  installing relay (one-time, ~30s)…"
  python3 -m venv "$HW_HOME/venv" >/dev/null
  "$HW_HOME/venv/bin/pip" -q install 'websockify==0.13.0' >/dev/null
fi
ok "relay installed ($HW_HOME)"

# 5. The pass-through auth bridge (embedded — this file IS the Mac side)
cat > "$HW_HOME/vnc-bridge.py" <<'BRIDGEEOF'
#!/usr/bin/env python3
"""Heartwood pass-through VNC auth bridge: presents classic VNC auth (type 2)
to the client and relays the ENTIRE handshake to macOS Screen Sharing —
Apple's challenge goes to the client, the client's answer goes back to Apple,
and Apple alone judges it. The bridge stores NO password anywhere.

macOS Screen Sharing serves one live viewer at a time, so the bridge enforces
"newest connection wins." Tradeoff (LAN/Tailscale exposure assumed): teardown
happens before the newcomer authenticates, so a wrong-password knock bounces
the live session — the real viewer's auto-reconnect recovers in seconds."""
import socket, threading, struct, time, sys

# Bind the auth bridge to loopback only: its sole client is the websockify
# relay on this same Mac. The PC-facing door is websockify's port, not this one.
LISTEN = ("127.0.0.1", int(sys.argv[1]) if len(sys.argv) > 1 else 5901)
REAL   = ("127.0.0.1", int(sys.argv[2]) if len(sys.argv) > 2 else 5900)

_session_lock = threading.Lock()
_active = {"sockets": None}
UPSTREAM_RELEASE_WAIT = 0.4
UPSTREAM_RETRIES = 5
UPSTREAM_RETRY_WAIT = 0.3

def recvn(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("peer closed")
        buf += chunk
    return buf

def send_fail(sock, msg):
    sock.sendall(struct.pack(">I", 1) + struct.pack(">I", len(msg)) + msg.encode())

def close_socks(*socks):
    for s in socks:
        if not s:
            continue
        try: s.shutdown(socket.SHUT_RDWR)
        except Exception: pass
        try: s.close()
        except Exception: pass

def _dial_real_once():
    s = socket.create_connection(REAL, 5); s.settimeout(10)
    recvn(s, 12)
    s.sendall(b"RFB 003.008\n")
    n = recvn(s, 1)[0]
    types = recvn(s, n)
    if 2 not in types:
        raise RuntimeError(f"real server has no type 2: {list(types)}")
    s.sendall(b"\x02")
    challenge = recvn(s, 16)
    return s, challenge

def dial_real():
    last = None
    for _ in range(UPSTREAM_RETRIES):
        try:
            return _dial_real_once()
        except Exception as e:
            last = e
            time.sleep(UPSTREAM_RETRY_WAIT)
    raise last

def handle(client, addr):
    print(f"bridge: client from {addr}", flush=True)
    client.settimeout(15)
    server = None
    try:
        client.sendall(b"RFB 003.008\n")
        recvn(client, 12)
        with _session_lock:
            prev = _active.get("sockets")
            if prev:
                print("  -> dropping previous session (newest connection wins)", flush=True)
                close_socks(*prev)
                time.sleep(UPSTREAM_RELEASE_WAIT)
            server, challenge = dial_real()
            client.sendall(b"\x01\x02")
            if recvn(client, 1)[0] != 2:
                send_fail(client, "type 2 required")
                close_socks(client, server); return
            client.sendall(challenge)
            resp = recvn(client, 16)
            server.sendall(resp)
            result = recvn(server, 4)
            client.sendall(result)
            if struct.unpack(">I", result)[0] != 0:
                try:
                    ln = recvn(server, 4)
                    client.sendall(ln)
                    client.sendall(recvn(server, struct.unpack(">I", ln)[0]))
                except Exception:
                    pass
                print("  -> auth rejected by macOS (verdict relayed)", flush=True)
                close_socks(client, server); return
            client_init = recvn(client, 1)
            server.sendall(client_init)
            _active["sockets"] = (client, server)
        print("  -> pass-through auth OK, bridging", flush=True)

        server.settimeout(None); client.settimeout(None)

        def pump(src, dst):
            try:
                while True:
                    d = src.recv(65536)
                    if not d: break
                    dst.sendall(d)
            except Exception:
                pass
            finally:
                close_socks(src, dst)
        t1 = threading.Thread(target=pump, args=(client, server), daemon=True)
        t2 = threading.Thread(target=pump, args=(server, client), daemon=True)
        t1.start(); t2.start(); t1.join(); t2.join()
        print("  -> session ended", flush=True)
    except Exception as e:
        print(f"  -> error: {e}", flush=True)
        close_socks(client, server)
    finally:
        with _session_lock:
            if _active.get("sockets") and _active["sockets"][0] is client:
                _active["sockets"] = None

ls = socket.socket(); ls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
ls.bind(LISTEN); ls.listen(5)
print(f"heartwood bridge listening on {LISTEN} -> {REAL} (pass-through, no stored password)", flush=True)
while True:
    c, a = ls.accept()
    threading.Thread(target=handle, args=(c, a), daemon=True).start()
BRIDGEEOF
ok "pass-through bridge written (stores no password, ever)"

# 6. launchd agents — alive now, alive after every reboot
# Stop only our own prior agents first. If either port remains occupied after
# that, fail clearly rather than mistaking an unrelated/legacy listener for a
# successful Heartwood install.
launchctl bootout "gui/$UID_NUM/$LABEL_WS" 2>/dev/null || true
launchctl bootout "gui/$UID_NUM/$LABEL_BRIDGE" 2>/dev/null || true
sleep 1
for port in "$BRIDGE_PORT" "$WS_PORT"; do
  holder="$(port_listener "$port")"
  [[ -z "$holder" ]] || die "Port :$port is already in use (PID $holder). Stop the existing relay, then re-run setup."
done

write_plist() {
  local label="$1"; shift
  local out="$AGENTS/$label.plist"
  mkdir -p "$AGENTS"
  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
    printf '<plist version="1.0">\n<dict>\n'
    printf '  <key>Label</key><string>%s</string>\n' "$label"
    printf '  <key>ProgramArguments</key>\n  <array>\n'
    local arg
    for arg in "$@"; do printf '    <string>%s</string>\n' "$arg"; done
    printf '  </array>\n'
    printf '  <key>RunAtLoad</key><true/>\n'
    printf '  <key>KeepAlive</key><true/>\n'
    printf '  <key>StandardOutPath</key><string>%s/logs/%s.log</string>\n' "$HW_HOME" "$label"
    printf '  <key>StandardErrorPath</key><string>%s/logs/%s.log</string>\n' "$HW_HOME" "$label"
    printf '</dict>\n</plist>\n'
  } > "$out"
  launchctl bootstrap "gui/$UID_NUM" "$out"
}

write_plist "$LABEL_BRIDGE" "$HW_HOME/venv/bin/python3" "$HW_HOME/vnc-bridge.py" "$BRIDGE_PORT" "$VNC_PORT"
write_plist "$LABEL_WS" "$HW_HOME/venv/bin/websockify" "$WS_PORT" "localhost:$BRIDGE_PORT"
ok "launch agents installed (auto-start on every boot)"

# 7. Verify the chain end to end
sleep 2
agent_running "$LABEL_BRIDGE" || die "bridge agent failed to stay running — see $HW_HOME/logs/"
agent_running "$LABEL_WS" || die "websockify agent failed to stay running — see $HW_HOME/logs/"
nc -z localhost "$BRIDGE_PORT" 2>/dev/null || die "bridge didn't come up on :$BRIDGE_PORT — see $HW_HOME/logs/"
nc -z localhost "$WS_PORT" 2>/dev/null || die "websockify didn't come up on :$WS_PORT — see $HW_HOME/logs/"
ok "relay chain is up  (:$WS_PORT → :$BRIDGE_PORT → :$VNC_PORT)"

say ""
say "🖼  Done! On your PC, open Heartwood VNC and enter:"
say ""
say "      Mac address:  $(hostname -s).local"
say "      Password:     the one you set in Screen Sharing settings"
say ""
say "  (Both machines must be on the same network — or the same Tailscale"
say "   tailnet. Never expose these ports to the open internet.)"
