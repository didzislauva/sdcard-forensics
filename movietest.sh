#!/usr/bin/env bash
# ============================================================
# check_mov_integrity.sh
#
# Recursive integrity check for .mov files using ffprobe+ffmpeg.
# Designed for Linux Mint.
#
# What it does per file:
#   1) ffprobe: verifies container + streams readable
#   2) ffmpeg decode: decodes *all streams* to null sink and reports decode errors
#
# Output:
#   - logs/ffprobe/<relative_path>.ffprobe.log  (only if errors)
#   - logs/ffmpeg/<relative_path>.ffmpeg.log    (kept for FAIL/WARN; removed for OK)
#   - summary.csv (one line per file with health score and comments)
#
# Usage:
#   chmod +x check_mov_integrity.sh
#   ./check_mov_integrity.sh /path/to/movies
#
# Notes:
# - This reads all files fully (can take time).
# - Does NOT re-encode; it only decodes to /dev/null.
# ============================================================

set -euo pipefail

ROOT="${1:-.}"

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "ERROR: ffmpeg not found. Install: sudo apt-get install ffmpeg"
  exit 1
fi
if ! command -v ffprobe >/dev/null 2>&1; then
  echo "ERROR: ffprobe not found (usually comes with ffmpeg). Install: sudo apt-get install ffmpeg"
  exit 1
fi

# Logs + summary
TS="$(date +%Y%m%d_%H%M%S)"
OUTDIR="mov_check_${TS}"
LOG_PROBE="${OUTDIR}/logs/ffprobe"
LOG_FFMPEG="${OUTDIR}/logs/ffmpeg"
mkdir -p "$LOG_PROBE" "$LOG_FFMPEG"

SUMMARY="${OUTDIR}/summary.tsv"
SUMMARY="${OUTDIR}/summary.csv"
# Columns: status, score, file, bytes, duration_s, vcodec, acodec, comments
printf "status,score,file,bytes,duration_s,vcodec,acodec,comments\n" > "$SUMMARY"

echo "[*] Root: $ROOT"
echo "[*] Output dir: $OUTDIR"
echo "[*] Finding .mov files recursively..."
echo

# Make a filesystem-safe filename for logs (preserve structure but sanitize)
safe_log_name() {
  local path="$1"
  # Remove leading ./ and root prefix, replace slashes with __
  path="${path#./}"
  path="${path//\//__}"
  # Replace spaces with _
  path="${path// /_}"
  echo "$path"
}

# Extract basic metadata via ffprobe (fast)
probe_meta() {
  local f="$1"
  # duration (seconds, float), vcodec, acodec
  # We use first video stream and first audio stream.
  ffprobe -v error \
    -select_streams v:0 \
    -show_entries stream=codec_name \
    -of default=nk=1:nw=1 "$f" 2>/dev/null | head -n 1
}

probe_meta_audio() {
  local f="$1"
  ffprobe -v error \
    -select_streams a:0 \
    -show_entries stream=codec_name \
    -of default=nk=1:nw=1 "$f" 2>/dev/null | head -n 1
}

probe_duration() {
  local f="$1"
  ffprobe -v error \
    -show_entries format=duration \
    -of default=nk=1:nw=1 "$f" 2>/dev/null | head -n 1
}

file_size_bytes() {
  stat -c%s "$1"
}

# Decide WARN vs FAIL based on ffmpeg output
# FAIL if it contains typical fatal decode/container errors.
# WARN if only non-fatal warnings appear.
classify_ffmpeg_log() {
  local log="$1"
  # If empty -> OK
  if [ ! -s "$log" ]; then
    echo "OK"
    return
  fi

  # Common fatal-ish markers (exclude ambiguous warnings like "End of file")
  if grep -Eqi \
    'Invalid data found|moov atom not found|error while decoding|corrupt|could not find codec parameters|header damaged|I/O error|packet too short|missing picture|decode_slice_header error|CRC mismatch' \
    "$log"; then
    echo "FAIL"
    return
  fi

  # Otherwise, treat as WARN
  echo "WARN"
}

# CSV-safe quoting
csv_q() {
  local s="${1:-}"
  s="${s//\"/\"\"}"
  printf "\"%s\"" "$s"
}

# Extract human-friendly comments from logs
collect_comments() {
  local probe_log="$1"
  local ff_log="$2"
  local comments=""

  if [ -s "$probe_log" ]; then
    comments="${comments}ffprobe_error;"
  fi

  if [ -s "$ff_log" ]; then
    if grep -Eqi 'moov atom not found' "$ff_log"; then
      comments="${comments}moov_atom_missing;"
    fi
    if grep -Eqi 'Invalid data found' "$ff_log"; then
      comments="${comments}invalid_data;"
    fi
    if grep -Eqi 'could not find codec parameters' "$ff_log"; then
      comments="${comments}codec_params_missing;"
    fi
    if grep -Eqi 'header damaged' "$ff_log"; then
      comments="${comments}header_damaged;"
    fi
    if grep -Eqi 'CRC mismatch' "$ff_log"; then
      comments="${comments}crc_mismatch;"
    fi
    if grep -Eqi 'error while decoding' "$ff_log"; then
      comments="${comments}decode_error;"
    fi
    if grep -Eqi 'non monotonically increasing dts' "$ff_log"; then
      comments="${comments}non_monotonic_dts;"
    fi
    if grep -Eqi 'End of file|Truncated' "$ff_log"; then
      comments="${comments}truncated_or_eof;"
    fi
  fi

  comments="${comments%;}"
  echo "${comments:-NA}"
}

# We will iterate with find -print0 to handle odd filenames safely.
COUNT=0
OK=0
WARN=0
FAIL=0

while IFS= read -r -d '' f; do
  COUNT=$((COUNT+1))

  # Create a readable relative path for reporting
  rel="$f"
  # If ROOT is absolute, try to strip it for nicer logs
  if [[ "$ROOT" != "." ]]; then
    # Normalize: remove trailing slash from ROOT
    root_norm="${ROOT%/}"
    rel="${f#"$root_norm"/}"
  else
    rel="${f#./}"
  fi

  echo "[$COUNT] Checking: $rel"

  # Collect quick metadata
  bytes="$(file_size_bytes "$f")"
  dur="$(probe_duration "$f" || true)"
  vcodec="$(probe_meta "$f" || true)"
  acodec="$(probe_meta_audio "$f" || true)"

  # ffprobe strict check (container/streams readable)
  probe_log="${LOG_PROBE}/$(safe_log_name "$rel").ffprobe.log"
  if ffprobe -v error -show_format -show_streams "$f" > /dev/null 2> "$probe_log"; then
    # No errors; remove empty log
    rm -f "$probe_log"
    probe_note=""
  else
    probe_note="ffprobe_error"
    # keep the probe log
  fi

  # ffmpeg full decode test: decode ALL streams to null sink
  # -v error: only errors
  # -stats: show progress
  # -map 0: include all streams (video, audio, timecode, etc.)
  ff_log="${LOG_FFMPEG}/$(safe_log_name "$rel").ffmpeg.log"

  # Run ffmpeg. We send stderr to log and also show progress in terminal.
  # (ffmpeg prints progress to stderr; -stats makes it visible.)
  # We keep the full stderr log for classification.
  set +e
  ffmpeg -nostdin -v error -stats -i "$f" -map 0 -f null - 2> "$ff_log"
  rc=$?
  set -e

  # Classify results
  status="$(classify_ffmpeg_log "$ff_log")"

  # If ffmpeg exit code non-zero, force at least WARN/FAIL (never OK)
  if [ $rc -ne 0 ] && [ "$status" = "OK" ]; then
    status="WARN"
  fi

  # Comments and score
  comments="$(collect_comments "$probe_log" "$ff_log")"

  score=100
  if [ -n "${probe_note}" ]; then
    score=$((score-30))
  fi
  if [ $rc -ne 0 ]; then
    score=$((score-20))
  fi
  if [ "$status" = "WARN" ]; then
    score=$((score-15))
  fi
  if [ "$status" = "FAIL" ]; then
    score=$((score-60))
  fi
  if [ "${dur:-}" = "NA" ] || [ -z "${dur:-}" ]; then
    score=$((score-5))
  fi
  if [ $score -lt 0 ]; then
    score=0
  fi
  if [ $score -gt 100 ]; then
    score=100
  fi
  if [ "$status" = "OK" ]; then
    # Clean up log to keep output small
    rm -f "$ff_log"
    OK=$((OK+1))
  elif [ "$status" = "WARN" ]; then
    WARN=$((WARN+1))
  else
    FAIL=$((FAIL+1))
  fi

  # Fill unknown fields nicely
  dur="${dur:-NA}"
  vcodec="${vcodec:-NA}"
  acodec="${acodec:-NA}"

  printf "%s,%s,%s,%s,%s,%s,%s,%s\n" \
    "$status" \
    "$score" \
    "$(csv_q "$rel")" \
    "$bytes" \
    "$dur" \
    "$(csv_q "$vcodec")" \
    "$(csv_q "$acodec")" \
    "$(csv_q "$comments")" >> "$SUMMARY"

  echo "    => $status"
  echo
done < <(find "$ROOT" -type f \( -iname '*.mov' \) -print0)

echo "============================================================"
echo "[*] Done."
echo "[*] Total: $COUNT  OK: $OK  WARN: $WARN  FAIL: $FAIL"
echo "[*] Summary: $SUMMARY"
echo "[*] Logs kept under: $OUTDIR/logs/"
echo "============================================================"
