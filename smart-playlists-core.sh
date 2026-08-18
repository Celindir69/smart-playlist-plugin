#!/usr/bin/env bash
# =============================================================================
# Volumio Smart Playlists
#
# Automatically builds native Volumio 3 playlists from a plain text file of
# rules: artist list (OR), plus optional AND/OR filters on album, genre,
# year, title, artist, track number, and duration, with optional
# deduplication by title. See README.md for the full syntax reference.
# =============================================================================
set -euo pipefail

export LC_ALL=C
export LANG=C

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
# Metadata comes from Volumio's own MPD instance via "mpc" - MPD already
# indexes the whole library (that's what powers Browse/Search), so there's
# no separate per-file tag-reading pass needed at all. This requires a
# correctly installed Volumio with a reachable local MPD ("mpc" is part of
# Volumio's base image) - if MPD isn't reachable, the script exits with a
# clear error rather than guessing at an alternative.
#
# One thing MPD does NOT provide: "date added". The "added" filter relies
# on the filesystem mtime instead, via a plain "find" pass (fast, no
# per-file tool invocation, independent of library size).
MPD_MUSIC_DIR="${SMART_PLAYLISTS_MPD_MUSIC_DIR:-/var/lib/mpd/music}"
MPD_TIMEOUT="${SMART_PLAYLISTS_MPD_TIMEOUT:-120}"   # seconds - bounds the worst case if mpc/MPD hangs

# Maps the FIRST path segment MPD reports for a track (its "source label" -
# confirmed via a real mpc query to be exactly the label Volumio itself
# uses, e.g. "INTERNAL"/"USB", since Volumio's MPD music_directory is a
# folder of per-source symlinks/mounts named after those labels) to the
# prefix needed to build a Volumio playlist "uri". INTERNAL and USB are
# verified against real mpc output plus the existing (independently
# verified) uri scheme below. NAS is carried over UNVERIFIED from the
# previous filesystem-scan implementation's comments - no NAS source was
# available to test the MPD path against. If you use a NAS source and
# playlist entries for it don't play, check the debug log for "no
# configured uri prefix" warnings and adjust this accordingly.
SMART_PLAYLISTS_URI_PREFIXES_DEFAULT="INTERNAL|music-library/
USB|music-library/
NAS|mnt/"
URI_PREFIXES_RAW="${SMART_PLAYLISTS_URI_PREFIXES:-$SMART_PLAYLISTS_URI_PREFIXES_DEFAULT}"

WORK_DIR="${SMART_PLAYLISTS_WORK_DIR:-/data/smart_playlists_data}"   # Working directory (cache, log, input file) - deliberately NOT tied to any one music source
PLAYLIST_OUT_DIR="${SMART_PLAYLISTS_OUT_DIR:-/data/playlist}"        # THIS is where Volumio 3 expects its playlists (JSON, not .m3u!)

# File extensions to include. This gates which files get an mtime entry
# (via "find", for change detection and the "added" filter) - metadata
# itself comes from MPD regardless of extension, but a file with no
# matching mtime entry never makes it into the final cache. .wav and .wma
# are deliberately NOT included by default - tagging conventions for those
# are inconsistent enough (RIFF INFO vs. ID3 chunks, ASF tags) across
# encoders that results would be unreliable. Add your own extensions here
# if needed.
AUDIO_EXTENSIONS=(flac mp3 m4a dsf ogg opus aiff aif ape)

# NOTE: renamed from "artists_playlists.txt" now that the script does more
# than just artist lists. If you're upgrading from an earlier version,
# rename your existing input file to match (or change this path back).
INPUT_FILE="$WORK_DIR/smart_playlists.txt"
CACHE_FILE="$WORK_DIR/.smart_playlists_cache.tsv"
MANIFEST_FILE="$WORK_DIR/.smart_playlists_manifest.tsv"
DEBUG_LOG="$WORK_DIR/smart_playlists.debug.log"

mkdir -p "$WORK_DIR"
mkdir -p "$PLAYLIST_OUT_DIR"

# Rudimentary log rotation: keep the debug log from growing unbounded
# under a long-lived daily cron/systemd-timer schedule - relevant on
# space-constrained SD-card Volumio installs. Rotate once it exceeds
# ~5 MB, keeping one previous copy.
if [[ -f "$DEBUG_LOG" ]] && (( $(stat -c%s "$DEBUG_LOG" 2>/dev/null || echo 0) > 5242880 )); then
  mv -f "$DEBUG_LOG" "${DEBUG_LOG}.1"
fi

exec 3>>"$DEBUG_LOG"
PS4='+ ${BASH_SOURCE}:${LINENO}:${FUNCNAME[0]:-main}: '
if [[ "${DEBUG:-0}" == "1" ]]; then
  set -x
fi

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" >&3
}

if ! command -v jq >/dev/null 2>&1; then
  log "jq not found - please run 'sudo apt-get install -y jq' on Volumio"
  echo "Error: jq is required (sudo apt-get install -y jq)" >&2
  exit 1
fi
# "mpc" talks to Volumio's own MPD instance, which is where all metadata
# comes from - it's part of Volumio's base image on a correctly installed
# system, so this is a hard requirement rather than something to install.
if ! command -v mpc >/dev/null 2>&1; then
  log "mpc not found - this should be part of Volumio's base image"
  echo "Error: mpc is required (talks to Volumio's own MPD instance)" >&2
  exit 1
fi

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

normalize() {
  printf '%s' "$1" \
    | tr -d '\r' \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/[[:space:]]\+/ /g' \
    | tr '[:upper:]' '[:lower:]' \
    | tr -d ' -_.'
}

# Parse URI_PREFIXES_RAW (see the MPD integration config block above) into
# parallel arrays: URI_LABEL[i] is the first path segment MPD reports for
# a source (e.g. "INTERNAL"), URI_PREFIX[i] is what to prepend to the
# WHOLE MPD-relative path (including that segment) to get the final
# Volumio playlist "uri".
URI_LABEL=()
URI_PREFIX=()
while IFS='|' read -r lbl pfx; do
  [[ -z "$lbl" ]] && continue
  URI_LABEL+=("$lbl")
  URI_PREFIX+=("$pfx")
done <<< "$URI_PREFIXES_RAW"

# Cache format (tab-separated, 9 columns):
#   mtime  AlbumArtist  FilePath  Title  Album  Genre  Year  Track  Duration
#
# Rebuilds CACHE_FILE entirely from MPD's own database on every run
# instead of scanning files one by one. No incremental read/diff of a
# previous CACHE_FILE happens here (or is needed): MPD's database is
# already the persistent, incrementally-maintained source of truth, and a
# single "mpc search any" round-trip is fast enough to just always re-run
# in full. Only mtime (via a lightweight "find", for the "added" filter)
# still needs any incremental handling of its own on the script's side.
#
# Exits the whole script with a clear error if MPD/mpc can't be used for
# any reason - on a correctly installed Volumio, MPD is always there.
update_cache() {
  log "Updating cache via MPD..."

  if [[ ! -d "$MPD_MUSIC_DIR" ]]; then
    echo "Error: MPD_MUSIC_DIR '$MPD_MUSIC_DIR' does not exist" >&2
    exit 1
  fi

  if ! timeout 10 mpc stats >/dev/null 2>&1; then
    echo "Error: MPD is not reachable (mpc stats failed) - is it running?" >&2
    exit 1
  fi

  local find_name_args=()
  local ext
  for ext in "${AUDIO_EXTENSIONS[@]}"; do
    if (( ${#find_name_args[@]} > 0 )); then
      find_name_args+=(-o)
    fi
    find_name_args+=(-iname "*.${ext}")
  done

  # "-L" follows the symlinks Volumio uses under music_directory to point
  # at the real INTERNAL/USB/NAS locations - "%P" (GNU find) prints the
  # path RELATIVE to the search root directly, which is exactly the same
  # relative-path form ("INTERNAL/...", "USB/...") that mpc's %file%
  # reports, so the two can be joined by path without any translation.
  declare -A cur_mtime=()
  local total=0
  while IFS=$'\t' read -r mt relp; do
    [[ -z "$relp" ]] && continue
    cur_mtime["$relp"]="${mt%%.*}"
    total=$((total + 1))
  done < <(find -L "$MPD_MUSIC_DIR" -type f \( "${find_name_args[@]}" \) ! -name '._*' -printf '%T@\t%P\n')

  log "Audio files found (filesystem, for mtime/added only): $total"

  if (( total == 0 )); then
    echo "Error: no audio files found under MPD_MUSIC_DIR ('$MPD_MUSIC_DIR')" >&2
    exit 1
  fi

  # Bulk-fetch metadata for the WHOLE library in a single mpc call.
  # Field separator is \x1f (ASCII Unit Separator), NOT "|" - confirmed
  # empirically that mpc's own format-string syntax treats "|" specially
  # and silently swallows all output past the first tag on otherwise
  # correctly-tagged files. \x1f can't realistically collide with real
  # tag content and matches the separator convention already used
  # elsewhere in this script for structured data passed to awk.
  local mpd_raw="$TMP_ROOT/mpd_meta_raw.tsv"
  local mpd_err="$TMP_ROOT/mpd_meta_err.log"
  if ! timeout "$MPD_TIMEOUT" mpc -f $'%file%\x1f%albumartist%\x1f%artist%\x1f%title%\x1f%album%\x1f%genre%\x1f%date%\x1f%track%\x1f%time%' search any "" > "$mpd_raw" 2>"$mpd_err"; then
    echo "Error: 'mpc search any' failed or timed out (${MPD_TIMEOUT}s): $(cat "$mpd_err" 2>/dev/null)" >&2
    exit 1
  fi
  if [[ ! -s "$mpd_raw" ]]; then
    echo "Error: mpc returned no tracks at all (empty/not-yet-updated MPD database?)" >&2
    exit 1
  fi

  # %time% comes back as "M:SS" (or "H:MM:SS" for long tracks), not raw
  # seconds - parseTime() converts it. Missing tags are simply absent from
  # mpc's output (empty field); mapped to "-" here for consistency with
  # the rest of the cache/filter logic (a non-empty placeholder, since
  # "IFS=$'\t' read" treats tab as IFS whitespace and collapses runs of
  # empty/adjacent delimiters, which would misalign columns otherwise).
  local mpd_parsed="$TMP_ROOT/mpd_meta_parsed.tsv"
  awk -F'\x1f' -v OFS='\t' '
    function parseTime(t,   n, parts, secs, i) {
      if (t == "" || t == "-") return "-"
      n = split(t, parts, ":")
      if (n < 1) return "-"
      secs = 0
      for (i = 1; i <= n; i++) secs = secs * 60 + (parts[i] + 0)
      return secs
    }
    {
      fp = $1; aa = $2; ar = $3; ti = $4; al = $5; ge = $6; da = $7; trk = $8; tm = $9
      if (aa == "") aa = ar
      if (aa == "") aa = "-"
      if (ti == "") ti = "-"
      if (al == "") al = "-"
      if (ge == "") ge = "-"
      if (match(da, /[0-9][0-9][0-9][0-9]/)) { yr = substr(da, RSTART, 4) } else { yr = "-" }
      if (match(trk, /^[0-9]+/)) { trk = substr(trk, RSTART, RLENGTH) } else { trk = "-" }
      dur = parseTime(tm)
      gsub(/[\t\n\r]/, " ", aa); gsub(/[\t\n\r]/, " ", ti); gsub(/[\t\n\r]/, " ", al); gsub(/[\t\n\r]/, " ", ge); gsub(/[\t\n\r]/, " ", fp)
      print fp, aa, ti, al, ge, yr, trk, dur
    }
  ' "$mpd_raw" > "$mpd_parsed"

  declare -A meta_by_path=()
  while IFS=$'\t' read -r fp aa ti al ge yr trk dur; do
    [[ -z "$fp" ]] && continue
    meta_by_path["$fp"]="$aa"$'\t'"$ti"$'\t'"$al"$'\t'"$ge"$'\t'"$yr"$'\t'"$trk"$'\t'"$dur"
  done < "$mpd_parsed"

  local new_cache_file="${CACHE_FILE}.new"
  : > "$new_cache_file"
  local relp aa ti al ge yr trk dur meta
  for relp in "${!cur_mtime[@]}"; do
    meta="${meta_by_path[$relp]:-}"
    if [[ -n "$meta" ]]; then
      IFS=$'\t' read -r aa ti al ge yr trk dur <<< "$meta"
    else
      aa="-"; ti="-"; al="-"; ge="-"; yr="-"; trk="-"; dur="-"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${cur_mtime[$relp]}" "$aa" "$relp" "$ti" "$al" "$ge" "$yr" "$trk" "$dur" >> "$new_cache_file"
  done
  mv "$new_cache_file" "$CACHE_FILE"

  local final_count
  final_count=$(wc -l < "$CACHE_FILE" | tr -d ' ')
  log "Cache rebuilt via MPD: $final_count entries"
}

sanitize_name() {
  # On Volumio (Linux/ext4) "< > |" are unproblematic in filenames - they
  # are deliberately kept so filtered playlist names stay readable
  # (e.g. "Genesis, Supertramp, Pink Floyd|album!~Live|year>=1973").
  # Only genuinely problematic characters (/ : " \ ? *) are replaced.
  local out
  out="$(printf '%s' "$1" \
    | tr '/:"\\?*' '_' \
    | tr -d '\000-\037' \
    | sed 's/^ *//; s/ *$//; s/  */ /g')"

  # Guard against names that would be dangerous or invisible as files:
  #   "." / ".."   - not creatable as regular files at all; writing to
  #                  them would fail (or worse, be misinterpreted)
  #   ".foo"       - a leading dot makes it a hidden file, so the playlist
  #                  would silently not show up where expected
  # Also guard against an empty result (e.g. a name consisting only of
  # characters that all got stripped).
  case "$out" in
    "" ) out="unnamed" ;;
    "." | ".." ) out="unnamed" ;;
    .* ) out="_${out}" ;;
  esac

  printf '%s' "$out"
}

update_cache

if [[ ! -s "$INPUT_FILE" ]]; then
  log "Input file not found or empty: $INPUT_FILE"
  exit 1
fi

cache_lines=$(wc -l < "$CACHE_FILE" | tr -d ' ')
log "Cache lines available: $cache_lines"

current_names=()
declare -A seen_names=()

while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%$'\r'}"
  [[ -z "${line// }" ]] && continue

  # Skip comment lines: "#" as the first non-whitespace character
  trimmed="${line#"${line%%[![:space:]]*}"}"
  [[ "$trimmed" == \#* ]] && continue

  log "Processing line: $line"

  # Optional playlist name prefix: "My Name::Artist1;Artist2|filter..."
  # Without "::" everything works as before (name is derived
  # automatically from the line).
  if [[ "$line" == *"::"* ]]; then
    playlist_name="${line%%::*}"
    playlist_name="$(printf '%s' "$playlist_name" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    rest="${line#*::}"
    rest="$(printf '%s' "$rest" | sed 's/^[[:space:]]*//')"
  else
    playlist_name=""
    rest="$line"
  fi

  # The filename is determined NOW already (regardless of whether
  # matches are found later) and recorded in the manifest. This
  # prevents an already-existing playlist for this line from being
  # mistakenly deleted as "orphaned" just because it has 0 matches
  # this time.
  if [[ -n "$playlist_name" ]]; then
    base="$(sanitize_name "$playlist_name")"
  else
    base="$(sanitize_name "${rest//;/, }")"
  fi

  # Two rule lines resolving to the same playlist name would silently
  # overwrite each other (last one wins), which is almost never intended
  # and very confusing to debug. Note this can also happen with visibly
  # DIFFERENT names, because sanitize_name maps several characters to
  # "_" (e.g. "A/B" and "A:B" both become "A_B").
  if [[ -n "$base" && -n "${seen_names[$base]:-}" ]]; then
    log "Warning: playlist name '$base' is used by more than one rule line - the later line overwrites the earlier one (line: $line)"
  fi
  [[ -n "$base" ]] && seen_names["$base"]=1

  [[ -n "$base" ]] && current_names+=("$base")

  # Line format (after the optional name prefix): "Artist1;Artist2;...|field<op>value|field<op>value|..."
  # - Part before the first "|": artist list (OR, as before)
  # - every further "|" part: filter, AND-combined with all others
  # - fields: album, genre, year, title, artist
  # - operators: = != ~ (contains) !~ (does not contain) > >= < <=
  # - special field "duplicate=false" deduplicates by title (see below)
  # Lines without "|" behave exactly as before (artist-OR-list only).
  IFS='|' read -r -a line_parts <<< "$rest"
  artist_part="${line_parts[0]}"
  filter_parts=("${line_parts[@]:1}")

  # Artist part "*" (or simply empty/blank) means "match all artists" -
  # useful for playlists that only filter on non-artist fields, e.g. a
  # library-wide "recently added" or "longest tracks" playlist.
  artist_part_trimmed="$(printf '%s' "$artist_part" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  all_artists=0
  wanted_joined=""
  if [[ -z "$artist_part_trimmed" || "$artist_part_trimmed" == "*" ]]; then
    all_artists=1
  else
    IFS=';' read -r -a wanted <<< "$artist_part"

    # Pass the normalized wanted artist names to awk as a \x1f-separated
    # list. The actual matching + normalizing of cache lines then happens
    # in a SINGLE awk pass over the whole cache instead of in a bash loop
    # that spawns several external processes (tr/sed) per cache line -
    # on large libraries that was the bottleneck.
    for want in "${wanted[@]}"; do
      norm_want="$(normalize "$want")"
      [[ -z "$norm_want" ]] && continue
      if [[ -n "$wanted_joined" ]]; then
        wanted_joined+=$'\x1f'"$norm_want"
      else
        wanted_joined="$norm_want"
      fi
    done
  fi

  # Parse filter parts: each "|"-separated part is one AND-group.
  # Within a group, sub-conditions separated by "," are OR-combined:
  #   "|title~Mix,album=12'' Ers"  ->  (title contains "Mix" OR album = "12'' Ers")
  # Multiple "|" groups are still AND-combined with each other, so the
  # overall semantics are conjunctive normal form (AND of ORs), e.g.:
  #   Artist|fieldA<op>valA,fieldB<op>valB|fieldC<op>valC
  #   -> artist match AND (fieldA OR fieldB) AND fieldC
  # Encoding passed to awk: field\x1dop\x1dvalue for each sub-condition,
  # sub-conditions within a group joined by \x1c, groups joined by \x1e.
  # Invalid filters are logged and ignored.
  # "duplicate=true/false" is a special field (not a per-track filter,
  # but controls deduplication by title) and is handled separately
  # instead of being passed to awk as a filter. It must be its own
  # "|"-separated segment (not combined with "," OR conditions).
  #
  # "sort=<key><+|-><key><+|->..." is likewise a special field, not a
  # per-track filter: it controls the output ORDER of the already-
  # filtered tracks instead of random shuffling. Keys: title, track,
  # artist, album, year. "+" = ascending, "-" = descending, direction
  # defaults to "+" if omitted. Keys are concatenated directly, e.g.
  # "sort=album-track+" groups by album Z->A, tracks within each album
  # 1->N. Must also be its own "|" segment. "sort=random" (or omitting
  # sort entirely) keeps the original random order.
  #
  # "limit=N" is likewise special: caps the FINAL (filtered, sorted) list
  # to the first N tracks instead of writing all matches. Combined with
  # "sort=", this gives e.g. "10 most recently added tracks" or
  # "20 longest tracks". Must be its own "|" segment.
  dedupe_titles=0
  sort_spec=""
  limit_n=""
  filters_joined=""
  for filt in "${filter_parts[@]}"; do
    filt="$(printf '%s' "$filt" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [[ -z "$filt" ]] && continue

    if [[ "$filt" =~ ^duplicate[[:space:]]*=[[:space:]]*(.*)$ ]]; then
      fval="$(printf '%s' "${BASH_REMATCH[1]}" | sed 's/[[:space:]]*$//')"
      case "$(printf '%s' "$fval" | tr '[:upper:]' '[:lower:]')" in
        false|0|no) dedupe_titles=1 ;;
        true|1|yes) dedupe_titles=0 ;;
        *) log "Invalid value for duplicate ignored: '$fval' (line: $line)" ;;
      esac
      continue
    fi

    if [[ "$filt" =~ ^sort[[:space:]]*=[[:space:]]*(.*)$ ]]; then
      sort_spec="$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
      continue
    fi

    if [[ "$filt" =~ ^limit[[:space:]]*=[[:space:]]*(.*)$ ]]; then
      lval="$(printf '%s' "${BASH_REMATCH[1]}" | tr -d '[:space:]')"
      if [[ "$lval" =~ ^[0-9]+$ ]] && (( lval > 0 )); then
        limit_n="$lval"
      else
        log "Invalid value for limit ignored: '$lval' (line: $line)"
      fi
      continue
    fi

    IFS=',' read -r -a subconds <<< "$filt"
    group_joined=""
    group_total=0
    group_negative=0
    for sub in "${subconds[@]}"; do
      sub="$(printf '%s' "$sub" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
      [[ -z "$sub" ]] && continue
      if [[ "$sub" =~ ^([A-Za-z]+)[[:space:]]*(\>=|\<=|!=|!~|\>|\<|=|~)[[:space:]]*(.*)$ ]]; then
        ffield="$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')"
        fop="${BASH_REMATCH[2]}"
        fval="$(printf '%s' "${BASH_REMATCH[3]}" | sed 's/[[:space:]]*$//')"
        case "$ffield" in
          album|genre|year|title|artist|track|duration|added) ;;
          *) log "Unknown filter field ignored: $ffield (line: $line)"; continue ;;
        esac
        group_total=$((group_total + 1))
        if [[ "$fop" == "!=" || "$fop" == "!~" ]]; then
          group_negative=$((group_negative + 1))
        fi
        entry="${ffield}"$'\x1d'"${fop}"$'\x1d'"${fval}"
        if [[ -n "$group_joined" ]]; then
          group_joined+=$'\x1c'"$entry"
        else
          group_joined="$entry"
        fi
      else
        log "Invalid filter ignored: '$sub' (line: $line)"
      fi
    done

    # Likely-mistake check: a comma-group ("OR") made up ENTIRELY of
    # negative conditions (!=, !~) is almost never what was intended.
    # E.g. "album!~Live,title!~Live" means "album isn't Live OR title
    # isn't Live", which is true for nearly every track (De Morgan's
    # law: to exclude tracks where EITHER field says "Live", you need
    # AND, i.e. separate "|" segments: "|album!~Live|title!~Live").
    # This only warns, it does not change behavior or block the line.
    if (( group_total >= 2 && group_negative == group_total )); then
      log "Warning: line '$line' - filter group '$filt' combines $group_total exclusions (!=/!~) with comma (OR/likely a mistake - excludes almost nothing). To exclude tracks matching ANY of these, use separate | segments (AND) instead, e.g. |field1!~val1|field2!~val2"
    fi

    [[ -z "$group_joined" ]] && continue
    if [[ -n "$filters_joined" ]]; then
      filters_joined+=$'\x1e'"$group_joined"
    else
      filters_joined="$group_joined"
    fi
  done

  # Parse the sort spec into ordered (key, direction) pairs. Keys are
  # concatenated without a separator, so we greedily match a known key
  # name followed by an optional direction character, repeatedly, until
  # the whole string is consumed. ANY unparseable leftover invalidates
  # the WHOLE spec (falls back to random order) rather than applying a
  # partially-parsed, likely-wrong sort - e.g. a typo like "albumx-"
  # would otherwise silently be accepted as "album" plus garbage.
  sort_keys=()
  sort_dirs=()
  if [[ -n "$sort_spec" && "$sort_spec" != "random" ]]; then
    remaining="$sort_spec"
    while [[ -n "$remaining" ]]; do
      if [[ "$remaining" =~ ^(album|artist|title|track|year|added)([+-]?) ]]; then
        sort_keys+=("${BASH_REMATCH[1]}")
        dir="${BASH_REMATCH[2]}"
        [[ -z "$dir" ]] && dir="+"
        sort_dirs+=("$dir")
        remaining="${remaining:${#BASH_REMATCH[0]}}"
      else
        log "Invalid sort spec '$sort_spec' (unparseable near '$remaining', line: $line) - falling back to random order"
        sort_keys=()
        sort_dirs=()
        break
      fi
    done
  fi

  tmp_tracks="$TMP_ROOT/tracks_$$_${RANDOM}"

  if [[ "$all_artists" -eq 0 && -z "$wanted_joined" ]]; then
    : > "$tmp_tracks"
  else
    awk -F'\t' -v wanted="$wanted_joined" -v filters="$filters_joined" -v dedupe="$dedupe_titles" -v now="$(date +%s)" -v allArtists="$all_artists" '
      BEGIN {
        n = split(wanted, arr, "\037")
        for (i = 1; i <= n; i++) wantedSet[arr[i]] = 1

        numGroups = 0
        if (filters != "") {
          numGroups = split(filters, grecs, "\036")
          for (gi = 1; gi <= numGroups; gi++) {
            numSub = split(grecs[gi], subrecs, "\034")
            groupSize[gi] = numSub
            for (sj = 1; sj <= numSub; sj++) {
              split(subrecs[sj], fparts, "\035")
              gField[gi, sj] = fparts[1]
              gOp[gi, sj]    = fparts[2]
              gVal[gi, sj]   = fparts[3]
            }
          }
        }
      }
      function norm(s,   t) {
        t = s
        gsub(/\r/, "", t)
        t = tolower(t)
        gsub(/[ \t\-_.]/, "", t)
        return t
      }
      # Text comparison (album/genre/title/artist): = != exact
      # (case-insensitive, normalized), ~ !~ substring (case-insensitive,
      # raw, not normalized)
      function textMatch(val, op, want,   nv, nw) {
        if (op == "~")  return (index(tolower(val), tolower(want)) > 0)
        if (op == "!~") return (index(tolower(val), tolower(want)) == 0)
        nv = norm(val); nw = norm(want)
        if (op == "=")  return (nv == nw)
        if (op == "!=") return (nv != nw)
        return 1
      }
      # Numeric comparison (year)
      function numMatch(val, op, want,   nvv, nwv) {
        if (val == "" || val == "-") return 0
        nvv = val + 0; nwv = want + 0
        if (op == "=")  return (nvv == nwv)
        if (op == "!=") return (nvv != nwv)
        if (op == ">")  return (nvv >  nwv)
        if (op == ">=") return (nvv >= nwv)
        if (op == "<")  return (nvv <  nwv)
        if (op == "<=") return (nvv <= nwv)
        return 1
      }
      # Evaluate a single sub-condition against the appropriate field.
      function evalCond(f, op, v, aa, ti, al, ge, yr, trk, dur, mt, now,   daysAgo) {
        if (f == "year")         return numMatch(yr, op, v)
        if (f == "track")        return numMatch(trk, op, v)
        if (f == "duration")     return numMatch(dur, op, v)
        if (f == "album")        return textMatch(al, op, v)
        if (f == "genre")        return textMatch(ge, op, v)
        if (f == "title")        return textMatch(ti, op, v)
        if (f == "artist")       return textMatch(aa, op, v)
        if (f == "added") {
          # Days since the file mtime (proxy for "date added" - the
          # closest thing available without a dedicated tag; resets if a
          # file is re-copied or re-tagged after the fact).
          if (mt == "") return 0
          daysAgo = (now - (mt + 0)) / 86400
          return numMatch(daysAgo, op, v)
        }
        return 1
      }
      {
        mt = $1; aa = $2; fp = $3; ti = $4; al = $5; ge = $6; yr = $7; trk = $8; dur = $9
        if (allArtists != 1 && !(norm(aa) in wantedSet)) next

        # Each group is AND-combined with the others; within a group,
        # sub-conditions are OR-combined (conjunctive normal form).
        ok = 1
        for (gi = 1; gi <= numGroups; gi++) {
          groupOk = 0
          for (sj = 1; sj <= groupSize[gi]; sj++) {
            if (evalCond(gField[gi, sj], gOp[gi, sj], gVal[gi, sj], aa, ti, al, ge, yr, trk, dur, mt, now)) {
              groupOk = 1
              break
            }
          }
          if (!groupOk) { ok = 0; break }
        }
        if (!ok) next

        # duplicate=false: keep only the first match per normalized
        # title (e.g. to avoid duplicate songs when a best-of/live
        # compilation and the original studio album are both in the
        # library)
        if (dedupe + 0 == 1) {
          nt = norm(ti)
          if (nt in seenTitle) next
          seenTitle[nt] = 1
        }

        print fp "\t" ti "\t" al "\t" aa "\t" trk "\t" yr "\t" (mt == "" ? "" : int((now - mt) / 86400))
      }
    ' "$CACHE_FILE" > "$tmp_tracks"
  fi

  matched=$(wc -l < "$tmp_tracks" | tr -d ' ')

  log "Matches for line '$line': $matched"

  if [[ -s "$tmp_tracks" ]]; then
    outfile="$PLAYLIST_OUT_DIR/${base}"

    ordered_tracks="$TMP_ROOT/ordered_$$_${RANDOM}"
    if (( ${#sort_keys[@]} > 0 )); then
      # Column layout in tmp_tracks: 1=filepath 2=title 3=album 4=artist
      # 5=track 6=year 7=added (days since mtime). Build one -k option
      # per requested sort key, in order, so multi-key sorts (e.g. album
      # desc, then track asc within each album) work as expected. "-s"
      # keeps the sort stable so equal keys don't get reshuffled between
      # runs.
      sort_args=(-t $'\t' -s)
      for si in "${!sort_keys[@]}"; do
        key="${sort_keys[$si]}"; dir="${sort_dirs[$si]}"
        case "$key" in
          title)  col=2; numeric=0 ;;
          album)  col=3; numeric=0 ;;
          artist) col=4; numeric=0 ;;
          track)  col=5; numeric=1 ;;
          year)   col=6; numeric=1 ;;
          added)  col=7; numeric=1 ;;
        esac
        mod=""
        [[ "$dir" == "-" ]] && mod="r"
        if (( numeric )); then
          sort_args+=("-k${col},${col}n${mod}")
        else
          sort_args+=("-k${col},${col}f${mod}")
        fi
      done
      sort "${sort_args[@]}" "$tmp_tracks" > "$ordered_tracks"
    else
      shuf "$tmp_tracks" > "$ordered_tracks"
    fi

    if [[ -n "$limit_n" ]]; then
      limited_tracks="$TMP_ROOT/limited_$$_${RANDOM}"
      head -n "$limit_n" "$ordered_tracks" > "$limited_tracks"
      ordered_tracks="$limited_tracks"
    fi

    # Build the JSON array in one awk pass + one jq invocation instead of
    # spawning a separate jq process per track. On large, lightly-filtered
    # playlists (thousands of matches) the old per-track subprocess loop
    # was by far the slowest part of the script - same reasoning as the
    # single-awk-pass artist matching above.
    playlist_tsv="$TMP_ROOT/playlist_$$_${RANDOM}.tsv"
    uri_warn_log="$TMP_ROOT/uri_warn_$$_${RANDOM}.log"
    awk -F'\t' -v uriprefixes="$URI_PREFIXES_RAW" '
      BEGIN {
        OFS = "\t"
        nLbl = split(uriprefixes, lblLines, "\n")
        for (i = 1; i <= nLbl; i++) {
          if (lblLines[i] == "") continue
          split(lblLines[i], lp, "|")
          labelPrefix[lp[1]] = lp[2]
          haveLabel[lp[1]] = 1
        }
      }
      # fp is relative to MPD_MUSIC_DIR in the form "<LABEL>/<rest>" - look
      # up the label (first path segment) and prepend its configured
      # prefix to the WHOLE path (label included).
      function uriFor(fp,   label) {
        label = fp
        sub(/\/.*/, "", label)
        if (label in haveLabel) return labelPrefix[label] fp
        print "Warning: no configured uri prefix for source label '\''" label "'\'' (path: " fp ") - using raw relative path as uri" > "/dev/stderr"
        return fp
      }
      {
        fp = $1; ti = $2; al = $3; aa = $4
        uri = uriFor(fp)
        # "-" is our internal placeholder for "no value" (see the note in
        # update_cache on why real empty fields are avoided) - map it back
        # to something sensible instead of a literal dash.
        title = ti
        if (title == "" || title == "-") {
          n = split(fp, p, "/")
          title = p[n]
        }
        if (aa == "-") aa = ""
        if (al == "-") al = ""
        print uri, title, aa, al
      }
    ' "$ordered_tracks" > "$playlist_tsv" 2>"$uri_warn_log"

    if [[ -s "$uri_warn_log" ]]; then
      while IFS= read -r warn_line; do
        log "$warn_line"
      done < "$uri_warn_log"
    fi

    jq -R -s '
      split("\n") | map(select(length > 0) | split("\t")) |
      map({service: "mpd", uri: .[0], title: .[1], artist: .[2], album: .[3]})
    ' "$playlist_tsv" > "$outfile"

    chown volumio:volumio "$outfile" 2>/dev/null || true

    if [[ -n "$limit_n" ]]; then
      written=$(wc -l < "$ordered_tracks" | tr -d ' ')
      log "Wrote playlist: $outfile ($written of $matched matched tracks, limit=$limit_n)"
    else
      log "Wrote playlist: $outfile ($matched tracks)"
    fi
  else
    log "No matches for line: $line"
  fi

done < "$INPUT_FILE"

# Manifest reconciliation: delete playlists that were created on the
# previous run but no longer appear in the current smart_playlists.txt
# (line removed/renamed). Playlists whose line still exists but currently
# has 0 matches are kept, since their name is still in current_names
# (see above).
declare -A new_manifest_set=()
for n in "${current_names[@]}"; do
  new_manifest_set["$n"]=1
done

# Names we failed to delete stay tracked so cleanup is retried on the
# next run (e.g. once a permission/ownership issue is fixed) instead of
# being silently forgotten forever just because this run's manifest
# rewrite happens unconditionally below.
failed_removals=()

if [[ -f "$MANIFEST_FILE" ]]; then
  while IFS= read -r old_name; do
    [[ -z "$old_name" ]] && continue
    if [[ -z "${new_manifest_set[$old_name]:-}" ]]; then
      if [[ -f "$PLAYLIST_OUT_DIR/$old_name" ]]; then
        # NOTE: "rm -f" only suppresses "file does not exist" errors -
        # a genuine permission/ownership failure (e.g. after a plugin
        # reinstall changes file ownership) still makes it exit non-zero
        # and print an error. Under "set -e" that would silently kill
        # the WHOLE script mid-cleanup (before the manifest gets
        # rewritten and before any later lines get processed), which is
        # far worse than a failed deletion on its own. The "|| true"
        # guards against that; we then verify success ourselves below
        # instead of trusting rm's exit status either way.
        rm -f "$PLAYLIST_OUT_DIR/$old_name" 2>/dev/null || true
        if [[ -f "$PLAYLIST_OUT_DIR/$old_name" ]]; then
          log "Warning: failed to remove orphaned playlist '$old_name' (still present after rm -f - check file ownership/permissions on $PLAYLIST_OUT_DIR) - will retry next run"
          failed_removals+=("$old_name")
        else
          log "Removed orphaned playlist: $old_name"
        fi
      fi
    fi
  done < "$MANIFEST_FILE"
fi

: > "$MANIFEST_FILE"
for n in "${current_names[@]}"; do
  printf '%s\n' "$n" >> "$MANIFEST_FILE"
done
for n in "${failed_removals[@]}"; do
  printf '%s\n' "$n" >> "$MANIFEST_FILE"
done

log "Done"

if [[ "${DEBUG:-0}" == "1" ]]; then
  set +x
fi
exec 3>&-
