// Heartwood VNC — preload bridge (full-size stage architecture).
//
// The window never resizes or moves; frame geometry is pure CSS in the
// renderer. Main owns click-through via native cursor polling — the renderer
// just reports mode + frame geometry and reacts to the panic reset.
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('lg', {
  // min → normal OS minimize to the taskbar (NOT hide-to-tray).
  minimize: () => ipcRenderer.send('lg-minimize'),
  close:    () => ipcRenderer.send('lg-close'),

  // Heartwood connection config: host/port + password (encrypted at rest by
  // main via safeStorage). null → no config yet → first-run setup screen.
  getConfig: () => ipcRenderer.invoke('lg-config-get'),
  setConfig: (cfg) => ipcRenderer.invoke('lg-config-set', cfg),

  // Mode report: framed on/off + hold (mid drag/resize → never pass-through).
  setMode: (framed, hold) => ipcRenderer.send('lg-mode', { framed, hold }),

  // Frame rectangle in window-content coords — main hit-tests the cursor
  // against this to decide pass-through on the transparent margins.
  frameRect: (rect) => ipcRenderer.send('lg-frame-rect', rect),

  // Ctrl+Alt+G pressed — main already forced the window interactive; the
  // renderer should drop back to the safe unframed state.
  onPanicReset: (cb) => ipcRenderer.on('lg-panic-reset', () => cb()),

  // Window restored from the taskbar — reverse the minimize animation.
  onRestored: (cb) => ipcRenderer.on('lg-restored', () => cb()),
});
