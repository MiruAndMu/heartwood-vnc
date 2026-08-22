// Looking Glass — Electron main process (full-size stage architecture).
//
// THE WINDOW NEVER RESIZES. It is created once at the display's work-area
// size and stays there for its whole life. The OS never maximizes, restores,
// or re-bounds it — which makes the transparent-frameless red-flash artifact
// (a GPU surface reinit during OS resize) STRUCTURALLY impossible.
//
// The two visual states live entirely in the renderer now:
//
//   UNFRAMED — the noVNC feed fills the (work-area-sized) window edge to edge.
//   FRAMED   — the walnut frame is a pure CSS object positioned/scaled inside
//              the transparent stage. Drag and resize are CSS-variable math.
//
// Main's only remaining jobs: create the stage window, click-through
// forwarding on the transparent margins (setIgnoreMouseEvents), minimize,
// close, tray, and the safety hotkey.
const { app, BrowserWindow, globalShortcut, ipcMain, Tray, Menu, nativeImage, screen, safeStorage } = require('electron');
const path = require('path');
const fs = require('fs');

let win = null;
let tray = null;

// ---- debug log (the flight recorder) ---------------------------------------
// Dev (npm start): next to main.js, readable over SSH at looking-glass-app/.
// Packaged: __dirname is inside the read-only app archive, so the log moves
// to userData (%APPDATA%/heartwood-vnc/) — otherwise it dies silently.
let LOG = null;
function dlog(...a) {
  try {
    if (!LOG) {
      const dir = app.isPackaged ? app.getPath('userData') : __dirname;
      fs.mkdirSync(dir, { recursive: true });
      LOG = path.join(dir, 'lg-debug.log');
    }
    fs.appendFileSync(LOG, new Date().toISOString() + ' ' + a.join(' ') + '\n');
  } catch (_) {}
}

function sizeToWorkArea() {
  if (!win) return;
  const disp = screen.getPrimaryDisplay();
  const wa = disp.workArea;
  const bounds = { x: wa.x, y: wa.y, width: wa.width, height: wa.height };
  // WINDOWS LIMITATION (documented): a transparent window sized EXACTLY to
  // the screen resolution stops receiving mouse input entirely. With an
  // auto-hidden taskbar the work area IS the full resolution, so shave one
  // pixel — invisible to the eye, keeps hit-testing alive.
  if (bounds.width >= disp.size.width && bounds.height >= disp.size.height) {
    bounds.height -= 1;
  }
  win.setBounds(bounds);
  dlog('sizeToWorkArea: bounds=', JSON.stringify(win.getBounds()),
       'display=', JSON.stringify(disp.size),
       'resizable=', win.isResizable(), 'movable=', win.isMovable());
}

function createWindow() {
  win = new BrowserWindow({
    width: 1280,
    height: 800,
    frame: false,                  // no OS chrome — the renderer paints everything
    transparent: true,             // margins around the CSS frame show the desktop
    backgroundColor: '#00000000',
    hasShadow: false,
    alwaysOnTop: false,
    show: false,                   // show once sized to avoid any first-paint flash
    // NOTE: resizable/movable stay TRUE (matching the known-good June build).
    // A frameless window exposes no edges or title bar, so the user can't
    // resize/move it anyway — and locking those flags on a transparent
    // window is a prime suspect for the dead-mouse-input bug.
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
    },
  });

  win.loadFile('index.html');

  win.once('ready-to-show', () => {
    // ORDER MATTERS (the 2026-07-06 lesson): show FIRST, resize SECOND.
    // A transparent window resized while hidden never propagates the new
    // size to the renderer on Windows — the page stays at the creation size
    // and everything renders stretched with garbage coordinates. The June
    // build's show()-then-maximize() order was correct all along.
    win.show();
    sizeToWorkArea();
    dlog('shown: bounds=', JSON.stringify(win.getBounds()));
    // Verify the renderer actually learned the size; this line is the test.
    setTimeout(() => {
      win.webContents.executeJavaScript('window.innerWidth + "x" + window.innerHeight')
        .then((s) => dlog('VERIFY renderer inner=', s, 'vs bounds=', JSON.stringify(win.getBounds())))
        .catch((err) => dlog('VERIFY failed:', String(err)));
    }, 700);
  });
  win.on('closed', () => { win = null; });
  // Tell the renderer when we come back from the taskbar so it can reverse
  // the minimize animation.
  win.on('restore', () => win.webContents.send('lg-restored'));
  win.on('show',    () => win.webContents.send('lg-restored'));

  // Capture every renderer console line into the debug log.
  win.webContents.on('console-message', (_e, _level, message) => {
    dlog('[renderer]', message);
  });
  win.webContents.on('render-process-gone', (_e, details) => {
    dlog('RENDERER GONE:', JSON.stringify(details));
  });

  // If the display layout/resolution changes, re-fit the stage once. This is
  // a setBounds on a non-maximized window — not the OS maximize path — and
  // happens only on real display changes, never during framing/unframing.
  screen.on('display-metrics-changed', sizeToWorkArea);
}

// ---- click-through on the transparent margins ------------------------------
// FRAMED mode: main polls the REAL cursor position (native call — immune to
// the unreliable forward:true event forwarding on Windows transparent
// windows) against the frame's rectangle, which the renderer reports on
// every geometry change. Inside the frame → interactive. Outside → mouse
// events pass through to the desktop. Unframed → always interactive.
let framedRect = null;      // {x,y,w,h} in window-content coordinates
let framedOn = false;
let holdInteractive = false; // renderer is mid drag/resize — never pass-through
let ignored = false;
let pollTimer = null;

function setIgnore(v) {
  if (!win || v === ignored) return;
  ignored = v;
  if (v) win.setIgnoreMouseEvents(true, { forward: true });
  else win.setIgnoreMouseEvents(false);
}

function pollCursor() {
  if (!win) return;
  if (!framedOn || holdInteractive || !framedRect) { setIgnore(false); return; }
  const pt = screen.getCursorScreenPoint();
  const [wx, wy] = win.getPosition();
  const x = pt.x - wx, y = pt.y - wy;
  const PAD = 8;   // small forgiveness band around the wood
  const inside =
    x >= framedRect.x - PAD && x <= framedRect.x + framedRect.w + PAD &&
    y >= framedRect.y - PAD && y <= framedRect.y + framedRect.h + PAD;
  setIgnore(!inside);
}

ipcMain.on('lg-frame-rect', (_e, rect) => { framedRect = rect; });

ipcMain.on('lg-mode', (_e, { framed, hold }) => {
  framedOn = !!framed;
  holdInteractive = !!hold;
  if (framedOn && !pollTimer) pollTimer = setInterval(pollCursor, 33);
  if (!framedOn && pollTimer) { clearInterval(pollTimer); pollTimer = null; }
  if (!framedOn || holdInteractive) setIgnore(false);
});

// ---- Heartwood connection config (2026-07-21) ------------------------------
// The Mac's address + Screen Sharing password used to live hardcoded in
// index.html — a dead end for anyone but us. Now they live in a per-user
// config file with the password encrypted at rest via safeStorage (DPAPI on
// Windows: only this user on this machine can decrypt). The renderer asks
// for config at boot; missing config → first-run setup screen.
function configPath() {
  return path.join(app.getPath('userData'), 'heartwood-config.json');
}

ipcMain.handle('lg-config-get', () => {
  try {
    const raw = JSON.parse(fs.readFileSync(configPath(), 'utf8'));
    let password = null;
    if (raw.passwordEnc) {
      password = safeStorage.decryptString(Buffer.from(raw.passwordEnc, 'base64'));
    } else if (raw.passwordPlain) {
      password = raw.passwordPlain;   // fallback path (encryption unavailable)
    }
    if (!raw.host || !password) return null;
    return { host: raw.host, port: raw.port || 5902, password };
  } catch (_) { return null; }        // no config yet → first run
});

ipcMain.handle('lg-config-set', (_e, cfg) => {
  try {
    const rec = { host: String(cfg.host), port: Number(cfg.port) || 5902 };
    if (safeStorage.isEncryptionAvailable()) {
      rec.passwordEnc = safeStorage.encryptString(String(cfg.password)).toString('base64');
    } else {
      rec.passwordPlain = String(cfg.password);
      dlog('CONFIG WARNING: safeStorage unavailable — password stored unencrypted');
    }
    fs.mkdirSync(path.dirname(configPath()), { recursive: true });
    fs.writeFileSync(configPath(), JSON.stringify(rec));
    dlog('CONFIG saved: host=', rec.host, 'port=', rec.port,
         'enc=', rec.passwordEnc ? 'yes' : 'NO');
    return true;
  } catch (e) { dlog('CONFIG save failed:', String(e)); return false; }
});

// ---- min → normal OS minimize (to the taskbar), NOT hide-to-tray ----------
ipcMain.on('lg-minimize', () => { if (win) win.minimize(); });

ipcMain.on('lg-close', () => { app.quit(); });

// ---- tray icon: the heart-rings mark, embedded as PNG ----------------------
// (Was a generated SVG data-URL — Electron's Windows tray renders SVG as
// BLANK, which sat unnoticed since June until Mu's product-eyes caught it
// the night the real icon shipped, 2026-07-21. PNG is embedded so there's
// no dev-vs-packaged path difference.)
function buildTrayIcon() {
  const png = 'data:image/png;base64,' + TRAY_PNG_B64;
  const img = nativeImage.createFromDataURL(png);
  return img.isEmpty() ? nativeImage.createEmpty() : img;
}
const TRAY_PNG_B64 =
  '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';

function showWindow() {
  if (!win) { createWindow(); return; }
  win.show();
  win.focus();
}

function createTray() {
  tray = new Tray(buildTrayIcon());
  tray.setToolTip('Heartwood 🦊');
  const menu = Menu.buildFromTemplate([
    { label: 'Show Heartwood', click: showWindow },
    { type: 'separator' },
    { label: 'Quit', click: () => app.quit() },
  ]);
  tray.setContextMenu(menu);
  tray.on('click', showWindow);
}

// SINGLE INSTANCE: a second double-click must never spawn a second app —
// two instances fight over the Mac's single VNC viewer slot in an endless
// newest-wins ping-pong (the feed dies in BOTH). Focus the original instead.
if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on('second-instance', () => {
    dlog('second-instance launch blocked; focusing existing window');
    showWindow();
  });
}

app.whenReady().then(() => {
  createWindow();
  createTray();

  // SAFETY: a frameless window has no OS close button — guarantee an escape.
  globalShortcut.register('Control+Alt+Q', () => app.quit());

  // PANIC KEY: if pass-through ever gets stuck, Ctrl+Alt+L forces the window
  // interactive and focused again, from anywhere, regardless of mouse state.
  // (Ctrl+Alt+G was the first pick — Google Drive owns it on Mu's PC.)
  globalShortcut.register('Control+Alt+L', () => {
    if (!win) return;
    framedOn = false;
    if (pollTimer) { clearInterval(pollTimer); pollTimer = null; }
    setIgnore(false);
    win.show();
    win.focus();
    win.webContents.send('lg-panic-reset');
  });

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
    else showWindow();
  });
});

app.on('will-quit', () => globalShortcut.unregisterAll());
app.on('window-all-closed', () => { /* stay alive for the tray */ });
