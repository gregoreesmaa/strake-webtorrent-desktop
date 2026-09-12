# TIER-3 COMPAT — webtorrent-desktop on strake

App: [webtorrent/webtorrent-desktop](https://github.com/webtorrent/webtorrent-desktop)
(v0.24.0, Electron 27.3.11) — torrent-streaming client with a distinctive
IPC-heavy architecture: a visible main window plus a **hidden worker window**
(`show: false`) that runs the WebTorrent engine, an About window, and a
`wt-*` message relay with a pre-ready queue between them.

- Fork: <https://github.com/gregoreesmaa/webtorrent-desktop>
- Demo branch: `strake-demo` (`strake-demo/RUN.sh`, `strake-demo/COMPAT.md`)
- Strake oracle: `strake-electron-compat` at strake rev `68d22d7b`
  (`packages/strake-electron-compat/src/{lib,app,window,ipc,coverage}.rs`,
  frozen TOP50 in `coverage.rs`).
- Upstream default branch here is `master`.

## What runs

`./strake-demo/RUN.sh` (node only, no `npm install`, no display server):
it aliases `electron` (plus tiny `debounce`/`application-config`/`arch`/
`@electron/remote` shims) to a strake-shaped shim (`App` lifecycle +
`WindowManager` + `IpcBus`, cf. the `ScriptDocument`-style headless driving
in `strake-vibey-script/tests/dom.rs`), boots the app's **real
`src/main/ipc.js` + `src/main/windows/{main,webtorrent,about}.js` +
`src/main/{menu,tray,dock,shortcuts,dialog,log}.js`**, and asserts
behaviour. Observed: **29/29 checks passed** (node v26.8.1, macOS/darwin).

Exercised end-to-end through real app code:

- `send`/`on` round-trips: `setTitle` → window title, `show` → visible,
  `openTorrentFile` → sync-dialog deferred capture with no selection
  dispatch (real `ipc.js` + `dialog.js` paths).
- `invoke`/`handle` round-trip: `wt-get-state` → `{torrentCount: 7}`;
  duplicate-`handle` and unknown-channel `invoke` rejected (parity with
  `IpcBus::{DuplicateHandler, UnknownChannel}`). The codebase itself uses
  no `handle`/`invoke` (28 × `ipcMain.on`/`once`, all fire-and-forget), so
  request/response migrates to this form.
- The `wt-*` relay through the app's **real monkey-patched
  `ipcMain.emit`** (`src/main/ipc.js:220`): pre-ready message queued with
  zero delivery → `ipcReadyWebTorrent` flushes exactly one payload to the
  hidden window → hidden→main forwarding by page-title match
  (`static/webtorrent.html` is titled `WebTorrent Hidden Window`, which is
  what `e.sender.getTitle()` returns — verified in-repo).
- `log()` fan-out: pre-ready logs queue on app `ipcReady` and flush **in
  order**, then live logs deliver immediately (`src/main/log.js`).
- Windows: 3 created with correct titles/visibility; worker close→hide
  guard unless quitting; About shows on `ready-to-show` with no menu bar;
  `setBounds` null-x/y centers 800×600 on the stub display → `{x:560,y:240}`
  through the real arithmetic.
- Menus: real 7-section application menu (WebTorrent/File/Edit/View/
  Playback/Transfers/Help) via `buildFromTemplate`+`setApplicationMenu`;
  `setAllowNav` and `dom-ready` drive real menu-item helpers; dock menu
  set; tray correctly absent on darwin (linux/win32-only init);
  MediaPlayPause/Next/Previous shortcuts registered.

## API-by-API mapping

Status values are strake's (`coverage.rs` TOP50): **native** = direct
primitive, **shim** = implemented in `strake-electron-compat`,
**deferred** = out of MVP with blocker named.

### App lifecycle

| Electron API | Used by app | Strake mapping | Status |
|---|---|---|---|
| `app.on('ipcReady'/'ipcReadyWebTorrent')` (custom events) | `ipc.js`, `log.js` | `App::on(…)` (custom-event capable) | shim |
| `app.quit` / `isQuitting` | `windows/main.js` close path, `tray.js` | `App::quit` | shim |
| `app.getName`/`getVersion` | menu version items | `App::name`/`version` | native |
| `app.getPath`/`getAppPath` | `config.js` | `App::get_path`/`set_path` | shim |
| `app.commandLine.appendSwitch` | `index.js` autoplay policy (not booted, §gap 5) | unmapped | **deferred** (unmapped) |
| `app.dock.setMenu`/`downloadFinished` | `dock.js` | needs #12 OS integration | **deferred** |
| `app.getLoginItemSettings` | `index.js` hidden-boot (not booted) | unmapped | **deferred** (unmapped) |

### Windows (all via `WindowManager`)

| Electron API | Used by app | Strake mapping | Status |
|---|---|---|---|
| `new BrowserWindow` ×3 (main 1024+ / hidden 150×150 worker / About 300×250) | `windows/{main,webtorrent,about}.js` | `WindowManager::create` | shim |
| `win.loadURL` (file:// static pages) | all three windows | `WebContents::load_url` | shim |
| `win.show`/`hide`/`close`/`focus`/`minimize`/`restore`/`maximize`/`unmaximize` | lifecycle, guards, `setBounds` | `WindowManager::{show,hide,close,focus,restore,minimize,maximize}` (`unmaximize` folds into `restore`) | shim |
| `win.setTitle`/`getTitle` | `setTitle` IPC, About title | `WindowManager::set_title` | shim |
| `win.isVisible`/`isMinimized`/`isMaximized`/`isFullScreen` | guards, tray toggle | `is_minimized`/`is_maximized` shimmed; `isVisible` unmapped | shim + **deferred** (`isVisible` unmapped) |
| `win.setAlwaysOnTop`/`isAlwaysOnTop` | Float-on-Top | `WindowManager::set_always_on_top` | shim |
| `win.setMenuBarVisibility` | fullscreen/About flows | unmapped shell bridge | **deferred** (unmapped) |
| `win.setBounds`/`getBounds`/`setContentBounds`/`setAspectRatio` | `setBounds` IPC + centering, aspect lock | unmapped geometry bridge | **deferred** (unmapped — core to this app's window mgmt) |
| `win.setProgressBar` | `setProgress` IPC | OS taskbar bridge | **deferred** |
| `win.webContents.send` | relay, `log()`, `dispatch()` | `WebContents::send` → `IpcBus::send` | shim |
| `win.webContents` `dom-ready`/`will-navigate` | menu sync, nav guard | renderer event bridge | shim (events) |
| `win.webContents.openDevTools`/`isDevToolsOpened` | `toggleDevTools`, View menu | devtools UI | **deferred** |
| `win.webContents.getTitle` (page title!) | wt-relay sender match | unmapped content query | **deferred** (unmapped) |
| `BrowserWindow webPreferences` (`nodeIntegration`, `enableRemoteModule`, …) | all three windows | N-API preload sandbox | **deferred** (needs #18) |

### IPC — the invoke/send round-trip

| Electron API | Used by app | Strake mapping | Status |
|---|---|---|---|
| `ipcMain.on` + `ipcRenderer.send` (~28 channels: dialogs, player, window ctl, shell, watcher…) | `ipc.js` | `IpcBus::on` / `IpcBus::send` | shim |
| `ipcMain.once` (`ipcReady`, `ipcReadyWebTorrent`, `stateSaved`) | `ipc.js`, `index.js` | `IpcBus::on` + self-removal | shim |
| `ipcMain.emit` relay patch + `messageQueueMainToWebTorrent` | `ipc.js:220` wt-* routing | `IpcBus::send` ordering guarantee | shim |
| `ipcMain.handle` + `ipcRenderer.invoke` | migrated form (RUN.sh §4; zero uses in tree) | `IpcBus::handle` / `IpcBus::invoke` | shim |
| `event.sender.send` / `event.returnValue` | reply style available | `IpcBus::send` | shim |
| `@electron/remote` (`enable`, renderer `remote`) | all windows, renderer controllers | removed-model; preload/`invoke` bridge | **deferred** (needs #18) |

### Menus / tray / dialogs / OS (deferred cluster)

| Electron API | Used by app | Blocker | Status |
|---|---|---|---|
| `Menu.buildFromTemplate`/`setApplicationMenu`/`getApplicationMenu`, submenu `Menu` normalisation, `MenuItem` | `menu.js` (7 sections), `tray.js`, `dock.js` | needs #12 native menus | **deferred** |
| `Tray` + `setContextMenu` + click | `tray.js` (linux/win32-gated) | needs #12 native tray | **deferred** |
| `dialog.showOpenDialogSync/showSaveDialogSync/showMessageBox*` | `dialog.js` (sync flavour!) | needs #12 native dialogs | **deferred** |
| `globalShortcut.register/unregister` (media keys) | `shortcuts.js` | OS global hotkeys | **deferred** |
| `shell.openExternal/showItemInFolder/moveItemToTrash` | `openPath`, trash flows | needs #12 OS integration | **deferred** |
| `screen.getDisplayMatching` | `setBounds` centering | winit monitor bridge | **deferred** |
| `clipboard`, `nativeTheme`, `powerSaveBlocker` | playback/clipboard flows | respective bridges | **deferred** |

## Key gaps (ordered by tier-3 impact)

1. **Window-geometry bridge (unmapped)** — `setBounds`/`getBounds`/
   `setContentBounds`/`setAspectRatio`/`isVisible`/`setMenuBarVisibility`
   have no TOP50 entry, yet this app manages windows almost entirely
   through them. Biggest functional gap after menus.
2. **Native menus/tray/dialogs (#12)** — full menu builds, tray context
   menu, and the *sync* dialog flavour record-but-cannot-render headlessly.
3. **`win.send()` normalisation** — the app calls `win.send(...)`
   (`windows/main.js:128`, `windows/webtorrent.js:57`); the documented
   `BrowserWindow` surface lists only `webContents.send`
   ([BrowserWindow docs](https://www.electronjs.org/docs/latest/api/browser-window),
   full method list checked — no `win.send`). The strake port normalises
   both call sites to the shimmed `WebContents::send` regardless.
4. **Renderer `remote` + `webPreferences` sandbox (#18)** — all windows
   set `nodeIntegration`/`enableRemoteModule`, and every
   `renderer-controller` uses `remote`; the strake path is preload +
   `invoke`, so these need porting, not shimming.
5. **Full entry not booted** — `src/main/index.js` pulls the renderer
   `State` stack, crash-reporter, auto-updater, folder-watcher and the
   `webtorrent` engine; booting it headless is the explicit non-goal.
   Player/external-player/folder-watcher IPC handlers are registered but
   unfired for the same reason. No `node_modules` was installed at any
   point; only `node --check` + the stub harness touch the tree.
6. **Renderer dispatch flows un-driven** — `dispatch('addTorrent')`,
   playback-controller round-trips need a DOM; the strake-vibey-script
   `ScriptDocument::from_html` + `execute_scripts` pattern (see
   `strake-vibey-script/tests/dom.rs`) is the intended driver once #18
   lands.

## Reproduce

```sh
git clone https://github.com/gregoreesmaa/webtorrent-desktop.git
cd webtorrent-desktop && git checkout strake-demo
./strake-demo/RUN.sh   # expect: 29/29 checks passed
```
