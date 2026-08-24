#!/usr/bin/env python3
"""Tiny type-2 VNC greeting used by the disposable Mac installer test."""

import socket
import sys
import threading


port = int(sys.argv[1])
listener = socket.socket()
listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
listener.bind(("127.0.0.1", port))
listener.listen(8)


def handle(conn):
    try:
        conn.settimeout(3)
        conn.sendall(b"RFB 003.008\n")
        if len(conn.recv(12)) == 12:
            conn.sendall(b"\x01\x02")
    except OSError:
        pass
    finally:
        conn.close()


while True:
    connection, _ = listener.accept()
    threading.Thread(target=handle, args=(connection,), daemon=True).start()
