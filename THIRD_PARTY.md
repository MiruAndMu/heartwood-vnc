# Third-Party Software

Heartwood VNC stands on excellent open-source shoulders. Everything vendored
or depended upon, with gratitude:

## Vendored

- **[noVNC](https://github.com/novnc/noVNC)** (`novnc/`) — the HTML5 VNC
  client that renders your Mac inside the frame. Licensed under the
  **Mozilla Public License 2.0**; its complete, unmodified license and
  author credits ship in this repository (`novnc/LICENSE.txt`,
  `novnc/AUTHORS`). Some noVNC subcomponents carry their own licenses as
  documented in `novnc/docs/LICENSE.*`.

## Dependencies (not vendored)

- **[Electron](https://electronjs.org)** (MIT) — the desktop shell.
- **[electron-builder](https://www.electron.build)** (MIT) — builds the
  Windows portable executable.
- **[websockify](https://github.com/novnc/websockify)** (LGPL-3.0) — the
  WebSocket→VNC relay the Mac setup script installs on the Mac side
  (fetched at setup time; not distributed with this app).
- **macOS Screen Sharing** — the VNC server is Apple's own; Heartwood
  never replaces or wraps it, it just knocks politely.

## Not code, still credit

- Tailscale, for making "same network" a gentle phrase instead of a
  networking degree.
