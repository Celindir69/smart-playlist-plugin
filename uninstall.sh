#!/bin/bash

echo "Uninstalling Smart Playlists"

# Deliberately NOT removing jq - it's a common general-purpose tool other
# plugins or the user's own scripts might also depend on. mpc is part of
# Volumio's base image and was never installed by this plugin anyway.
# Deliberately NOT removing generated playlists under /data/playlist/, the
# rules file or the manifest in /data/smart_playlists_data/ - those are the
# user's data, not plugin installation artifacts, and are meant to survive an
# uninstall/reinstall cycle. DO NOT add an "rm -rf" for
# /data/smart_playlists_data here.

# Only the debug log, the library cache (rebuilt on the next run) and the
# run lock go. The rules file and the manifest (which playlists this plugin
# created, so they can be cleaned up after a reinstall) stay.
D="${SMART_PLAYLISTS_WORK_DIR:-/data/smart_playlists_data}"   # SMART_PLAYLISTS_WORK_DIR: tests only
if [ -d "$D" ]; then
  rm -f "$D/smart_playlists.debug.log" "$D/smart_playlists.debug.log.1" "$D/.smart_playlists_cache.tsv" "$D/.smart_playlists.lock"
fi

echo "pluginuninstallend"
