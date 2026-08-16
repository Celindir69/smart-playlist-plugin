#!/bin/bash

echo "Installing Smart Playlists dependencies"

install_deps() {
  sudo apt-get update
  sudo apt-get -y install --no-install-recommends libimage-exiftool-perl jq
}

install_deps

# Verify both tools actually made it onto the system. apt-get can fail
# silently/partially (e.g. a transient network hiccup right after boot,
# before networking is fully up) without the failure being obvious in the
# install log - this happened in practice. Retry once before giving up.
check_missing() {
  MISSING=""
  command -v exiftool >/dev/null 2>&1 || MISSING="$MISSING exiftool"
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
    echo "Smart Playlists will NOT work until these are installed. Try"
    echo "manually once your network connection is confirmed working:"
    echo "  sudo apt-get update"
    echo "  sudo apt-get install -y libimage-exiftool-perl jq"
    echo "==================================================================="
  else
    echo "OK: all dependencies present after retry"
  fi
else
  echo "OK: all dependencies present"
fi

# Make sure the bundled core script is executable (should already be from
# the zip, but be defensive).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
chmod +x "$SCRIPT_DIR/smart-playlists-core.sh"

# Internal data directory (rules file, cache, manifest, debug log) -
# deliberately outside both the music folder and this plugin's own
# install folder, so it survives a "volumio plugin uninstall" +
# reinstall cycle (unlike this plugin's own config.json).
sudo mkdir -p /data/smart_playlists_data
sudo chown -R volumio:volumio /data/smart_playlists_data

# required to end the plugin install
echo "plugininstallend"