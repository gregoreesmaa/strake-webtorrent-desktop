# Running this app under Strake — status: blocked (strake#151 closed; re-probed, entry build still missing)

This fork is **pristine upstream**
[`webtorrent/webtorrent-desktop`](https://github.com/webtorrent/webtorrent-desktop)
plus this file — no app source was changed. It does **not** boot under
[Strake](https://github.com/gregoreesmaa/strake) yet. This file records the
swap attempt, the exact failure, and what unblocks it.

## Attempt

```sh
# In a Strake checkout:
cargo run -rp strake-run -- --prove-ipc /path/to/strake-webtorrent-desktop
```

Observed output (Strake `a2195568`, headless — re-probed 2026-09-13 after the strake#151 loader landed; identical failure):

```text
app: webtorrent-desktop (main: index.js)
main: 1 JS error(s):
  - Uncaught JS error in <eval>: Error: Cannot find module './build/main' (unknown at :1:8)
    at <main> (unknown at :1:8)
windows: 0
ipc: round-trip FAILED (pumped 0)
```

## Why it stops

Entry chain: `package.json` `main` → `index.js` (`require('./build/main')`)
→ `build/` is babel output (`npm run build`: `babel src --out-dir build`),
absent from git (as is `node_modules/`). The strake#151 loader (relative-file
+ `node_modules` resolution, extension/index probing, `package.json` main,
module cache with circular support) has since landed, so once `build/` and
`node_modules/` exist the real entry `src/main/index.js` should resolve its
relative-file requires (`./ipc`, `./menu`, `./windows`, … across ~20
main-process files) and bare third-party specifiers. What it will meet next:

- `@electron/remote/main` (`src/main/index.js:3`), `@electron/remote`
- `application-config`, `run-parallel`, `chokidar`, `auto-launch`, `winreg`, `vlc-command`, `simple-get`, `debounce`, `arch`, `webtorrent/package.json`
- Node cores beyond the stand-in table: `fs`, `child_process` (full `node:fs` is strake#16)

Further down the line the app also uses `app.commandLine`,
`app.getLoginItemSettings`, crash-reporter, Tray/Menu/dialog/ipc/shell,
`powerSaveBlocker`, auto-updater, and WebRTC (media streaming — Strake's
documented offscreen-fallback category), each to be mapped once boot reaches them.

## What unblocks it

1. ~~[strake#151](https://github.com/gregoreesmaa/strake/issues/151) — relative-file + `node_modules` loader~~ ✅ closed (relative-file + `node_modules` resolution, module cache with circular support; re-probe above confirms boot now gets exactly as far as the missing build output allows).
2. `npm install` + `npm run build` (babel) — build outputs and `node_modules/` are not in git, and the failure above is now purely their absence.
3. `node:fs` and friends (strake#16), `@electron/remote` main-side init, then per-API mapping.

`strake-run` remains the `npm start` equivalent; this app next needs its build outputs before anything else can be proven.
