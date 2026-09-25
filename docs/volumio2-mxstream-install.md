# Installing on Volumio 2 / OEM devices (e.g. Musical Fidelity MX-Stream)

This plugin's `package.json` declares `"volumio": ">=3"`, but that constraint
is **not actually enforced anywhere** in Volumio's install pipeline - it's
just documentation. In practice the plugin runs fine on a Volumio 2 OEM
build too, as long as two device-specific problems (neither one related to
the plugin's own code) are worked around. This was confirmed live on an
actual device: a Musical Fidelity MX-Stream ("mxstream"), Volumio 2,
`VOLUMIO_VERSION=1.079`, Node `v8.11.1`, npm `5.6.0`.

The same two problems affect `volumio-autodj-plugin` (the sibling AutoDJ
plugin) on the same device/device class, so everything below applies there
too.

## Problem 1: `volumio plugin install` hangs forever

Running the official CLI:

```bash
volumio plugin install
```

compresses the plugin and prints `Plugin succesfully compressed`, then just
**hangs indefinitely** - no error, no timeout, and critically, **nothing at
all shows up in `journalctl -u volumio`**, even with `-f` tailing live
through the whole hang.

### What we ruled out

Both of these looked like plausible causes and were checked directly against
the live backend source (`/volumio/app/...`) before being ruled out:

- **A confirmation-modal gate.** The backend's websocket handler for
  `installPlugin` checks
  `process.env.WARNING_ON_PLUGIN_INSTALL === 'true' && data.confirm !== true`
  and would otherwise wait for a confirmation round-trip. Checked directly via
  `/proc/<backend-pid>/environ` - not set on this device, so this isn't it.
- **A detached/misconfigured `websocketServer`.** Traced
  `PluginManager.prototype.pushMessage` -> `coreCommand.broadcastMessage` ->
  the actual `websocketServer` instance through `pluginContext.js` and
  `pluginmanager.js` - correctly wired.

### What's actually happening

A raw diagnostic script (plain `socket.io-client`, connecting directly to
`http://127.0.0.1:3000` and logging **every** incoming event via an
`socket.onevent` override, not just the ones we expected) showed that the
backend's `installPlugin` handler is **never even invoked** when the
official CLI (`/volumio/pluginhelper.js`) runs. The CLI's own socket emit
goes out, but nothing on the backend reacts to it. The exact mechanism
was never fully pinned down (candidates: a `socket.io` client/server version
mismatch between what `pluginhelper.js` bundles and what the backend
expects; the CLI's emit not including `confirm: true`, which the backend
may silently require despite the env var above being unset) - but it
didn't need to be, once a reliable workaround was found (see below).

**This makes the plain CLI unusable on this device, full stop, regardless of
which user runs it.**

## Problem 2: silent permission failures from the wrong Unix user

Independently of Problem 1: this device's SSH login user is `volumiooem`,
but Volumio's own backend process runs as `volumio`
(confirmed via `ps -o user= -p <backend-pid>`). If any install step runs as
`volumiooem`:

- Files the backend needs to move (e.g. the uploaded plugin zip under
  `/tmp/plugins/`) end up owned by `volumiooem`, and the backend's own
  `/bin/mv`/file-move logic then fails with a silent
  `Permission denied` - no error surfaces to the CLI or the UI.
- After a plugin is installed and enabled, its own data directories under
  `/data/...` can end up root-owned instead (typically because an old
  cron job that predates the plugin install ran as root and created them
  first) - the plugin then crash-loops trying to write its log/state files
  there.

**Always run every install/update step as the `volumio` user**
(`su volumio`, or SSH directly as `volumio@mxstream.local` if that login is
enabled), and chown any pre-existing state directories to `volumio:volumio`
before installing.

## The permanent workaround

`scripts/install-mxstream.sh` in this repo (copy it to the device, or paste
it directly over SSH) does all of the following:

1. Refuses to run as anyone but `volumio`.
2. `chown -R volumio:volumio` on the plugin's known state directories
   (`/data/smart_playlists_data`, `/data/playlist`) in case an old cron job
   created them first.
3. Clones/updates the plugin source into a **fixed, dedicated build
   directory** (`~/smart-playlist-plugin-build`) and does a hard reset to a
   specific branch - deliberately not an ambiguous path like
   `~/smart-playlist-plugin`, since a stray older clone sitting there once
   silently shadowed a real build and shipped stale dependencies (see the
   `fs-extra` note below).
4. Deletes any existing `node_modules`/`package-lock.json` before
   `volumio plugin package` (which runs `npm install` + zips) - `npm
   install` only actually runs when `node_modules` is missing, so a stale
   `node_modules` from an earlier, broken build would otherwise get shipped
   unchanged forever, even after fixing `package.json`.
5. **Bypasses `volumio plugin install` entirely** and talks to the backend's
   own `socket.io` API directly - the same way the CLI does internally, just
   with a client that actually works on this device:
   - connects to `http://127.0.0.1:3000` with `socket.io-client`
     (`reconnection: true`)
   - emits `installPlugin` with `{url: 'http://127.0.0.1:3000/plugin-serve/<name>.zip', confirm: true}`
   - listens for `installPluginStatus` events until `progress === 100`
   - **does not exit on `connect_error`** - logs it and lets socket.io's
     built-in reconnection retry, with a `reconnect` handler that re-emits
     `installPlugin` if the first attempt didn't land (an earlier version of
     this script called `process.exit(1)` here, which turned a transient
     connection hiccup - e.g. the backend being briefly busy right after the
     preceding `npm install`/zip step - into a hard failure)
   - only gives up after a 90s overall timeout with no completion event

For a **pure code change with no dependency changes** (i.e. `package.json`
untouched), re-running the full install script will fail with
`Error: Plugin smart_playlists already exists`, since the plugin is already
installed. In that case, skip the install pipeline entirely and just copy
the changed file(s) directly into the already-installed plugin folder,
then restart:

```bash
cd ~/smart-playlist-plugin-build
git fetch origin <branch>
git checkout <branch>
git reset --hard "origin/<branch>"

sudo cp index.js /data/plugins/user_interface/smart_playlists/index.js
sudo chown volumio:volumio /data/plugins/user_interface/smart_playlists/index.js

sudo systemctl restart volumio
```

## Related device-specific issues found along the way

These aren't install-pipeline problems, but were found and fixed in the same
round of testing on this device and are worth knowing about if you hit
something similar:

- **`fs-extra@^10.0.0` doesn't run on Node v8.11.1.** Its syntax
  (`lib/empty/index.js`) isn't valid on this old V8. Pin `fs-extra` to
  `^8.1.0` for Volumio 2 compatibility (matches what `autodj-plugin` already
  uses). On this device the failure didn't just stop the plugin from
  loading - it cascaded into an **uncaught `TypeError` in Volumio's own core
  code** (via the bundled `airplay_emulation` plugin's `onStart`), which
  crashed the entire backend process and put `systemd` into a ~10s
  crash-restart loop with no music playback and no web UI at all. Recovery
  in that situation is: stop `volumio`, delete the plugin's installed folder
  under `/data/plugins/...`, remove its entry from
  `/data/configuration/plugins.json`, restart.
- **`getI18nString('SMART_PLAYLISTS.*')` throws on this core.**
  `CoreCommandRouter.loadI18nStrings()` on this Volumio 2 build only ever
  reads its own `/volumio/app/i18n/strings_en.json` - there's no code path
  anywhere in `pluginmanager.js` that merges a plugin's own
  `i18n/strings_*.json` into that table. Any `getI18nString('SMART_PLAYLISTS.*')`
  call therefore throws (`Cannot read property 'X' of undefined`) instead of
  returning a string. `index.js`'s `ControllerSmartPlaylists.prototype.i18n()`
  wrapper works around this by falling back to a hardcoded English string
  whenever the core lookup throws or comes back empty, while still using
  real translations on cores where plugin i18n does get loaded.
- A symlinked data file (`smart_playlists.txt` pointed at a Samba-shared
  `/mnt/INTERNAL/...` path) can end up owned by `nobody:nogroup` if it's
  ever edited from a network client, breaking the plugin's own writes with
  `EACCES` even though `/data/smart_playlists_data` itself is correctly
  owned. If you don't need to edit the rules file directly over the network
  share, let the plugin manage a plain file under its own data directory
  instead of symlinking it elsewhere.
