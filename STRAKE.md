# Running this app under Strake — status: blocked (issue gregoreesmaa/strake#151)

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

Observed output (Strake `main`, headless):

```text
app: webtorrent-desktop (main: index.js)
main: 1 JS error(s):
  - Uncaught JS error in <eval>: Error: Cannot find module './build/main' (unknown at :1:8)
windows: 0
ipc: round-trip FAILED (pumped 0)
```

## Why it stops

Entry chain: `package.json` `main` → `index.js` (`require('./build/main')`)
→ `build/` is babel output (`npm run build`: `babel src --out-dir build`),
absent from git — and even with it built, Strake's `require` serves only
`'electron'` plus Node core stand-ins. The real entry `src/main/index.js`
needs relative-file requires (`./ipc`, `./menu`, `./windows`, … across ~20
main-process files) and bare third-party specifiers, neither of which the
boot loader resolves:

- `@electron/remote/main` (`src/main/index.js:3`), `@electron/remote`
- `application-config`, `run-parallel`, `chokidar`, `auto-launch`, `winreg`, `vlc-command`, `simple-get`, `debounce`, `arch`, `webtorrent/package.json`
- Node cores beyond the stand-in table: `fs`, `child_process` (full `node:fs` is strake#16)

Further down the line the app also uses `app.commandLine`,
`app.getLoginItemSettings`, crash-reporter, Tray/Menu/dialog/ipc/shell,
`powerSaveBlocker`, auto-updater, and WebRTC (media streaming — Strake's
documented offscreen-fallback category), each to be mapped once boot reaches them.

## What unblocks it

1. [strake#151](https://github.com/gregoreesmaa/strake/issues/151) — relative-file + `node_modules` loader for app boot (the immediate blocker).
2. `npm run build` first (babel), or source-level support for it — build outputs are not in git.
3. `node:fs` and friends (strake#16), `@electron/remote` main-side init, then per-API mapping.

`strake-run` remains the `npm start` equivalent; this app just needs the loader before anything else can be proven.
