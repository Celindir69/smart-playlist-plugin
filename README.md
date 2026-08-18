# Volumio Smart Playlists

Automatically builds native Volumio playlists from a plain text file of
rules - artist lists with optional AND/OR filters on album, genre, year,
title, track number, duration, BPM, and days-since-added, plus custom sort
order, track limits, and deduplication (e.g. when a best-of/live compilation
and the original studio album are both in your library).

Available two ways:
- **As a Volumio plugin** (recommended) - a settings page in the Volumio UI
  to edit rules, set a daily schedule, and trigger a run, no SSH needed for
  day-to-day use.
- **As a standalone bash script** - for anyone who'd rather manage it by
  hand via SSH/cron/systemd.

Both share the exact same underlying logic (the plugin just wraps the
script). Tested with a ~25,000 track FLAC/MP3/M4A/DSF/OGG library spread
across Internal Storage, a USB drive, and a NAS share on Volumio 3.

## What it does

- Reads a text file where each line describes one playlist you want built
  (artist name(s), optionally with filters).
- **Scans all of Volumio's standard music sources automatically** - Internal
  Storage, USB, and NAS - no path configuration needed. A source that isn't
  present on your system (e.g. no NAS connected) is silently skipped.
- Reads metadata (AlbumArtist, Artist, Title, Album, Genre, Year, Track,
  Duration) directly from **Volumio's own MPD database** via `mpc` - the
  same index that powers Browse/Search, so there's no separate per-file
  scan to wait for at all (a ~24k track library that used to take ~20
  minutes on first run now takes a couple of seconds, every run). Falls
  back automatically to the original `exiftool`-based full scan (with its
  incremental cache) if `mpc`/MPD isn't reachable for any reason. BPM -
  the one thing MPD doesn't track - still comes from `exiftool`, but only
  runs when a rule actually uses a `bpm` filter, and only for new/changed
  files. See "MPD integration" below.
- Supports `.flac`, `.mp3`, `.m4a`, `.dsf`, `.ogg`, `.opus`, `.aiff`/`.aif`,
  and `.ape` out of the box - configurable via the `AUDIO_EXTENSIONS` array
  in the script (see "Notes / limitations" below for why `.wav`/`.wma`
  aren't included by default).
- Writes native Volumio playlists (JSON files under `/data/playlist/`) so
  they show up directly in Volumio's own Playlist view - no manual import
  needed.
- Automatically removes playlists it previously created that are no longer
  present in your rules (orphan cleanup via a manifest file).

## Requirements

- Volumio 3
- `jq` (always required) and `mpc` (used to talk to Volumio's own MPD - it's
  part of Volumio's base image, nothing to install). The plugin installs
  `jq` automatically; for the standalone script:
  ```bash
  sudo apt-get update
  sudo apt-get install -y jq
  ```
- `exiftool` is only needed as a fallback (MPD unreachable) or for BPM
  filters - install it too if you're not sure you'll need it:
  ```bash
  sudo apt-get install -y libimage-exiftool-perl
  ```

## Installation - Plugin (recommended)

1. On your Volumio device (via SSH), set up the plugin dev workflow once:
   ```bash
   volumio plugin init
   ```
   Category: `user_interface`. Name: `smart_playlists` (if you pick a
   different name, you'll need to update the `endpoint` values in
   `UIConfig.json` and the `plugin_type`/name in `package.json` to match).
2. Copy all the plugin files (`index.js`, `UIConfig.json`, `config.json`,
   `package.json`, `install.sh`, `uninstall.sh`, `smart-playlists-core.sh`,
   `i18n/strings_en.json`) into the folder that command created.
3. Install it:
   ```bash
   volumio plugin install
   ```
4. Restart Volumio once after install (and after every future update):
   ```bash
   sudo systemctl restart volumio
   ```
5. In the Volumio UI, go to **Plugins → Installed Plugins → Smart
   Playlists** (gear icon) to configure it.

### Updating the plugin later

Prefer `volumio plugin refresh` (copies changed files into the running
install) over uninstalling and reinstalling - uninstalling deletes the
plugin's saved settings, which will wipe your schedule and (if the rules
file has already been folded into config) your rules too:
```bash
cd /path/to/your/plugin/source/folder
volumio plugin refresh
sudo systemctl restart volumio
```
The restart is not optional - Volumio doesn't pick up refreshed plugin code
without it.

## Installation - Standalone script

1. Download `volumio-smart-playlists.sh` and copy it to your Volumio
   device, e.g. `/usr/local/bin/volumio-smart-playlists.sh`.
2. Make it executable:
   ```bash
   sudo chmod +x /usr/local/bin/volumio-smart-playlists.sh
   ```
3. That's it - no path configuration needed, it scans Internal Storage,
   USB, and NAS automatically (see "Multi-source scanning" below if your
   setup is non-standard).

## Where the plugin stores its data

Rules, the metadata cache, the cleanup manifest, and the debug log all live
under `/data/smart_playlists_data/` - deliberately **not** inside your
music folder (so you won't accidentally edit/delete it while browsing your
music share) and **not** inside the plugin's own install folder under
`/data/plugins/...` (so it survives an uninstall/reinstall cycle, unlike
the plugin's regular settings).

The standalone script defaults to the same location. Override it via the
`SMART_PLAYLISTS_WORK_DIR` environment variable if you'd rather keep it
elsewhere.

## Multi-source scanning

Volumio 3's three standard music sources are scanned by default:

| Source | Scanned directory | Playlist `uri` format |
|---|---|---|
| Internal Storage | `/data/INTERNAL` | `music-library/INTERNAL/<relative path>` |
| USB | `/media/<drive-label>` | `music-library/USB/<relative path>` |
| NAS | `/mnt/NAS/<share-name>` | `<relative path>` (no prefix at all) |

USB and NAS were verified against playlists Volumio itself created for
tracks from each source - note NAS genuinely uses a **different** uri
scheme (the raw filesystem path, no `music-library/` prefix, no label) than
USB/Internal Storage. Internal Storage follows the same structural pattern
as USB but wasn't independently confirmed against every possible setup.

Override the whole list via the `SMART_PLAYLISTS_SOURCES` environment
variable if your setup differs - newline-separated entries of the form
`scan_dir|uri_root|uri_prefix`:
- `scan_dir`: directory to search for audio files in
- `uri_root`: prefix stripped from a file's absolute path to build the
  relative part of the `uri`
- `uri_prefix`: prepended to that relative path to form the final `uri`
  (empty for NAS-style raw paths)

If tracks from a source don't play, create a playlist for that source
manually in the Volumio UI and inspect its `uri` field under
`/data/playlist/` to see the actual format your system uses, then adjust
`SMART_PLAYLISTS_SOURCES` accordingly.

**Note:** the table above describes the **legacy** (`exiftool`/filesystem)
scan path. The default MPD path (see below) determines a track's source
differently - via the path MPD itself reports - and only falls back to
scanning `SMART_PLAYLISTS_SOURCES` directly if MPD is unavailable.

## MPD integration

By default, metadata comes from Volumio's own MPD instance (`mpc search any
""`) rather than from scanning files with `exiftool` one by one - MPD
already has the whole library indexed for Browse/Search, so this is both
far faster and one less thing to keep in sync. This is tried first on every
run and needs no configuration; if `mpc` is missing or MPD doesn't respond,
the script logs a warning and transparently falls back to the exiftool-based
scan described above, so a broken/unusual MPD setup won't stop playlists
from being generated.

What this means in practice:
- **Artist, Album, Title, Genre, Year, Track, Duration**: come from MPD.
  No incremental cache is needed for these - a single MPD query is fast
  enough to just re-run in full on every invocation.
- **BPM**: MPD has no BPM tag at all (verified against a real MPD 0.24
  instance - it's not in MPD's own list of valid tag/search types). If a
  rule uses a `bpm` filter, `exiftool` runs a lightweight, BPM-only,
  incrementally-cached pass (`.smart_playlists_bpm_cache.tsv` in the work
  directory) - only for new/changed files, and only if `bpm` is actually
  used somewhere in your rules.
- **`added`** (days since added): MPD doesn't track this either, so it
  still comes from the file's filesystem mtime via a plain `find` pass (no
  `exiftool` involved - just listing files and their timestamps, which is
  fast regardless of library size).
- **uri source mapping**: MPD reports each file's path relative to its own
  `music_directory` (default `/var/lib/mpd/music`), prefixed with the same
  source label Volumio itself uses (e.g. `INTERNAL/Artist/Album/Track.mp3`).
  That label is mapped to a playlist `uri` prefix via
  `SMART_PLAYLISTS_URI_PREFIXES` (newline-separated `label|uri_prefix`
  entries, default:
  ```
  INTERNAL|music-library/
  USB|music-library/
  NAS|mnt/
  ```
  ). **INTERNAL and USB are verified against a real device; NAS is
  carried over from the legacy path's (independently verified) uri scheme
  but was NOT tested against MPD's own NAS path format** - if you use a
  NAS source, check the debug log for a "no configured uri prefix"
  warning and adjust `SMART_PLAYLISTS_URI_PREFIXES` if needed.

Relevant environment variables (standalone script) / equivalent behavior
(plugin, same defaults):
- `SMART_PLAYLISTS_MPD_MUSIC_DIR` - MPD's `music_directory` (default
  `/var/lib/mpd/music`; check `grep music_directory /etc/mpd.conf` if
  unsure).
- `SMART_PLAYLISTS_MPD_TIMEOUT` - seconds to wait for MPD before giving up
  and falling back to the legacy scan (default `120`).
- `SMART_PLAYLISTS_URI_PREFIXES` - see above.

## Input file format

**Plugin**: edit rules directly in the plugin's settings page (Playlist
Rules section - one line per field, up to 30 lines; Volumio's UI framework
doesn't support a proper multi-line text box, so it's 30 separate single-
line fields instead).

**Standalone script**: create `smart_playlists.txt` inside
`/data/smart_playlists_data/` (or wherever `SMART_PLAYLISTS_WORK_DIR`
points). One line per playlist:

```
[Playlist Name::]Artist1;Artist2;Artist3[|field<op>value[,field<op>value...]|...][|duplicate=true|false]
```

Whitespace around `::`, `;`, `|`, `,`, and operators (`=`, `~`, `>=`, etc.)
is ignored, so feel free to format for readability, e.g.:
```
Classic Rock 70s :: Genesis ; Supertramp ; Pink Floyd | album !~ Live | year >= 1973 | sort = year +
```
is exactly equivalent to the more compact
`Classic Rock 70s::Genesis;Supertramp;Pink Floyd|album!~Live|year>=1973|sort=year+`.

- Lines starting with `#` (optionally indented) are treated as comments and
  skipped.
- Blank lines are skipped.
- **Artist list**: any number of artist names separated by `;`, combined
  with OR (a track matches if its AlbumArtist matches *any* of them).
  Matching is case-insensitive and ignores spaces/dashes/underscores/dots.
- **`*` (wildcard artist)**: use `*` instead of an artist list to match
  tracks from **any** artist - useful for library-wide playlists that
  only filter on non-artist fields, e.g. `Recently Added::*|added<5`.
  The `*` must be followed by `|` (i.e. it needs to be its own segment,
  same as a real artist list would be) - a completely blank artist
  section without `*` and without a leading `|` right after `::` can't
  be reliably told apart from a filter and will be treated as an
  (unmatchable) artist name instead.
- **Playlist name** (optional): put a name followed by `::` before the
  artist list to control the exact filename/display name in Volumio.
  Without it, the name is derived automatically from the line.
- **Filters** (optional): any number of `|`-separated segments, combined
  with **AND**. Within a single segment, separate conditions with `,` to
  combine them with **OR**:
  ```
  |fieldA<op>valA,fieldB<op>valB|fieldC<op>valC
  ```
  means `(fieldA OR fieldB) AND fieldC` - i.e. conjunctive normal form
  (AND of ORs), which covers the vast majority of real-world queries
  without needing full parenthesized boolean expressions.
  - Fields: `album`, `genre`, `year`, `title`, `artist`, `track`,
    `duration` (seconds), `bpm`, `added` (days since the file's mtime -
    see caveat below)
  - Operators: `=`, `!=`, `~` (contains), `!~` (does not contain), `>`,
    `>=`, `<`, `<=`
  - Numeric comparisons (`>`, `>=`, `<`, `<=`) apply to `year`, `track`,
    `duration`, `bpm`, and `added`.
  - Note: if a value legitimately contains a comma, it will be
    mis-parsed as an OR split - this is a known limitation.
- **`duplicate=false`** (optional, special field, must be its own `|`
  segment): deduplicates the resulting playlist by normalized track title,
  keeping only the first match per title. Default is `true` (duplicates
  allowed, i.e. original behavior).
- **`sort=<key><+|-><key><+|->...`** (optional, special field, must be its
  own `|` segment): controls the track ORDER in the generated playlist
  instead of the default random shuffle.
  - Keys: `title`, `track`, `artist`, `album`, `year`, `added`
  - `+` = ascending, `-` = descending; direction defaults to `+` if
    omitted (e.g. `sort=title` behaves like `sort=title+`)
  - Keys are concatenated directly with no separator, e.g.
    `sort=album-track+` sorts by album Z->A, then by track number 1->N
    within each album - a typical "grouped by album, tracks in order"
    listing. `sort=added+` puts the most recently added tracks first.
  - `sort=random` (or omitting `sort` entirely) keeps the original random
    order.
  - If the spec can't be parsed (e.g. a typo'd field name), the **whole**
    sort spec is discarded and the playlist falls back to random order -
    check the log for "Invalid sort spec" rather than getting a
    silently wrong partial sort.
- **`limit=N`** (optional, special field, must be its own `|` segment):
  caps the playlist at the first N tracks *after* filtering and sorting.
  Combine with `sort=` for "top N" style playlists, e.g.
  `sort=added+|limit=10` for "10 most recently added tracks", or
  `sort=duration-|limit=20` for "20 longest tracks". An invalid (non-
  numeric or zero) value is logged and ignored (no limit applied).

### Examples

```
# Simple: every track from these three artists
Genesis;Supertramp;Pink Floyd

# Custom playlist name
Classic Rock 70s::Genesis;Supertramp;Pink Floyd

# AND filters: no live albums, only 1973-1979
Classic Rock 70s::Genesis;Supertramp;Pink Floyd|album!~Live|year>=1973|year<=1979

# OR within a filter: title contains "Mix" OR album is exactly "12'' Ers"
Simply Red Mixes::Simply Red|title~Mix,album=12'' Ers

# Deduplicate: best-of and studio albums both in the library,
# but each song should only appear once
Queen Best-Of::Queen|duplicate=false

# Fast, long tracks
Long Uptempo::Genesis|duration>300|bpm>=120

# Sorted instead of shuffled: group by album (Z-A), tracks in order (1-N)
Genesis Albums In Order::Genesis|sort=album-track+

# Recently added tracks (based on file mtime), newest 15 only
New Genesis::Genesis|added<30|sort=added+|limit=15

# Wildcard artist: library-wide, not tied to any specific artist,
# pulls from Internal Storage, USB, and NAS all at once
Recently Added (All Artists)::*|added<5|limit=20

# Combined: everything together
70s Rock, No Live Duplicates::Genesis;Supertramp;Pink Floyd|album!~Live|year>=1973|year<=1979|duplicate=false
```

## Usage (standalone script)

Manual run:
```bash
/usr/local/bin/volumio-smart-playlists.sh
```

Debug run (verbose trace to stderr):
```bash
DEBUG=1 bash -x /usr/local/bin/volumio-smart-playlists.sh 2> /tmp/debug.log
```

The script also writes its own log (with timestamps) to
`/data/smart_playlists_data/smart_playlists.debug.log` on every run,
independent of `DEBUG`. Follow it live during/after a run:
```bash
tail -f /data/smart_playlists_data/smart_playlists.debug.log
```

### Running on a schedule

**Plugin**: toggle "Run automatically" and set a daily time in the
Schedule section of the plugin's settings page - no cron/systemd needed.

**Standalone script**: you don't strictly need cron - Volumio uses systemd
as its init system, so systemd timers work too and don't require
installing anything extra. Pick whichever you're more comfortable with.

**Option A: cron**

Cron is usually already present on Volumio (it's Debian-based), but the
cron *service* is sometimes not enabled to start on boot - there are
several reports of this in the Volumio community. Check first:
```bash
crontab -l
systemctl status cron
```
If cron is present but not running/enabled:
```bash
sudo systemctl enable --now cron
```
Only if `cron`/`crontab` is genuinely missing:
```bash
sudo apt-get install -y cron
```

Then edit the system crontab:
```bash
sudo nano /etc/crontab
```
Add (daily at 3 AM):
```
0 3 * * * volumio /usr/local/bin/volumio-smart-playlists.sh >> /home/volumio/cron_playlists.log 2>&1
```

If `exiftool` or `jq` live outside the default cron `PATH`, add a `PATH=`
line above your entry in `/etc/crontab`:
```
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
```

**Option B: systemd timer**

No extra package needed, integrates with `journalctl` for logging, and -
unlike cron - can catch up on a missed run (e.g. if Volumio was off at
3 AM) instead of just skipping it.

```bash
sudo nano /etc/systemd/system/smart-playlists.service
```
```ini
[Unit]
Description=Volumio Smart Playlists

[Service]
Type=oneshot
User=volumio
ExecStart=/usr/local/bin/volumio-smart-playlists.sh
```

```bash
sudo nano /etc/systemd/system/smart-playlists.timer
```
```ini
[Unit]
Description=Run Volumio Smart Playlists daily at 3 AM

[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true

[Install]
WantedBy=timers.target
```

Enable it:
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now smart-playlists.timer
```

Check logging and next scheduled run:
```bash
journalctl -u smart-playlists.service
systemctl list-timers smart-playlists.timer
```

## How it stores playlists

Volumio 3 does **not** use `.m3u` files dropped into your music folder for
its native Playlist view - it reads JSON files from `/data/playlist/`
(one file per playlist, no file extension), each holding an array of track
objects like:
```json
{"service":"mpd","uri":"music-library/USB/Artist/Album/Track.flac","title":"...","artist":"...","album":"..."}
```
This script writes exactly that format directly, so playlists appear in
Volumio immediately, no import step required. See "Multi-source scanning"
above for how the `uri` differs between Internal Storage/USB and NAS.

## Notes / limitations

- Scanned extensions are configurable via the `AUDIO_EXTENSIONS` array
  near the top of the script. Default: `flac mp3 m4a dsf ogg opus aiff
  aif ape` - formats with well-established, reliably read metadata via
  exiftool (ID3 for mp3/dsf/aiff, Vorbis comments for flac/ogg/opus,
  APEv2 for ape, MP4 atoms for m4a). `.wav` and `.wma` are deliberately
  excluded by default - tagging conventions for those vary too much
  (RIFF INFO vs. ID3 chunks for WAV, inconsistent ASF tag usage for WMA)
  to trust blindly. If you want to add them (or anything else), test
  first with `exiftool -AlbumArtist -Artist yourfile.ext` to confirm it
  actually returns something sensible for your files.
- `duplicate=false` deduplicates by title only (not artist+title), so two
  different artists with a coincidentally identical song title would
  collapse into one entry. For the intended use case (same artist,
  best-of vs. studio album) this is the desired behavior.
- Year is read from `-Year`, falling back to `-Date`, falling back to
  `-ContentCreateDate` (the QuickTime "©day" atom iTunes-tagged M4A files
  often use instead) - in that order.
- `added` is based on the file's mtime, not a real "date added to
  library" tag (no audio format reliably stores that). If you re-copy or
  re-tag a file later, its mtime - and therefore its `added` value -
  resets. An unclean USB disconnect/remount can also shift mtimes on some
  filesystems (exFAT via FUSE in particular), which makes the incremental
  cache treat every file as changed on the next run - a one-off full
  rescan, not a bug, and it self-corrects after that run.
- OR-grouping via `,` inside a filter segment does not support escaping a
  literal comma in a value.
- The script does not delete tracks from the *audio library*, only manages
  the generated playlist files under `/data/playlist/`.
- Album art is not explicitly set in the generated JSON; Volumio typically
  resolves it automatically from the `uri` during playback.
- A disconnected/unreachable NAS share still counts as "available" if its
  mount directory exists locally, even if empty - you won't get an error,
  just 0 tracks from that source. Check `mount | grep cifs` and `dmesg` if
  NAS tracks are unexpectedly missing.

## Upgrading from an earlier version

This script has gone through a few naming/location changes:
- `build_artist_playlists.sh` / `artists_playlists.txt` / `.track_cache.tsv`
  → renamed to `volumio-smart-playlists.sh` / `smart_playlists.txt` /
  `.smart_playlists_cache.tsv`
- Single-source config (`MUSIC_DIR`/`MPD_ROOT`/`MPD_SOURCE_LABEL`, working
  files stored inside your music folder) → automatic multi-source scanning,
  working files moved to `/data/smart_playlists_data/`

If you're on an old version, the cleanest path is to delete the old cache
file (wherever it was) and let the current version rebuild it fresh in its
new location - trying to migrate the old cache format isn't worth the
effort. Your existing rules just need to be copied into the new
`smart_playlists.txt` location (or pasted into the plugin's UI fields).

## License

Do whatever you want with it.
