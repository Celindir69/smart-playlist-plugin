# Volumio Smart Playlists

Automatically builds native Volumio playlists from a plain text file of
rules - artist lists with optional AND/OR filters on album, genre, year,
originalyear, title, artist, albumartist, comment, track number, duration,
and days-since-added, plus custom sort order, track limits, deduplication
(e.g. when a best-of/live compilation and the original studio album are
both in your library), and optional various-artists matching (for pulling
an artist's appearances on compilations into their own playlist).

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
- Reads metadata (AlbumArtist, Artist, Title, Album, Genre, Year,
  OriginalYear, Comment, Track, Duration) directly from **Volumio's own
  MPD database** via `mpc` - the
  same index that powers Browse/Search, so there's no separate per-file
  scan to wait for at all (a ~24k track library that used to take ~20
  minutes on first run with a per-file tag scanner now takes a couple of
  seconds, every run). Requires a correctly installed Volumio with a
  reachable local MPD - see "How metadata is read" below.
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

- Volumio 3, with a reachable local MPD (standard on any correctly
  installed Volumio)
- `jq` and `mpc`. `mpc` is part of Volumio's base image - nothing to
  install. The plugin installs `jq` automatically; for the standalone
  script:
  ```bash
  sudo apt-get update
  sudo apt-get install -y jq
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
3. That's it - no path configuration needed, it reads Internal Storage,
   USB, and NAS metadata straight from Volumio's own MPD (see "How
   metadata is read" below if your setup is non-standard).

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

## How metadata is read

All metadata comes from Volumio's own MPD instance (`mpc search any ""`)
rather than from scanning files one by one - MPD already has the whole
library indexed for Browse/Search, so this is both far faster and one less
thing to keep in sync. This needs no configuration, and requires a
reachable local MPD; if `mpc` is missing or MPD doesn't respond, the script
exits with a clear error rather than guessing at an alternative (on a
correctly installed Volumio, MPD is always there).

What this means in practice:
- **AlbumArtist, Artist, Album, Title, Genre, Year, OriginalYear,
  Comment, Track, Duration**: come from MPD. No incremental cache is
  needed for these - a single MPD query is fast enough to just re-run in
  full on every invocation.
- **AlbumArtist and Artist are read as separate tags**, not merged - see
  "Compilations / Various Artists" below for why that matters.
- **`comment` needs an mpd.conf change.** MPD only exposes to `mpc` the
  tags listed in mpd.conf's `metadata_to_use` - by default this is
  "every known tag except `comment` and the `musicbrainz_*` ones", so
  `AlbumArtist`/`Artist`/`OriginalDate` are already available, but
  `Comment` is not until you add it explicitly:
  ```
  metadata_to_use    "artist,album,title,track,name,genre,date,composer,performer,disc,comment,albumartist,originaldate"
  ```
  (List every tag you actually want, not just `comment` - this setting
  *replaces* the default list rather than adding to it.) After editing
  `/etc/mpd.conf`, MPD's database must be **rebuilt, not just updated**,
  for the change to take effect (Volumio: Settings -> My Music -> use
  the "Rescan" / rebuild option, or `mpc rescan` followed by a restart of
  the `mpd` service). If you don't need `comment` filters, you can skip
  this entirely.
- **`originalyear` needs a new enough MPD.** Unlike `comment`, this isn't a
  `metadata_to_use` setting you can turn on - some older MPD releases don't
  implement the `OriginalDate` tag *type* at all, so the daemon has nothing
  to expose regardless of config. Confirmed missing entirely on MPD 0.20.0
  (no `OriginalDate:` field even querying MPD directly over its raw
  protocol, below `mpc`/format-strings entirely). If `originalyear`
  filters/sorting behave exactly like `year` on your system, check your MPD
  version (`mpc` itself may be too old to report `--version` usefully -
  `dpkg -s mpd | grep Version` is more reliable) and query a known-tagged
  file directly to confirm:
  ```bash
  mpc -f "%file%" search any "" | head -1   # copy a real path from the output
  exec 3<>/dev/tcp/127.0.0.1/6600; read -r -u 3 x
  printf 'find file "PASTE_THE_PATH_HERE"\n' >&3
  while read -r -u 3 l; do echo "$l"; [[ "$l" == "OK" || "$l" == ACK* ]] && break; done
  exec 3<&- 3>&-
  ```
  No `OriginalDate:` line in that output means your MPD build doesn't
  support the tag - upgrading MPD standalone on Volumio isn't recommended
  (it's managed as part of the OS image and could destabilize playback),
  so on such a system `originalyear` filters/sorting will always fall back
  to `year` (see above/below) rather than ever using a genuine original
  release date.
- **`added`** (days since added): MPD doesn't track "date added", so it
  still comes from the file's filesystem mtime via a plain `find` pass -
  just listing files and their timestamps, fast regardless of library
  size.
- **uri source mapping**: MPD reports each file's path relative to its own
  `music_directory` (default `/var/lib/mpd/music`), prefixed with the same
  source label Volumio itself uses for each of its standard music sources
  (Internal Storage, USB, NAS) - e.g. `INTERNAL/Artist/Album/Track.mp3`.
  That label is mapped to a playlist `uri` prefix via
  `SMART_PLAYLISTS_URI_PREFIXES` (newline-separated `label|uri_prefix`
  entries, default:
  ```
  INTERNAL|music-library/
  USB|music-library/
  NAS|mnt/
  ```
  ). **INTERNAL and USB are verified against a real device; NAS is
  UNVERIFIED** (no NAS source was available to test against) - if you use
  a NAS source, check the debug log for a "no configured uri prefix"
  warning and adjust `SMART_PLAYLISTS_URI_PREFIXES` if needed.

Relevant environment variables (standalone script) / equivalent behavior
(plugin, same defaults):
- `SMART_PLAYLISTS_MPD_MUSIC_DIR` - MPD's `music_directory` (default
  `/var/lib/mpd/music`; check `grep music_directory /etc/mpd.conf` if
  unsure).
- `SMART_PLAYLISTS_MPD_TIMEOUT` - seconds to wait for an MPD query before
  giving up (default `120`).
- `SMART_PLAYLISTS_URI_PREFIXES` - see above.

### Compilations / Various Artists

`AlbumArtist` and `Artist` are read as separate tags, which matters for
how the artist list (the part of a rule line before the first `|`)
decides what counts as a match:

- **Default** (`various=false`, or simply omitted): matches against
  `AlbumArtist`, falling back to `Artist` only when `AlbumArtist` is
  blank. This is unchanged from before and is what you want for a
  regular album, where every track's `AlbumArtist` is the artist itself.
  A compilation tagged `AlbumArtist=Various Artists` will **not** match
  here, even if an individual track's `Artist` is the artist you're
  looking for.
- **`various=true`** (must be its own `|` segment / its own rule field in
  the plugin UI): matches against the raw `Artist` tag instead, so a
  track on a `Various Artists` compilation is picked up as long as its
  `Artist` tag names the right performer. Use this for a playlist that
  should also include an artist's guest spots/compilation appearances,
  not just their own albums.

This is exactly the tagging convention MusicBrainz Picard and MP3tag
both encourage for compilations: `AlbumArtist = Various Artists`,
`Artist = <the actual performer of that track>`. The `albumartist` and
`artist` filter fields (see below) expose the same two raw tags
independently for use in AND/OR filters, e.g. `albumartist=VariousArtists`
to build a "all my compilation tracks" playlist regardless of artist.

```
# Only Genesis' own albums
Genesis Albums::Genesis

# Genesis' own albums PLUS any compilation track where Genesis performed
Genesis Everywhere::Genesis|various=true
```

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
  with OR (a track matches if its AlbumArtist matches *any* of them - or
  its Artist tag, if `various=true` is set; see "Compilations / Various
  Artists" above). Matching is case-insensitive and ignores
  spaces/dashes/underscores/dots.
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
  - Fields: `album`, `genre`, `year`, `originalyear`, `title`, `artist`
    (raw Artist tag), `albumartist` (raw AlbumArtist tag), `comment`,
    `track`, `duration` (seconds), `added` (days since the file's mtime -
    see caveat below)
  - Operators: `=`, `!=`, `~` (contains), `!~` (does not contain), `>`,
    `>=`, `<`, `<=`
  - Numeric comparisons (`>`, `>=`, `<`, `<=`) apply to `year`,
    `originalyear`, `track`, `duration`, and `added`.
  - `originalyear` comes from MPD's `OriginalDate` tag (what Picard/MP3tag
    write for a reissue's *original* release date) - independent of
    `year`, which still reflects `Date` (the specific release/reissue
    you actually have). If a track has no `OriginalDate` tag at all, both
    an `originalyear` filter and `sort=originalyear` fall back to that
    track's `year` (`Date`) instead of excluding it or grouping it at one
    end of the sort order, so mixed libraries (some files with original
    release dates tagged, others not) still get sensible results without
    requiring every file to be tagged first. This same fallback also kicks
    in on an MPD build too old to support the `OriginalDate` tag type at
    all, regardless of how your files are tagged - see "How metadata is
    read" above.
  - Note: if a value legitimately contains a comma, it will be
    mis-parsed as an OR split - this is a known limitation.
- **`duplicate=false`** (optional, special field, must be its own `|`
  segment): deduplicates the resulting playlist by normalized track title,
  keeping only the first match per title. Default is `true` (duplicates
  allowed, i.e. original behavior).
- **`various=true`** (optional, special field, must be its own `|`
  segment): matches the artist list against the raw Artist tag instead of
  AlbumArtist - see "Compilations / Various Artists" above. Default is
  `false` (original AlbumArtist-based behavior).
- **`sort=<key><+|-><key><+|->...`** (optional, special field, must be its
  own `|` segment): controls the track ORDER in the generated playlist
  instead of the default random shuffle.
  - Keys: `title`, `track`, `artist`, `album`, `year`, `added`,
    `originalyear`
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

# Long tracks only
Long Tracks::Genesis|duration>300

# Sorted instead of shuffled: group by album (Z-A), tracks in order (1-N)
Genesis Albums In Order::Genesis|sort=album-track+

# Recently added tracks (based on file mtime), newest 15 only
New Genesis::Genesis|added<30|sort=added+|limit=15

# Wildcard artist: library-wide, not tied to any specific artist,
# pulls from Internal Storage, USB, and NAS all at once
Recently Added (All Artists)::*|added<5|limit=20

# Genesis' own albums PLUS their compilation/guest appearances
# (AlbumArtist=Various Artists, Artist=Genesis on those tracks)
Genesis Everywhere::Genesis|various=true

# Compilation tracks only, regardless of artist
Various Artists Compilations::*|albumartist=VariousArtists

# Reissues: use the ORIGINAL release year, not the reissue year
70s Originals::*|originalyear>=1970|originalyear<1980

# Filter on a free-text Comment tag (e.g. "Remastered", "Live bootleg", ...)
Remastered Only::*|comment~Remaster

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

If `mpc` or `jq` live outside the default cron `PATH`, add a `PATH=`
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
Volumio immediately, no import step required. See "How metadata is read"
above for how the `uri` differs between Internal Storage/USB and NAS.

## Notes / limitations

- Scanned extensions are configurable via the `AUDIO_EXTENSIONS` array
  near the top of the script. Default: `flac mp3 m4a dsf ogg opus aiff
  aif ape`. This only gates which files get an mtime entry (for change
  detection and the `added` filter) - metadata itself comes from MPD
  regardless of extension, but a file with no matching mtime entry never
  makes it into the cache. `.wav` and `.wma` are deliberately excluded by
  default - tagging conventions for those vary too much (RIFF INFO vs.
  ID3 chunks for WAV, inconsistent ASF tag usage for WMA) across encoders
  to trust blindly. Add your own extensions here if needed.
- `duplicate=false` deduplicates by title only (not artist+title), so two
  different artists with a coincidentally identical song title would
  collapse into one entry. For the intended use case (same artist,
  best-of vs. studio album) this is the desired behavior.
- Year comes from MPD's `Date` tag, `originalyear` from `OriginalDate` -
  in both cases the first 4 consecutive digits found in the tag, so both
  plain-year (`2023`) and full-date (`2023-01-01`) formats work.
- The artist-list header match and the `artist`/`albumartist` filter
  fields are all case-insensitive and ignore spaces/dashes/underscores/
  dots for `=`/`!=` comparisons (same normalization as everywhere else in
  this script) - "Various Artists" and "various-artists" are treated as
  identical.
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

- **AlbumArtist/Artist/OriginalDate/Comment support** (this version): the
  cache format gained new columns (Artist is now read separately from
  AlbumArtist, plus OriginalYear and Comment) and the `artist` filter
  field now means the raw Artist tag rather than AlbumArtist-with-
  fallback (use `albumartist` for the old meaning). No manual step is
  needed for the cache itself - it's rebuilt from scratch on every run
  regardless of version, so the new columns simply appear on the next
  run. If you want to use `comment` filters, add `comment` to mpd.conf's
  `metadata_to_use` and rebuild MPD's database first (see "How metadata
  is read" above) - without that change, `comment` will just always be
  empty.

## License

Do whatever you want with it.
