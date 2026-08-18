#!/usr/bin/env bash
# =============================================================================
# Volumio Smart Playlists
#
# Automatically builds native Volumio 3 playlists from a plain text file of
# rules: artist list (OR), plus optional AND/OR filters on album, genre,
# year, title, artist, track number, duration, and BPM, with optional
# deduplication by title. See README.md for the full syntax reference.
# =============================================================================
set -euo pipefail

export LC_ALL=C
export LANG=C

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
# All three of Volumio's standard music sources are scanned by DEFAULT -
# INTERNAL, USB, and NAS. A source that isn't present on your system (e.g.
# no NAS share mounted) is silently skipped, no error.
#
# Override the whole list via the SMART_PLAYLISTS_SOURCES environment
# variable if your setup differs - newline-separated entries of the form
# "scan_dir|uri_root|uri_prefix":
#   scan_dir  : directory to search for audio files in
#   uri_root  : prefix stripped from a file's absolute path to build the
#               relative part of Volumio's playlist "uri" field
#   uri_prefix: prepended to the stripped relative path to form the final
#               "uri" - varies per source type, see below
#
# Mount points below are Volumio 3's standard layout. Two DIFFERENT uri
# schemes are in use, confirmed against real Volumio-created playlists:
#   INTERNAL -> /data/INTERNAL        -> "music-library/INTERNAL/<rel>"
#   USB      -> /media/<drive-label>  -> "music-library/USB/<rel>"
#   NAS      -> /mnt/NAS/<share-name> -> "<rel>" (NO "music-library/"
#               prefix, NO source label at all - just the raw absolute
#               path with the leading "/" stripped, e.g.
#               "mnt/NAS/Download/Artist/Album/01 Track.m4a")
# USB and NAS were verified against playlists Volumio itself created.
# INTERNAL follows the same structural pattern as USB but is not
# independently confirmed - if INTERNAL tracks don't play, double-check
# the "uri" of a manually-created Volumio playlist for an INTERNAL track
# and adjust SMART_PLAYLISTS_SOURCES accordingly.
#
# Note INTERNAL's uri_root equals its scan_dir (there's only ever one
# fixed INTERNAL folder, unlike USB where multiple differently-named
# drives can be mounted side by side under /media) - don't change it to
# one level up, or "INTERNAL" ends up duplicated in the uri.
SMART_PLAYLISTS_SOURCES_DEFAULT="/data/INTERNAL|/data/INTERNAL|music-library/INTERNAL/
/media|/media|music-library/USB/
/mnt/NAS||"
SOURCES_RAW="${SMART_PLAYLISTS_SOURCES:-$SMART_PLAYLISTS_SOURCES_DEFAULT}"

WORK_DIR="${SMART_PLAYLISTS_WORK_DIR:-/data/smart_playlists_data}"   # Working directory (cache, log, input file) - deliberately NOT tied to any one music source
PLAYLIST_OUT_DIR="${SMART_PLAYLISTS_OUT_DIR:-/data/playlist}"        # THIS is where Volumio 3 expects its playlists (JSON, not .m3u!)

# File extensions to scan. Only formats with well-established, reliably
# read metadata via exiftool are included by default (ID3 for mp3/dsf/aiff,
# Vorbis comments for flac/ogg/opus, APEv2 for ape, MP4 atoms for m4a).
# .wav and .wma are deliberately NOT included - tagging conventions for
# those are inconsistent enough (RIFF INFO vs. ID3 chunks, ASF tags) that
# results would be unreliable. Add your own extensions here if needed;
# just make sure `exiftool -AlbumArtist -Artist yourfile.ext` actually
# returns something sensible first.
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
if ! command -v exiftool >/dev/null 2>&1; then
  log "exiftool not found"
  echo "Error: exiftool is required" >&2
  exit 1
fi

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# Parse SMART_PLAYLISTS_SOURCES / the default into parallel arrays.
SRC_DIR=()
SRC_ROOT=()
SRC_PREFIX=()
while IFS='|' read -r d r p; do
  [[ -z "$d" ]] && continue
  SRC_DIR+=("$d")
  SRC_ROOT+=("$r")
  SRC_PREFIX+=("$p")
done <<< "$SOURCES_RAW"

log "Configured sources: ${#SRC_DIR[@]}"
for _si in "${!SRC_DIR[@]}"; do
  _disp="${SRC_PREFIX[$_si]:-<raw path, no prefix>}"
  if [[ -d "${SRC_DIR[$_si]}" ]]; then
    log "  [available]      ${_disp}: ${SRC_DIR[$_si]}"
  else
    log "  [not found, skip] ${_disp}: ${SRC_DIR[$_si]}"
  fi
done

# Given an absolute file path, find which configured source it belongs to
# and build the corresponding Volumio playlist "uri". Every path passed in
# here originated from a find() under one of SRC_DIR[], so a match is
# always expected.
uri_for_path() {
  local fp="$1"
  local i
  for i in "${!SRC_DIR[@]}"; do
    if [[ "$fp" == "${SRC_DIR[$i]}"/* ]]; then
      local root="${SRC_ROOT[$i]}"
      local prefix="${SRC_PREFIX[$i]}"
      local rel="${fp#"$root"/}"
      printf '%s%s' "$prefix" "$rel"
      return 0
    fi
  done
  log "Warning: could not determine source for '$fp' - uri may be wrong"
  printf '%s' "${fp#/}"
  return 1
}

normalize() {
  printf '%s' "$1" \
    | tr -d '\r' \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/[[:space:]]\+/ /g' \
    | tr '[:upper:]' '[:lower:]' \
    | tr -d ' -_.'
}

# Cache format (tab-separated, 10 columns):
#   mtime  AlbumArtist  FilePath  Title  Album  Genre  Year  Track  Duration  BPM
#
# Incremental update:
#   1. Determine the current file set (path + mtime) via find.
#   2. Read the existing cache (path -> mtime + full line).
#   3. Only files that are new OR whose mtime has changed are re-read
#      via exiftool.
#   4. Files that are in the cache but no longer exist are automatically
#      dropped when the new cache is written.
#
# IMPORTANT: -f forces exiftool to print a column for EVERY tag
# (placeholder "-" for a missing tag). Without -f, columns shift when
# a tag is missing and the cache becomes unusable.
#
# Year: some formats (especially FLAC/Vorbis) only carry the year in
# -Date rather than -Year. iTunes-tagged M4A files often carry it only
# in -ContentCreateDate (the QuickTime "©day" atom). We query all three
# and use the first 4-digit year found, in the order Year, Date,
# ContentCreateDate.
#
# Track: ID3 (MP3) usually uses the "Track" tag, Vorbis/FLAC uses
# "TrackNumber". We query both, take the first non-empty value, and
# extract only the leading digits (the value is often formatted "3/12").
#
# BPM: both ID3 (MP3) and QuickTime/M4A (the iTunes "tmpo" atom) map to
# exiftool's unified "BeatsPerMinute" tag. FLAC/Vorbis has no fixed
# convention but often carries a raw "BPM" field. We query both and take
# the first non-empty, numeric value.
#
# Duration: the Composite tag "Duration#" ("#" requests the raw seconds
# value instead of a formatted time like "3:45"), works across formats.
update_cache() {
  log "Updating cache (incremental)..."

  # Build the "-iname '*.ext'" clauses dynamically from AUDIO_EXTENSIONS
  # so extensions only need to be maintained in one place.
  local find_name_args=()
  local ext
  for ext in "${AUDIO_EXTENSIONS[@]}"; do
    if (( ${#find_name_args[@]} > 0 )); then
      find_name_args+=(-o)
    fi
    find_name_args+=(-iname "*.${ext}")
  done

  declare -A cur_mtime=()
  local total=0
  local _src_dir
  for _src_dir in "${SRC_DIR[@]}"; do
    [[ -d "$_src_dir" ]] || continue
    # NOTE: mtime is truncated to whole seconds (dropping the fractional
    # part %T@ normally reports) before comparison. Some mount types
    # (CIFS/NAS shares, exFAT via FUSE in particular) have been observed
    # to report a slightly different fractional mtime on every single
    # stat() call for the same, genuinely-unchanged file - sub-second
    # jitter that has nothing to do with an actual file change. Since our
    # change-detection only needs "did this file actually change" at
    # whole-second granularity, truncating eliminates that false-positive
    # source without losing any meaningful precision.
    while IFS=$'\t' read -r mt fp; do
      [[ -z "$fp" ]] && continue
      cur_mtime["$fp"]="${mt%%.*}"
      total=$((total + 1))
    done < <(find "$_src_dir" -type f \( "${find_name_args[@]}" \) ! -name '._*' -printf '%T@\t%p\n')
  done

  log "Audio files found: $total"

  declare -A cache_mtime=()
  declare -A cache_full=()
  if [[ -f "$CACHE_FILE" ]]; then
    while IFS=$'\t' read -r mt aa fp ti al ge yr trk dur bpm; do
      [[ -z "$fp" ]] && continue
      cache_mtime["$fp"]="$mt"
      cache_full["$fp"]="$mt"$'\t'"$aa"$'\t'"$fp"$'\t'"$ti"$'\t'"$al"$'\t'"$ge"$'\t'"$yr"$'\t'"$trk"$'\t'"$dur"$'\t'"$bpm"
    done < "$CACHE_FILE"
  fi

  local to_scan=()
  local fp
  for fp in "${!cur_mtime[@]}"; do
    if [[ "${cache_mtime[$fp]:-}" != "${cur_mtime[$fp]}" ]]; then
      to_scan+=("$fp")
    fi
  done

  local new_count=${#to_scan[@]}
  log "New/changed files: $new_count"

  # Diagnostic: log a sample of what actually changed (path, old mtime,
  # new mtime) so a mismatch that keeps recurring on every run - which
  # should NOT normally happen - can be investigated instead of only
  # seeing the bare count. Capped at 20 lines to avoid flooding the log
  # on a legitimate mass-change (e.g. after adding a lot of new music).
  if (( new_count > 0 )); then
    local _diag_i=0
    for fp in "${to_scan[@]}"; do
      _diag_i=$((_diag_i + 1))
      (( _diag_i > 20 )) && { log "  ... and $((new_count - 20)) more (truncated)"; break; }
      log "  changed: '$fp' old_mtime='${cache_mtime[$fp]:-<not in cache>}' new_mtime='${cur_mtime[$fp]}'"
    done
  fi

  if (( new_count > 0 )); then
    local exif_out="$TMP_ROOT/exif_out.tsv"
    local exif_rc=0
    # NOTE: exiftool exits with a non-zero status as soon as EVEN A
    # SINGLE one of the files passed to it triggers a warning (corrupt/
    # unknown tags, etc.) - practically unavoidable on large batches.
    # Combined with "pipefail" this would otherwise mark the whole
    # pipeline as failed and "set -e" would kill the script instantly
    # and silently. That's why the exit code is deliberately caught
    # here and only logged.
    { printf '%s\0' "${to_scan[@]}" \
        | xargs -0 -r exiftool -T -s3 -f -FilePath -AlbumArtist -Artist -Title -Album -Genre -Year -Date -ContentCreateDate -Track -TrackNumber '-Duration#' -BeatsPerMinute -BPM \
        | awk -F '\t' 'BEGIN{OFS="\t"}
            {
              # FilePath is queried FIRST (field 1) on purpose: a metadata
              # value that itself contains a TAB shifts every field after
              # it, and losing track of WHICH FILE a row belongs to breaks
              # the whole cache merge (the row silently disappears). With
              # the path pinned to $1 it can never be displaced, and any
              # extra fields caused by an embedded tab only affect the
              # metadata columns, which we clean up below.
              fp=$1; aa=$2; ar=$3; ti=$4; al=$5; ge=$6; yr=$7; da=$8; cc=$9;
              tr1=$10; tr2=$11; dur=$12; bp1=$13; bp2=$14;
              if (aa=="-" || aa=="") aa=ar;
              if (aa=="") aa="-";
              # NOTE: files with no usable AlbumArtist/Artist tag (e.g. a
              # corrupt/unsupported file, or one exiftool genuinely found
              # nothing in) are NOT skipped here anymore - they still get
              # a cache line (with artist "-", so they will simply never
              # match any playlist rule). Skipping them via "next" used to
              # mean they were NEVER written to the cache, which made the
              # incremental update treat them as "new" on every single run
              # forever, re-invoking exiftool on the exact same untaggable
              # files over and over.
              #
              # IMPORTANT: missing values are represented as "-" (matching
              # the convention exiftool itself uses for a missing tag),
              # NEVER as a true empty string, in every field written to this file
              # (and later to the cache and to tmp_tracks/ordered_tracks).
              # bash "read" (with a tab IFS) silently collapses runs of
              # consecutive tabs (i.e. adjacent empty fields) into a
              # single delimiter, which misaligns every field after the
              # first empty one - "-" as a non-empty placeholder sidesteps
              # that bug entirely without needing to change how those
              # files get parsed.
              if (ti=="-" || ti=="") ti="-";
              if (al=="-" || al=="") al="-";
              if (ge=="-" || ge=="") ge="-";
              if (yr=="-" || yr=="") {
                if (match(da, /[0-9][0-9][0-9][0-9]/)) {
                  yr = substr(da, RSTART, 4)
                } else if (match(cc, /[0-9][0-9][0-9][0-9]/)) {
                  # ContentCreateDate: the QuickTime "©day" atom that
                  # iTunes-tagged M4A files use for the release year -
                  # -Year/-Date often return nothing for these files.
                  yr = substr(cc, RSTART, 4)
                } else {
                  yr = "-"
                }
              } else if (match(yr, /[0-9][0-9][0-9][0-9]/)) {
                yr = substr(yr, RSTART, 4)
              } else {
                yr = "-"
              }

              # Track: "Track" (ID3) or "TrackNumber" (Vorbis/FLAC),
              # sometimes formatted "3/12" - keep only the leading digits.
              trkraw = (tr1 != "-" && tr1 != "") ? tr1 : tr2
              if (trkraw == "-" || trkraw == "") {
                trk = "-"
              } else if (match(trkraw, /^[0-9]+/)) {
                trk = substr(trkraw, RSTART, RLENGTH)
              } else {
                trk = "-"
              }

              # Duration: the "#" Composite tag gives raw seconds - round
              # to whole seconds.
              if (dur == "-" || dur == "") {
                dur = "-"
              } else {
                dur = sprintf("%d", dur + 0)
              }

              # BPM: "BeatsPerMinute" (ID3/QuickTime) or raw "BPM"
              # (common on FLAC/Vorbis) - keep numeric values only.
              bpraw = (bp1 != "-" && bp1 != "") ? bp1 : bp2
              if (bpraw == "-" || bpraw == "") {
                bpm = "-"
              } else if (match(bpraw, /^[0-9]+(\.[0-9]+)?/)) {
                bpm = substr(bpraw, RSTART, RLENGTH)
              } else {
                bpm = "-"
              }

              # Defensive: a metadata value that itself contains a TAB (or
              # a newline) would shift every subsequent column in this
              # tab-separated file, corrupting the cache from that row on.
              # Rare, but real - some badly-tagged files do carry stray
              # control characters. Replace them with a space here rather
              # than trusting the input.
              gsub(/[\t\n\r]/, " ", aa)
              gsub(/[\t\n\r]/, " ", ti)
              gsub(/[\t\n\r]/, " ", al)
              gsub(/[\t\n\r]/, " ", ge)
              gsub(/[\t\n\r]/, " ", fp)

              print fp, aa, ti, al, ge, yr, trk, dur, bpm
            }' > "$exif_out"
    } || exif_rc=$?
    if (( exif_rc != 0 )); then
      log "Warning: exiftool/awk pipeline reported exit code $exif_rc (likely a warning on a single file) - continuing anyway"
    fi

    while IFS=$'\t' read -r fp aa ti al ge yr trk dur bpm; do
      [[ -z "$fp" ]] && continue
      local mt="${cur_mtime[$fp]:-}"
      [[ -z "$mt" ]] && continue
      cache_full["$fp"]="$mt"$'\t'"$aa"$'\t'"$fp"$'\t'"$ti"$'\t'"$al"$'\t'"$ge"$'\t'"$yr"$'\t'"$trk"$'\t'"$dur"$'\t'"$bpm"
    done < "$exif_out"
  fi

  local new_cache_file="${CACHE_FILE}.new"
  rm -f "$new_cache_file"
  : > "$new_cache_file"
  for fp in "${!cur_mtime[@]}"; do
    if [[ -n "${cache_full[$fp]:-}" ]]; then
      printf '%s\n' "${cache_full[$fp]}" >> "$new_cache_file"
    fi
  done
  mv "$new_cache_file" "$CACHE_FILE"

  local final_count
  final_count=$(wc -l < "$CACHE_FILE" | tr -d ' ')
  log "Cache updated: $final_count entries total, $new_count new/updated"
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
          album|genre|year|title|artist|track|duration|bpm|added) ;;
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
      function evalCond(f, op, v, aa, ti, al, ge, yr, trk, dur, bpm, mt, now,   daysAgo) {
        if (f == "year")         return numMatch(yr, op, v)
        if (f == "track")        return numMatch(trk, op, v)
        if (f == "duration")     return numMatch(dur, op, v)
        if (f == "bpm")          return numMatch(bpm, op, v)
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
        mt = $1; aa = $2; fp = $3; ti = $4; al = $5; ge = $6; yr = $7; trk = $8; dur = $9; bpm = $10
        if (allArtists != 1 && !(norm(aa) in wantedSet)) next

        # Each group is AND-combined with the others; within a group,
        # sub-conditions are OR-combined (conjunctive normal form).
        ok = 1
        for (gi = 1; gi <= numGroups; gi++) {
          groupOk = 0
          for (sj = 1; sj <= groupSize[gi]; sj++) {
            if (evalCond(gField[gi, sj], gOp[gi, sj], gVal[gi, sj], aa, ti, al, ge, yr, trk, dur, bpm, mt, now)) {
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

    cat "$ordered_tracks" \
      | while IFS=$'\t' read -r fp ti al aa trk yr added; do
          uri="$(uri_for_path "$fp")"
          # "-" is our internal placeholder for "no value" (see the note
          # in update_cache on why real empty fields are avoided) - map
          # it back to something sensible for display instead of showing
          # a literal dash in the Volumio UI.
          title="$ti"
          [[ -z "$title" || "$title" == "-" ]] && title="$(basename "$fp")"
          [[ "$aa" == "-" ]] && aa=""
          [[ "$al" == "-" ]] && al=""
          jq -n --arg service "mpd" \
                --arg uri "$uri" \
                --arg title "$title" \
                --arg artist "$aa" \
                --arg album "$al" \
                '{service:$service, uri:$uri, title:$title, artist:$artist, album:$album}'
        done \
      | jq -s '.' > "$outfile"

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
