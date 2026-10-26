#!/bin/bash

echo "Installing Smart Playlists dependencies"

# A failed installation leaves nothing behind (no half-installed plugin in
# Volumio's list).
PLUGIN_DIR="$(cd "$(dirname "$0")" && pwd -P)"
fail() {
  echo "Smart Playlists installation failed: $1"
  case "$PLUGIN_DIR" in /data/plugins/*) rm -rf "$PLUGIN_DIR" ;; esac
  echo "plugininstallend"
  exit 1
}

install_deps() {
  sudo apt-get update
  sudo apt-get -y install --no-install-recommends jq
}

install_deps

# Verify jq actually made it onto the system. apt-get can fail
# silently/partially (e.g. a transient network hiccup right after boot,
# before networking is fully up) without the failure being obvious in the
# install log - this happened in practice. Retry once before giving up.
check_missing() {
  MISSING=""
  command -v jq >/dev/null 2>&1 || MISSING="$MISSING jq"
}

check_missing

if [ -n "$MISSING" ]; then
  echo "Warning: missing after first attempt:$MISSING - retrying in 5s..."
  sleep 5
  install_deps
  check_missing

  if [ -n "$MISSING" ]; then
    echo "==================================================================="
    echo "ERROR: still missing after retry:$MISSING"
    echo "Smart Playlists does not work without it. Install the plugin again"
    echo "once the network connection is working."
    echo "==================================================================="
    fail "missing:$MISSING"
  else
    echo "OK: all dependencies present after retry"
  fi
else
  echo "OK: all dependencies present"
fi

# "mpc" (talks to Volumio's own MPD instance, where all metadata comes
# from) is part of Volumio's base image on a correctly installed system -
# nothing to install here, just verify it's actually there and warn
# loudly if it somehow isn't, rather than failing silently at runtime.
if ! command -v mpc >/dev/null 2>&1; then
  echo "==================================================================="
  echo "WARNING: 'mpc' was not found. This should be part of a standard"
  echo "Volumio installation - Smart Playlists needs it to read metadata"
  echo "from Volumio's own MPD instance and will NOT work without it."
  echo "==================================================================="
fi

# Make sure the bundled core script is executable (should already be from
# the zip, but be defensive).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
chmod +x "$SCRIPT_DIR/smart-playlists-core.sh"

# Internal data directory (rules file, cache, manifest, debug log) -
# deliberately outside both the music folder and this plugin's own
# install folder, so it survives a "volumio plugin uninstall" +
# reinstall cycle (unlike this plugin's own config.json).
sudo mkdir -p /data/smart_playlists_data || fail "mkdir /data/smart_playlists_data"
sudo chown -R volumio:volumio /data/smart_playlists_data

# required to end the plugin install
echo "plugininstallend"