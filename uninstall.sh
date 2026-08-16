#!/bin/bash

echo "Uninstalling Smart Playlists"

# Deliberately NOT removing exiftool/jq - they're common general-purpose
# tools other plugins or the user's own scripts might also depend on.
# Deliberately NOT removing generated playlists under /data/playlist/ or
# /data/smart_playlists_data/ (rules file, cache, manifest, debug log) -
# those are the user's data, not plugin installation artifacts, and are
# meant to survive an uninstall/reinstall cycle. DO NOT add an "rm -rf"
# for /data/smart_playlists_data here.

echo "pluginuninstallend"
