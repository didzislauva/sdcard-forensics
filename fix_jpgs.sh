#!/usr/bin/env bash

set -u

OUT_DIR="${1:-fixed_reencode}"
LOG_DIR="${2:-repair_logs}"

mkdir -p "$OUT_DIR" "$LOG_DIR"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_cmd jpeginfo
require_cmd identify
require_cmd exiftool

if command -v magick >/dev/null 2>&1; then
  REENCODER="magick"
elif command -v convert >/dev/null 2>&1; then
  REENCODER="convert"
else
  echo "Missing ImageMagick re-encoder: magick or convert" >&2
  exit 1
fi

mapfile -d '' FILES < <(find . -maxdepth 1 -type f \( -iname '*.jpg' -o -iname '*.jpeg' \) -print0 | sort -z)

if [ "${#FILES[@]}" -eq 0 ]; then
  echo "No JPEG files found in current directory."
  exit 0
fi

LOG1="$LOG_DIR/01_jpeginfo.txt"
LOG2="$LOG_DIR/02_identify_errors.txt"
LOG3="$LOG_DIR/03_exiftool.txt"
LOG4="$LOG_DIR/04_reencode_errors.txt"
LOG5="$LOG_DIR/05_fixed_check.txt"
LOG6="$LOG_DIR/06_fixed_identify_errors.txt"
LOG7="$LOG_DIR/07_carved_map.csv"
LOG8="$LOG_DIR/08_carve_errors.txt"
LOG9="$LOG_DIR/09_carved_check.txt"
LOG10="$LOG_DIR/10_carved_identify_errors.txt"

BROKEN_LIST="$LOG_DIR/broken.txt"
TMP1="$LOG_DIR/.broken_from_jpeginfo.tmp"
TMP2="$LOG_DIR/.broken_from_identify.tmp"
TMP3="$LOG_DIR/.broken_from_exiftool.tmp"
CARVE_DIR="$OUT_DIR/carved"

: >"$LOG1"
: >"$LOG2"
: >"$LOG3"
: >"$LOG4"
: >"$LOG5"
: >"$LOG6"
: >"$LOG8"
: >"$LOG9"
: >"$LOG10"
: >"$TMP1"
: >"$TMP2"
: >"$TMP3"
mkdir -p "$CARVE_DIR"
echo "source_file,start_offset,end_offset,size_bytes,carved_file" >"$LOG7"

echo "Running triage on ${#FILES[@]} files..."
for f in "${FILES[@]}"; do
  file="${f#./}"
  jpeginfo -c "$file" >>"$LOG1" 2>&1 || true
  identify "$file" >/dev/null 2>>"$LOG2" || true
  exiftool -warning -error "$file" >>"$LOG3" 2>&1 || true
done

# jpeginfo: collect non-OK records
awk '
  /\[OK\]$/ {next}
  NF > 0 {print $1}
' "$LOG1" | sort -u >"$TMP1"

# identify: extract filename from "... `file.JPG'" pattern
sed -n "s/.*\`\([^']*\)'.*/\1/p" "$LOG2" | sort -u >"$TMP2"

# exiftool: map warning/error lines back to the active file section
awk '
  /^======== / {current = substr($0, 10); next}
  /Warning|Error/ {if (current != "") print current}
' "$LOG3" | sort -u >"$TMP3"

cat "$TMP1" "$TMP2" "$TMP3" | awk 'NF > 0' | sort -u >"$BROKEN_LIST"

BROKEN_COUNT="$(wc -l <"$BROKEN_LIST" | tr -d '[:space:]')"
TOTAL_COUNT="${#FILES[@]}"

if [ "$BROKEN_COUNT" -eq 0 ]; then
  echo "No broken files detected."
  echo "Total checked: $TOTAL_COUNT"
  exit 0
fi

echo "Detected $BROKEN_COUNT potentially broken files. Re-encoding with $REENCODER..."
while IFS= read -r file; do
  [ -n "$file" ] || continue
  [ -f "$file" ] || continue
  out_file="$OUT_DIR/$(basename "$file")"
  if [ "$REENCODER" = "magick" ]; then
    magick "$file" -strip -quality 92 "$out_file" 2>>"$LOG4" || true
  else
    convert "$file" -strip -quality 92 "$out_file" 2>>"$LOG4" || true
  fi
done <"$BROKEN_LIST"

FIXED_COUNT=0
mapfile -d '' FIXED_FILES < <(find "$OUT_DIR" -maxdepth 1 -type f \( -iname '*.jpg' -o -iname '*.jpeg' \) -print0 | sort -z)
for f in "${FIXED_FILES[@]}"; do
  file="${f#./}"
  jpeginfo -c "$file" >>"$LOG5" 2>&1 || true
  identify "$file" >/dev/null 2>>"$LOG6" || true
  FIXED_COUNT=$((FIXED_COUNT + 1))
done

CARVED_COUNT=0
CARVE_SOURCES=0
echo "Scanning broken files for embedded JPEG markers (FF D8 ... FF D9)..."
while IFS= read -r file; do
  [ -n "$file" ] || continue
  [ -f "$file" ] || continue

  mapfile -t STARTS < <(grep -aob $'\xFF\xD8' "$file" | cut -d: -f1 || true)
  mapfile -t ENDS < <(grep -aob $'\xFF\xD9' "$file" | cut -d: -f1 || true)
  [ "${#STARTS[@]}" -gt 0 ] || continue
  [ "${#ENDS[@]}" -gt 0 ] || continue

  CARVE_SOURCES=$((CARVE_SOURCES + 1))
  eidx=0
  local_count=0

  for s in "${STARTS[@]}"; do
    while [ "$eidx" -lt "${#ENDS[@]}" ] && [ "${ENDS[$eidx]}" -le "$s" ]; do
      eidx=$((eidx + 1))
    done
    [ "$eidx" -lt "${#ENDS[@]}" ] || break

    e="${ENDS[$eidx]}"
    size=$((e - s + 2))
    # Skip implausibly tiny chunks.
    [ "$size" -ge 256 ] || continue

    local_count=$((local_count + 1))
    stem="$(basename "$file")"
    stem="${stem%.*}"
    carved="$CARVE_DIR/${stem}__carved_$(printf '%03d' "$local_count").jpg"

    if ! dd if="$file" of="$carved" bs=1 skip="$s" count="$size" status=none 2>>"$LOG8"; then
      continue
    fi

    if jpeginfo -c "$carved" >>"$LOG9" 2>&1 && identify "$carved" >/dev/null 2>>"$LOG10"; then
      CARVED_COUNT=$((CARVED_COUNT + 1))
      printf '%s,%s,%s,%s,%s\n' "$file" "$s" "$e" "$size" "$carved" >>"$LOG7"
    else
      rm -f "$carved"
    fi
  done
done <"$BROKEN_LIST"

echo "Done."
echo "Total checked: $TOTAL_COUNT"
echo "Broken detected: $BROKEN_COUNT"
echo "Re-encoded outputs: $FIXED_COUNT"
echo "Carved valid JPEGs: $CARVED_COUNT"
echo "Files with marker hits: $CARVE_SOURCES"
echo "Logs: $LOG_DIR"
echo "Broken list: $BROKEN_LIST"
echo "Carve map: $LOG7"
