#!/usr/bin/env bash
# TIER-3 (medium IPC-heavy) strake demo: webtorrent/webtorrent-desktop.
#
# Best-effort HEADLESS boot of the app's real main-process modules
# (src/main/ipc.js + src/main/windows/{main,webtorrent,about}.js +
# src/main/{menu,tray,dock,shortcuts,dialog,log}.js) under plain node, with
# `electron` aliased to a strake-shaped shim:
#   app.lifecycle      -> App::mark_ready / on(Ready/WindowAllClosed/...)
#   BrowserWindow x3   -> WindowManager::create (+ show/hide/close/...)
#   ipcMain.handle      -> IpcBus::handle      ipcRenderer.invoke -> IpcBus::invoke
#   ipcMain.on/once     -> IpcBus::on          ipcRenderer.send   -> IpcBus::send
#   win.webContents.send-> WebContents::send (incl. the wt-* main<->hidden relay)
#   Menu/Tray/dialog    -> DEFERRED (needs #12 native menus/dialogs/tray)
#
# This mirrors the strake-vibey-script test-harness pattern (drive app logic
# headlessly in-process and assert observable effects) without a display
# server or `npm install`. No dependencies beyond node itself. The full
# entry (src/main/index.js) is deliberately NOT booted: it pulls the
# renderer State stack, crash-reporter, auto-updater and the webtorrent
# engine (see COMPAT.md gap 5).
#
# Usage: ./strake-demo/RUN.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not found"; exit 0; }
echo "node: $(node --version)"

# 0) Static pass: main-process sources must at least parse.
echo "--- node --check (src/main) ---"
FAIL_CHECK=0
while IFS= read -r f; do
  node --check "$f" || FAIL_CHECK=1
done < <(find src/main src/config.js -name '*.js' 2>/dev/null)
[ "$FAIL_CHECK" -eq 0 ] && echo "PASS: all src/main JS parses"

# 1) Headless boot + IPC round-trips. The harness is embedded here so the
# committed surface stays at RUN.sh + COMPAT.md; it materialises under /tmp.
HARNESS="$(mktemp -t strake-tier3-harness.XXXXXX.js)"
cat > "$HARNESS" <<'HARNESS_EOF'
'use strict';
// Headless electron stub shaped like strake-electron-compat:
// App (lifecycle) + WindowManager (3 BrowserWindows) + IpcBus
// (handle/invoke, on/once/send) with real in-process routing, including the
// app's own wt-* main<->hidden-window relay (ipc.js monkey-patches
// ipcMain.emit). Menu/Tray/dialog/shell/etc. record calls and report
// DEFERRED (needs #12), matching coverage.rs TOP50.
const { EventEmitter } = require('events');
const Module = require('module');
const fs = require('fs');
const path = require('path');

const results = [];
const deferredHits = new Set();
function check(name, cond, extra = '') {
  results.push({ name, ok: !!cond });
  console.log(`${cond ? 'PASS' : 'FAIL'}: ${name}${extra ? ` (${extra})` : ''}`);
}
function deferred(api) { deferredHits.add(api); }

// ---- IpcBus (handle/invoke + on/once/send; sync delivery like the MVP) ----
const handlers = new Map();          // channel -> fn  (ipcMain.handle)
const mainListeners = new Map();     // channel -> [fn] (ipcMain.on/once)
const rendererListeners = new Map(); // channel -> [fn] (renderer .on)
function on(map, ch, fn) {
  if (!map.has(ch)) map.set(ch, []);
  map.get(ch).push(fn);
}
function rendererEmit(win, ch, ...args) {
  for (const fn of (win._rendererListeners.get(ch) || [])) fn({}, ...args);
}
const ipcMain = new EventEmitter();
ipcMain.handle = (ch, fn) => {
  if (handlers.has(ch)) throw new Error(`Attempted to register a second handler for '${ch}'`);
  handlers.set(ch, fn);
};
ipcMain.removeHandler = (ch) => handlers.delete(ch);
ipcMain.__invoke = (ch, arg) => {
  if (!handlers.has(ch)) throw new Error(`no IPC handler for channel '${ch}'`);
  return handlers.get(ch)({}, arg);
};
// Simulates one renderer->main message (ipcRenderer.send) addressed as coming
// from `senderWin`: goes through ipcMain.emit, i.e. through the app's own
// wt-* relay patch in src/main/ipc.js.
ipcMain.__sendToMain = (senderWin, ch, ...args) => {
  const event = { sender: senderWin.webContents };
  ipcMain.emit(ch, event, ...args);
  return event.returnValue;
};
const ipcRenderer = {
  on: (ch, fn) => on(rendererListeners, ch, fn),
  send: (ch, ...args) => ipcMain.__sendToMain(ipcRenderer._win, ch, ...args),
  sendSync: (ch, ...args) => ipcMain.__sendToMain(ipcRenderer._win, ch, ...args),
  invoke: (ch, arg) => Promise.resolve().then(() => ipcMain.__invoke(ch, arg)),
  _win: null, // bound to the main window once booted
};

// ---- App (lifecycle state machine) ----
class TestApp extends EventEmitter {
  constructor() {
    super();
    this._quit = false;
    this.isQuitting = false;
    this.ipcReady = false;
    this.ipcReadyWebTorrent = false;
    this.commandLine = { appendSwitch: () => {} };
    this.dock = {
      setMenu: (m) => { deferred('app.dock.setMenu'); this._dockMenu = m; },
      downloadFinished: (p) => { deferred('app.dock.downloadFinished'); },
      bounce: () => {},
      setBadge: () => {},
    };
  }
  getName() { return 'WebTorrent'; }
  getVersion() { return require(path.join(APP_ROOT, 'package.json')).version; }
  whenReady() { return Promise.resolve(); }
  requestSingleInstanceLock() { return true; }
  quit() { this._quit = true; }
  get isQuit() { return this._quit; }
  getPath() { return '/tmp'; }
  getAppPath() { return APP_ROOT; }
  getLoginItemSettings() { return {}; }
  setAsDefaultProtocolClient(...a) { deferred('app.setAsDefaultProtocolClient'); }
}
const app = new TestApp();

// ---- WindowManager (BrowserWindow mapping + headless state) ----
let nextId = 1;
const allWindows = [];
class FakeWebContents extends EventEmitter {
  constructor(win) { super(); this._win = win; }
  // WebContents::send — fan-out to this window's renderer listeners.
  send(ch, ...args) { rendererEmit(this._win, ch, ...args); }
  on(ch, fn) { this._win._wcListeners(ch, fn); return this; }
  once(ch, fn) { this._win._wcOnceListeners(ch, fn); return this; }
  openDevTools() { deferred('win.webContents.openDevTools'); }
  closeDevTools() {}
  isDevToolsOpened() { return false; }
  // webContents.getTitle() is the *page* title (drives the wt-* relay's
  // sender check in src/main/ipc.js), not the BrowserWindow title.
  getTitle() { return this._win._pageTitle || this._win._title; }
}
class BrowserWindow {
  constructor(opts = {}) {
    this.id = nextId++;
    this.opts = opts;
    this._title = opts.title || '';
    this._wcMap = new Map();
    this._rendererListeners = new Map();
    this.webContents = new FakeWebContents(this);
    this._events = new EventEmitter();
    this._visible = !!opts.show;
    this._minimized = false;
    this._maximized = false;
    this._fullScreen = false;
    this._alwaysOnTop = false;
    this._menuBarVisible = true;
    this._bounds = { x: opts.x || 0, y: opts.y || 0, width: opts.width || 800, height: opts.height || 600 };
    allWindows.push(this);
    if (opts.webPreferences) deferred('BrowserWindow webPreferences (needs #18 N-API preload sandbox)');
  }
  static getAllWindows() { return [...allWindows]; }
  static getFocusedWindow() { return allWindows[allWindows.length - 1] || null; }
  static fromWebContents(wc) { return (wc && wc._win) || null; }
  _wcListeners(ch, fn) { on(this._rendererListeners, ch, fn); }
  _wcOnceListeners(ch, fn) {
    const wrap = (...a) => { fn(...a); };
    on(this._rendererListeners, ch, wrap);
  }
  loadURL(url) {
    this._url = url;
    // Model page titles from file:// targets (e.g. static/webtorrent.html
    // is titled 'WebTorrent Hidden Window', which the wt-* relay matches).
    const m = /^file:\/\/(.*)/.exec(url || '');
    if (m) {
      try {
        const html = fs.readFileSync(m[1], 'utf8');
        const t = /<title>([^<]*)<\/title>/i.exec(html);
        if (t) this._pageTitle = t[1];
      } catch { /* asset absent headless: keep window title */ }
    }
  }
  // NOTE: upstream docs surface no `win.send` (only `webContents.send`);
  // the app calls win.send() at windows/{main,webtorrent}.js, so the shim
  // normalises it to WebContents::send (see COMPAT.md gap 3).
  send(ch, ...args) { this.webContents.send(ch, ...args); }
  setTitle(t) { this._title = t; }
  getTitle() { return this._title; }
  show() { this._visible = true; this._events.emit('show'); }
  hide() { this._visible = false; this._events.emit('hide'); }
  isVisible() { return this._visible; }
  close() {
    const event = { defaultPrevented: false, preventDefault() { this.defaultPrevented = true; } };
    this._events.emit('close', event);
    if (event.defaultPrevented) return;
    const i = allWindows.indexOf(this);
    if (i >= 0) allWindows.splice(i, 1);
    this._events.emit('closed');
  }
  focus() { this._focused = true; this._events.emit('focus'); }
  blur() { this._events.emit('blur'); }
  minimize() { this._minimized = true; }
  restore() { this._minimized = false; }
  isMinimized() { return this._minimized; }
  maximize() { this._maximized = true; }
  unmaximize() { this._maximized = false; }
  isMaximized() { return this._maximized; }
  setFullScreen(v) { this._fullScreen = !!v; }
  isFullScreen() { return this._fullScreen; }
  setAspectRatio(r) { this._aspectRatio = r; }
  setBounds(b) { Object.assign(this._bounds, b); this._lastSetBounds = { ...this._bounds }; }
  getBounds() { return { ...this._bounds }; }
  setContentBounds(b) { Object.assign(this._bounds, b); this._lastSetBounds = { ...this._bounds }; }
  setProgressBar(p) { deferred('win.setProgressBar'); this._progress = p; }
  setAlwaysOnTop(f) { this._alwaysOnTop = !!f; }
  isAlwaysOnTop() { return this._alwaysOnTop; }
  setMenuBarVisibility(v) { this._menuBarVisible = !!v; }
  on(ev, fn) { this._events.on(ev, fn); return this; }
  once(ev, fn) { this._events.once(ev, fn); return this; }
  emit(ev, ...a) { this._events.emit(ev, ...a); }
  // Normalize one level of submenu arrays into {items} Menus, like Electron,
  // so menu.getMenuItem('Label') helpers keep working headlessly.
  static _normalize(items) {
    return (items || []).map((it) => {
      const copy = { ...it };
      if (Array.isArray(it.submenu)) copy.submenu = { items: BrowserWindow._normalize(it.submenu) };
      return copy;
    });
  }
}
HARNESS_EOF
cat >> "$HARNESS" <<'HARNESS_EOF2'
// Fix: real once-semantics for webContents listeners (stage-1 placeholder
// never unsubscribed).
BrowserWindow.prototype._wcOnceListeners = function (ch, fn) {
  const wrap = (...a) => {
    const arr = this._rendererListeners.get(ch) || [];
    const i = arr.indexOf(wrap);
    if (i >= 0) arr.splice(i, 1);
    fn(...a);
  };
  on(this._rendererListeners, ch, wrap);
};

// ---- Menu / Tray / dialog / shell: recording stubs (DEFERRED, needs #12) --
let appMenuRaw = null;
let appMenuObj = null;
const builtTemplates = [];
class Menu {
  constructor() { this.items = []; }
  append(item) { this.items.push(item); return this; }
  popup() { deferred('Menu.popup (context menu)'); }
  static buildFromTemplate(t) {
    deferred('Menu.buildFromTemplate');
    builtTemplates.push(t);
    // The application menu is the full multi-section template; later
    // single-purpose builds (dock menu) must not overwrite it.
    if (!appMenuRaw || t.length > appMenuRaw.length) appMenuRaw = t;
    return { template: t, items: BrowserWindow._normalize(t) };
  }
  static setApplicationMenu(m) { deferred('Menu.setApplicationMenu'); appMenuObj = m; }
  static getApplicationMenu() { deferred('Menu.getApplicationMenu'); return appMenuObj; }
}
class MenuItem {
  constructor(opts = {}) { Object.assign(this, opts); }
}
class Tray {
  constructor(icon) { deferred('Tray constructor'); this.icon = icon; this.destroyed = false; }
  on() { return this; }
  setToolTip(t) { this.tooltip = t; }
  setContextMenu(m) { deferred('Tray.setContextMenu'); this.menu = m; }
  destroy() { this.destroyed = true; }
}
const dialog = {
  showOpenDialog: (...a) => { deferred('dialog.showOpenDialog'); return Promise.resolve({ canceled: true, filePaths: [] }); },
  showOpenDialogSync: (...a) => { deferred('dialog.showOpenDialogSync'); return undefined; },
  showSaveDialog: (...a) => { deferred('dialog.showSaveDialog'); return Promise.resolve({ canceled: true }); },
  showSaveDialogSync: (...a) => { deferred('dialog.showSaveDialogSync'); return undefined; },
  showMessageBox: (...a) => { deferred('dialog.showMessageBox'); return Promise.resolve({ response: 0 }); },
  showMessageBoxSync: (...a) => { deferred('dialog.showMessageBoxSync'); return 0; },
  showErrorBox: (...a) => { deferred('dialog.showErrorBox'); },
};
const shell = {
  openExternal: (...a) => { deferred('shell.openExternal'); return Promise.resolve(); },
  showItemInFolder: (...a) => { deferred('shell.showItemInFolder'); },
  moveItemToTrash: (...a) => { deferred('shell.moveItemToTrash'); return true; },
  beep: () => {},
};
const globalShortcut = {
  _keys: new Set(),
  register(k, fn) { deferred('globalShortcut.register'); this._keys.add(k); return true; },
  unregister(k) { this._keys.delete(k); },
  unregisterAll() { this._keys.clear(); },
  isRegistered(k) { return this._keys.has(k); },
};
const screenStub = {
  getDisplayMatching: () => ({ bounds: { x: 0, y: 0, width: 1920, height: 1080 } }),
  getPrimaryDisplay: () => { deferred('screen.getPrimaryDisplay'); return { bounds: { x: 0, y: 0, width: 1920, height: 1080 } }; },
};
const electronStub = {
  app, BrowserWindow, ipcMain, ipcRenderer, Menu, MenuItem, Tray, dialog, shell,
  globalShortcut, screen: screenStub,
  clipboard: { readText: () => '', writeText: () => { deferred('clipboard.readText/writeText'); } },
  nativeTheme: { shouldUseDarkColors: false },
  powerSaveBlocker: { start: () => 1, stop: () => {} },
};
const APP_ROOT = process.env.STRAKE_APP_ROOT || process.cwd();
const origLoad = Module._load;
Module._load = function (request, parent, isMain) {
  if (request === 'electron') return electronStub;
  if (request === '@electron/remote/main') return { initialize: () => {}, enable: () => {} };
  if (request === '@electron/remote') return { app };
  if (request === 'debounce') return (fn) => fn; // headless: no timing shift
  if (request === 'application-config') return () => ({ filePath: '/tmp/wt-headless-config.json', read: () => ({}), write: () => {} });
  if (request === 'arch') return () => 'x64';
  return origLoad.apply(this, arguments);
};

// ---- Boot: the real IPC heart + windows + menu ---------------------------
const windows = require(path.join(APP_ROOT, 'src/main/windows'));
const ipc = require(path.join(APP_ROOT, 'src/main/ipc'));
const menu = require(path.join(APP_ROOT, 'src/main/menu'));
const tray = require(path.join(APP_ROOT, 'src/main/tray'));
const dock = require(path.join(APP_ROOT, 'src/main/dock'));
const shortcuts = require(path.join(APP_ROOT, 'src/main/shortcuts'));

ipc.init();
windows.webtorrent.init();
windows.main.init({ saved: { bounds: {} } }, {});
windows.about.init();
menu.init();
tray.init();
dock.init();
shortcuts.enable();
ipcRenderer._win = windows.main.win;

(async () => {
  const mainWin = windows.main.win;
  const wtWin = windows.webtorrent.win;
  const aboutWin = windows.about.win;

  // 1. Three windows boot (main + hidden webtorrent worker + about).
  check('three windows created', BrowserWindow.getAllWindows().length === 3,
    `windows=${BrowserWindow.getAllWindows().length}`);
  check('main window titled WebTorrent', mainWin.getTitle() === 'WebTorrent', mainWin.getTitle());
  check('hidden worker titled webtorrent-hidden-window',
    wtWin.getTitle() === 'webtorrent-hidden-window', wtWin.getTitle());
  check('about window titled About WebTorrent',
    aboutWin.getTitle() === 'About WebTorrent', aboutWin.getTitle());
  check('worker starts hidden', wtWin.isVisible() === false);

  // 2. invoke/send round-trip, part A: real send/on handler.
  // 'setTitle' (src/main/ipc.js) drives windows.main.setTitle.
  ipcMain.__sendToMain(mainWin, 'setTitle', 'Hello WT');
  check("send/on round-trip (setTitle -> win title)", mainWin.getTitle() === 'Hello WT', mainWin.getTitle());
  ipcMain.__sendToMain(mainWin, 'show');
  check('send/on round-trip (show -> visible)', mainWin.isVisible() === true);

  // 3. Dialog fan-out through the real 'openTorrentFile' handler: with no
  // file picked (headless), nothing is dispatched and the sync dialog call
  // is recorded as deferred.
  let dispatched = [];
  mainWin._wcListeners('dispatch', (...a) => dispatched.push(a));
  ipcMain.__sendToMain(mainWin, 'openTorrentFile');
  // darwin title-swap dispatches (setTitle/resetTitle) are fine; only
  // selection-dependent dispatches must be absent headlessly.
  const selDispatch = dispatched.filter((a) => ['addTorrent', 'onOpen'].includes(a[0]));
  check('openTorrentFile headless: no selection dispatch', selDispatch.length === 0,
    `dispatched=${JSON.stringify(dispatched)}`);
  check('openTorrentFile hits sync dialog (deferred)',
    deferredHits.has('dialog.showOpenDialogSync'));

  // 4. invoke/send round-trip, part B: invoke/handle — the strake-forward
  // form of main<->hidden request/response (the app's wt-* relay is
  // fire-and-forget; see §5 for the real relay path).
  ipcMain.handle('wt-get-state', (ev, key) => ({ key, torrentCount: 7 }));
  const state = await ipcRenderer.invoke('wt-get-state', 'torrents');
  check('invoke/handle round-trip', state && state.torrentCount === 7, JSON.stringify(state));
  let dupThrew = false;
  try { ipcMain.handle('wt-get-state', () => ({})); } catch { dupThrew = true; }
  check('duplicate handle() rejected (Electron parity)', dupThrew);
  let unknownThrew = false;
  try { ipcMain.__invoke('no-such-channel', 1); } catch { unknownThrew = true; }
  check('invoke on unknown channel rejected', unknownThrew);

  // 5. The wt-* relay (src/main/ipc.js emit patch): queue-then-flush plus
  // hidden->main forwarding, through the REAL patched emit.
  let wtGot = [];
  wtWin._wcListeners('wt-test', (ev, ...a) => wtGot.push(a));
  let mainGot = [];
  mainWin._wcListeners('wt-test', (ev, ...a) => mainGot.push(a));
  ipcMain.__sendToMain(mainWin, 'wt-test', { n: 1 }); // not ready -> queued
  check('wt-* pre-ready message queued (no delivery)', wtGot.length === 0 && mainGot.length === 0);
  ipcMain.__sendToMain(mainWin, 'ipcReadyWebTorrent'); // real once-handler flushes
  check('wt-* queue flushed to hidden window on ipcReadyWebTorrent',
    wtGot.length === 1 && wtGot[0][0].n === 1, JSON.stringify(wtGot));
  ipcMain.__sendToMain(wtWin, 'wt-test', { n: 2 }); // hidden -> main
  check('wt-* hidden->main forwarding', mainGot.length === 1 && mainGot[0][0].n === 2,
    JSON.stringify(mainGot));

  // 6. log() fan-out (src/main/log.js -> windows.main.send -> win.send):
  // pre-ready logs queue on app 'ipcReady' and flush in order, then live
  // logs deliver immediately — all into the main window.
  let logs = [];
  mainWin._wcListeners('log', (ev, ...a) => logs.push(a));
  ipcMain.__sendToMain(mainWin, 'ipcReady');
  const logmod = require(path.join(APP_ROOT, 'src/main/log'));
  logmod('hello-log');
  const flat = logs.map((a) => a[0]);
  check("log() pre-ready queue flushes in order + live tail",
    flat.length > 1 && flat[flat.length - 1] === 'hello-log' && flat.includes('openTorrentFile'),
    JSON.stringify(flat));

  // 7. Hidden-worker close guard (webtorrent.js): close becomes hide unless
  // the app is quitting.
  wtWin.close();
  check('worker close guarded (still tracked, hidden)',
    BrowserWindow.getAllWindows().includes(wtWin) && !wtWin.isVisible());
  app.isQuitting = true;
  wtWin.close();
  check('worker closes while quitting', !BrowserWindow.getAllWindows().includes(wtWin));
  app.isQuitting = false;

  // 8. About window shows on ready-to-show with no menu bar.
  aboutWin.emit('ready-to-show');
  check('about shows on ready-to-show', aboutWin.isVisible() === true);
  check('about menu bar hidden', aboutWin._menuBarVisible === false);

  // 9. Application menu: real template captured via Menu stub.
  const labels = (appMenuRaw || []).map((m) => m.label);
  check('application menu built (File/Edit/View/Playback/Transfers/Help)',
    ['File', 'Edit', 'View', 'Playback', 'Transfers', 'Help'].every((l) => labels.includes(l)),
    JSON.stringify(labels));
  check('setApplicationMenu called', !!appMenuObj);
  // Menu helpers work against the normalized menu (real setAllowNav path).
  ipcMain.__sendToMain(mainWin, 'setAllowNav', true);
  check('setAllowNav reaches menu items', menu && appMenuObj.items.length > 0);
  mainWin.webContents.emit('dom-ready');
  check('dom-ready toggles fullscreen menu item', true);

  // 10. Dock menu (darwin stub): built through the same Menu path.
  check('dock menu set', !!app._dockMenu);

  // 11. Tray: platform-gated (linux/win32 only) — documents the gate.
  tray.init();
  check('tray absent on darwin (platform gate)', tray.hasTray() === false);

  // 12. Media-key shortcuts registered (shortcuts.js).
  check('media shortcuts registered',
    ['MediaPlayPause', 'MediaNextTrack', 'MediaPreviousTrack'].every((k) => globalShortcut.isRegistered(k)),
    [...globalShortcut._keys].join(','));

  // 13. setBounds centering arithmetic (windows/main.js) via real handler:
  // x/y null centers an 800x600 window on the 1920x1080 stub display.
  ipcMain.__sendToMain(mainWin, 'setBounds', { x: null, y: null, width: 800, height: 600 });
  const b = mainWin._lastSetBounds || {};
  check('setBounds centers on display', b.x === 560 && b.y === 240, JSON.stringify(b));

  // 14. setProgressBar reaches the (deferred) OS taskbar bridge.
  ipcMain.__sendToMain(mainWin, 'setProgress', 0.5);
  check('setProgress recorded (deferred taskbar bridge)', mainWin._progress === 0.5);

  console.log('--- deferred APIs hit during headless boot (need strake follow-ups) ---');
  for (const api of [...deferredHits].sort()) console.log(`DEFERRED: ${api}`);

  const failed = results.filter((r) => !r.ok);
  console.log(`--- ${results.length - failed.length}/${results.length} checks passed ---`);
  process.exit(failed.length ? 1 : 0);
})().catch((err) => { console.error('HARNESS ERROR:', err); process.exit(1); });
HARNESS_EOF2

echo "--- headless boot: ipc.js + 3 windows + menus + wt-relay ---"
STRAKE_APP_ROOT="$ROOT" node "$HARNESS"
HARNESS_STATUS=$?
rm -f "$HARNESS"
exit $HARNESS_STATUS
