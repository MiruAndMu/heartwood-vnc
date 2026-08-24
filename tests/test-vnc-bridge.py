#!/usr/bin/env python3
"""Black-box checks for the Python bridge embedded in the Mac setup script."""

from __future__ import annotations

import socket
import struct
import subprocess
import tempfile
import threading
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SETUP = ROOT / "mac-setup" / "heartwood-mac-setup.sh"
VERSION = b"RFB 003.008\n"
CHALLENGE = bytes(range(16))
GOOD_RESPONSE = b"G" * 16


def recvn(sock: socket.socket, count: int) -> bytes:
    data = b""
    while len(data) < count:
        chunk = sock.recv(count - len(data))
        if not chunk:
            raise ConnectionError("peer closed")
        data += chunk
    return data


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class FakeMacVNC:
    def __init__(self) -> None:
        self.port = free_port()
        self.listener = socket.socket()
        self.listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.listener.bind(("127.0.0.1", self.port))
        self.listener.listen(8)
        self.stopping = threading.Event()
        self.thread = threading.Thread(target=self._serve, daemon=True)

    def start(self) -> None:
        self.thread.start()

    def close(self) -> None:
        self.stopping.set()
        self.listener.close()

    def _serve(self) -> None:
        while not self.stopping.is_set():
            try:
                conn, _ = self.listener.accept()
            except OSError:
                return
            threading.Thread(target=self._handle, args=(conn,), daemon=True).start()

    @staticmethod
    def _handle(conn: socket.socket) -> None:
        conn.settimeout(5)
        try:
            conn.sendall(VERSION)
            assert recvn(conn, len(VERSION)) == VERSION
            conn.sendall(b"\x01\x02")
            assert recvn(conn, 1) == b"\x02"
            conn.sendall(CHALLENGE)
            response = recvn(conn, 16)
            if response != GOOD_RESPONSE:
                reason = b"wrong password"
                conn.sendall(struct.pack(">I", 1))
                conn.sendall(struct.pack(">I", len(reason)) + reason)
                return
            conn.sendall(struct.pack(">I", 0))
            recvn(conn, 1)  # ClientInit
            while True:
                data = conn.recv(65536)
                if not data:
                    return
                conn.sendall(data)
        except (AssertionError, ConnectionError, OSError, TimeoutError):
            return
        finally:
            try:
                conn.close()
            except OSError:
                pass


def embedded_bridge() -> str:
    text = SETUP.read_text()
    start_marker = "cat > \"$HW_HOME/vnc-bridge.py\" <<'BRIDGEEOF'\n"
    start = text.index(start_marker) + len(start_marker)
    end = text.index("\nBRIDGEEOF", start)
    return text[start:end] + "\n"


def wait_for_port(port: int, process: subprocess.Popen[str]) -> None:
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError("bridge exited before listening")
        with socket.socket() as probe:
            probe.settimeout(0.1)
            try:
                probe.connect(("127.0.0.1", port))
                return
            except OSError:
                time.sleep(0.05)
    raise TimeoutError("bridge did not begin listening")


def connect_client(port: int, response: bytes = GOOD_RESPONSE) -> tuple[socket.socket, int, str]:
    client = socket.create_connection(("127.0.0.1", port), 3)
    client.settimeout(3)
    assert recvn(client, len(VERSION)) == VERSION
    client.sendall(VERSION)
    assert recvn(client, 2) == b"\x01\x02"
    client.sendall(b"\x02")
    assert recvn(client, 16) == CHALLENGE
    client.sendall(response)
    result = struct.unpack(">I", recvn(client, 4))[0]
    reason = ""
    if result:
        length = struct.unpack(">I", recvn(client, 4))[0]
        reason = recvn(client, length).decode()
    else:
        client.sendall(b"\x01")
    return client, result, reason


def main() -> None:
    fake = FakeMacVNC()
    fake.start()
    bridge_port = free_port()

    with tempfile.TemporaryDirectory(prefix="heartwood-bridge-test-") as tmp:
        bridge_file = Path(tmp) / "vnc-bridge.py"
        bridge_file.write_text(embedded_bridge())
        proc = subprocess.Popen(
            ["python3", str(bridge_file), str(bridge_port), str(fake.port)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        try:
            wait_for_port(bridge_port, proc)

            first, result, _ = connect_client(bridge_port)
            assert result == 0
            first.sendall(b"still-alive")
            assert recvn(first, 11) == b"still-alive"

            # A bare TCP open never reaches the replacement point.
            bare = socket.create_connection(("127.0.0.1", bridge_port), 3)
            assert recvn(bare, len(VERSION)) == VERSION
            bare.close()
            time.sleep(0.15)
            first.sendall(b"after-bare")
            assert recvn(first, 10) == b"after-bare"

            # A client that completes the RFB version exchange does replace it.
            replacement, result, _ = connect_client(bridge_port)
            assert result == 0
            deadline = time.monotonic() + 2
            closed = False
            while time.monotonic() < deadline:
                try:
                    if first.recv(1) == b"":
                        closed = True
                        break
                except OSError:
                    closed = True
                    break
            assert closed, "completed RFB newcomer should replace the active viewer"
            replacement.close()

            rejected, result, reason = connect_client(bridge_port, b"B" * 16)
            assert result == 1
            assert reason == "wrong password"
            rejected.close()
        finally:
            proc.terminate()
            try:
                proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                proc.kill()
            fake.close()

    print("bridge protocol: auth, rejection, bare-open, and replacement checks passed")


if __name__ == "__main__":
    main()
