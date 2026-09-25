#!/bin/bash
# Installs (or reinstalls) this plugin on a Volumio 2 / OEM device where the
# official "volumio plugin install" CLI hangs forever. See
# docs/volumio2-mxstream-install.md for the full story of why this is
# needed and what each step works around. Confirmed working on a Musical
# Fidelity MX-Stream ("mxstream"), Volumio 2, Node v8.11.1.
#
# For a pure code change with NO dependency changes, don't re-run this -
# it'll fail with "Plugin smart_playlists already exists". Instead copy the
# changed file(s) straight into the installed plugin folder and restart -
# see docs/volumio2-mxstream-install.md.
set -euo pipefail

BRANCH="${SMART_PLAYLISTS_BRANCH:-main}"

if [[ "$(whoami)" != "volumio" ]]; then
  echo "Error: this must be run as the 'volumio' user (currently: $(whoami))." >&2
  echo "Try: su volumio    (or: ssh volumio@mxstream.local)" >&2
  exit 1
fi

echo "--- Fixing ownership of any pre-existing state directories ---"
for dir in /data/smart_playlists_data /data/playlist; do
  if [[ -d "$dir" ]]; then
    echo "chown -R volumio:volumio $dir"
    sudo chown -R volumio:volumio "$dir"
  fi
done

# Fixed, dedicated build directory - deliberately not an ambiguous path like
# "~/smart-playlist-plugin", since a stray older clone sitting there once
# silently shadowed this build and shipped a stale package.json.
BUILD_DIR="$HOME/smart-playlist-plugin-build"

echo "--- Fetching the plugin (branch: $BRANCH) ---"
if [[ -d "$BUILD_DIR/.git" ]]; then
  (cd "$BUILD_DIR" && git fetch origin "$BRANCH" && git checkout "$BRANCH" && git reset --hard "origin/$BRANCH")
else
  git clone --branch "$BRANCH" https://github.com/Celindir69/smart-playlist-plugin.git "$BUILD_DIR"
fi
cd "$BUILD_DIR"
echo "Using commit: $(git log --oneline -1)"

PKG_NAME="$(node -e "console.log(require('./package.json').name)")"

echo "--- Cleaning any stale build (old node_modules can ship an incompatible dependency version even after package.json is fixed) ---"
rm -rf node_modules package-lock.json

echo "--- Packaging (npm install + zip, same as 'volumio plugin package') ---"
volumio plugin package

echo "--- Moving package into place for the backend to serve ---"
mkdir -p /tmp/plugins
mv "${PKG_NAME}"*.zip "/tmp/plugins/${PKG_NAME}.zip"

echo "--- Installing via the backend's socket.io API directly (bypasses the hanging CLI) ---"
cat > /tmp/install_via_socket.js <<JSEOF
var io = require('/volumio/node_modules/socket.io-client');
var socket = io.connect('http://127.0.0.1:3000', {reconnection: true});
var done = false;
var emitted = false;

function sendInstall() {
  socket.emit('installPlugin', {url: 'http://127.0.0.1:3000/plugin-serve/${PKG_NAME}.zip', confirm: true});
  emitted = true;
}

socket.on('connect', function () {
  console.log('Connected, sending install request...');
  sendInstall();
});

socket.on('reconnect', function () {
  console.log('Reconnected.');
  if (!emitted || !done) {
    sendInstall();
  }
});

socket.on('installPluginStatus', function (data) {
  console.log('[' + data.progress + '%] ' + data.message);
  if (data.progress === 100) {
    done = true;
    console.log('');
    console.log(done_message(data.message));
    socket.close();
    process.exit(0);
  }
});

function done_message(msg) {
  return msg.toLowerCase().indexOf('erfolgreich') !== -1 || msg.toLowerCase().indexOf('success') !== -1
    ? 'Done: ' + msg
    : 'Finished, but check this message for errors: ' + msg;
}

// Do NOT exit here - socket.io reconnects automatically on transient
// errors (e.g. the backend being briefly busy right after the preceding
// npm install/zip step). Only the timeout below gives up.
socket.on('connect_error', function (err) {
  console.error('Connection error (will keep retrying): ' + (err && err.message ? err.message : err));
});

setTimeout(function () {
  if (!done) {
    console.error('Timed out after 90s with no completion event - check "sudo journalctl -u volumio -f" for what the backend is doing.');
    process.exit(1);
  }
}, 90000);
JSEOF
node /tmp/install_via_socket.js
rm -f /tmp/install_via_socket.js

echo ""
echo "Enable it under Settings -> Plugins -> Installed Plugins -> Smart Playlists."
