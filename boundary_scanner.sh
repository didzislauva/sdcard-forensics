#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  boundary_scanner.sh [options]

Options:
  -f, --file PATH        Image file to scan (default: image.dd)
  -b, --block-mib N       Block size in MiB (default: 1)
  -p, --pad-bytes "..."   Pad bytes in hex (default: "ff")
  -m, --method METHOD     Scan method: dd, tail, grep (default: dd)
  -c, --chunk-mib N       Chunk size in MiB for tail method (default: 64)
  -s, --start-block N     Start scanning from block N (default: last block)
  -P, --profile SIZE      Start from card size profile: 1g,2g,4g,8g,16g,32g,64g,128g (GiB)
  -x, --extract-out FILE  Extract image up to last non-pad sector into FILE
  -L, --extract-last FILE Extract only the last non-pad sector (512 bytes) into FILE
  -B, --extract-boundary FILE
                          Extract last non-pad and first pad sectors into FILE
  --log-file FILE         Write full output to FILE (default: boundary_scanner/scan_YYYYmmdd_HHMMSS.log)
  -q, --quiet            Suppress console output (log still written)
  --progress N            Progress update interval in blocks (default: 100)
  --no-refine             Skip sector-level boundary refinement (default: refine)
  -h, --help              Show help
  
Notes:
  --profile sets the start block based on the GiB card size. If both
  --start-block and --profile are set, --start-block wins. Start block
  is clamped to the image size if it exceeds total blocks.
  --extract-out writes a new file up to the last non-pad sector.
  --extract-last writes only the last non-pad 512-byte sector.
  --extract-boundary writes last and first sectors into a single file.
  --log-file controls the log destination (directory is created if needed).
  --quiet suppresses console output but still writes the log.
  Warning: Results are indicative only and do not prove a card is fake.

Examples:
  boundary_scanner.sh -f fake_image.dd
  boundary_scanner.sh -f image.dd -p "ff 00" -b 2 -m tail
  boundary_scanner.sh -f image.dd -P 8g
  boundary_scanner.sh -f image.dd -s 5000
  boundary_scanner.sh -f image.dd -x trimmed.dd
  boundary_scanner.sh -f image.dd -L last_sector.bin
  boundary_scanner.sh -f image.dd -B boundary.bin
  boundary_scanner.sh -f image.dd --log-file boundary_scanner/custom.log
  boundary_scanner.sh -f image.dd -q
USAGE
}

if [[ -t 1 ]]; then
  C_RED=$'\033[0;31m'
  C_GREEN=$'\033[0;32m'
  C_YELLOW=$'\033[0;33m'
  C_BLUE=$'\033[0;34m'
  C_MAGENTA=$'\033[0;35m'
  C_CYAN=$'\033[0;36m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RESET=$'\033[0m'
else
  C_RED=""
  C_GREEN=""
  C_YELLOW=""
  C_BLUE=""
  C_MAGENTA=""
  C_CYAN=""
  C_BOLD=""
  C_DIM=""
  C_RESET=""
fi

die() { echo "${C_RED}ERROR:${C_RESET} $1" >&2; exit 1; }

# Decorative banner.
banner() {
  echo "${C_MAGENTA}========================================${C_RESET}"
  echo "${C_BOLD}${C_CYAN}   Boundary Scanner${C_RESET}${C_DIM}  (last non-pad finder)${C_RESET}"
  echo "${C_MAGENTA}========================================${C_RESET}"
}

# CLI parsing -> sets globals used across the scan pipeline.
parse_args() {
  FILE=""
  BLOCK_MIB=1
  PAD_BYTES="ff"
  METHOD="dd"
  CHUNK_MIB=64
  START_BLOCK=-1
  PROFILE=""
  EXTRACT_OUT=""
  EXTRACT_LAST_OUT=""
  EXTRACT_BOUNDARY_OUT=""
  LOG_FILE=""
  QUIET=0
  PROGRESS_EVERY=100
  REFINE=1
  RESULT_FOUND=0
  LAST_BLOCK=-1
  LAST_NONPAD_SECTOR=-1
  LAST_NONPAD_BYTE_OFF=-1
  BLOCK_CHECKS=0
  CHUNK_CHECKS=0
  REFINES=0
  BLOCK_BYTES_READ=0
  CHUNK_BYTES_READ=0
  REFINE_BYTES_READ=0
  EXTRACT_BYTES_WRITTEN=0
  EXTRACTED_OUT=0
  EXTRACTED_LAST=0
  EXTRACTED_BOUNDARY=0
  GREP_P_OK=0
  PROGRESS_FD=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f|--file) FILE="$2"; shift 2 ;;
      -b|--block-mib) BLOCK_MIB="$2"; shift 2 ;;
      -p|--pad-bytes) PAD_BYTES="$2"; shift 2 ;;
      -m|--method) METHOD="$2"; shift 2 ;;
      -c|--chunk-mib) CHUNK_MIB="$2"; shift 2 ;;
      -s|--start-block) START_BLOCK="$2"; shift 2 ;;
      -P|--profile) PROFILE="$2"; shift 2 ;;
      -x|--extract-out) EXTRACT_OUT="$2"; shift 2 ;;
      -L|--extract-last) EXTRACT_LAST_OUT="$2"; shift 2 ;;
      -B|--extract-boundary) EXTRACT_BOUNDARY_OUT="$2"; shift 2 ;;
      --log-file) LOG_FILE="$2"; shift 2 ;;
      -q|--quiet) QUIET=1; shift ;;
      --progress) PROGRESS_EVERY="$2"; shift 2 ;;
      --no-refine) REFINE=0; shift ;;
      -h|--help) usage; exit 0 ;;
      -* ) die "Unknown option: $1" ;;
      * )
        [[ -n "$FILE" ]] && die "Unexpected extra argument: $1"
        FILE="$1"; shift ;;
    esac
  done

  [[ -n "$FILE" ]] || { usage; die "Missing --file"; }
  [[ -f "$FILE" ]] || die "File not found: $FILE"
}

# Verify required tools and method-specific capabilities.
check_tools() {
  local need=(dd tr grep stat awk)
  local miss=()
  GREP_P_OK=1
  echo "${C_BLUE}Tool check:${C_RESET}"
  for t in "${need[@]}"; do
    if command -v "$t" >/dev/null 2>&1; then
      echo "  ${C_GREEN}OK${C_RESET}  $t"
    else
      echo "  ${C_RED}MISSING${C_RESET}  $t"
      miss+=("$t")
    fi
  done
  if [[ "${#miss[@]}" -gt 0 ]]; then
    die "Missing required tools: ${miss[*]}"
  fi
  if [[ "$METHOD" == "grep" ]]; then
    if ! echo "" | grep -P "" >/dev/null 2>&1; then
      die "Method grep requires grep with -P support"
    fi
  fi
  if ! echo "" | grep -P "" >/dev/null 2>&1; then
    GREP_P_OK=0
  fi
}

# Compute image size, block size (BS), and total block count.
read_image_size() {
  size_bytes=$(stat -c%s "$FILE" 2>/dev/null || stat -f%z "$FILE")
  BS=$((BLOCK_MIB*1024*1024))
  total_blocks=$(( (size_bytes + BS - 1) / BS ))
}

# Resolve the effective start block from explicit start/profile/default.
resolve_start_block() {
  local profile_blocks=-1
  if [[ -n "$PROFILE" ]]; then
    case "${PROFILE,,}" in
      1g) profile_blocks=$(( (1 * 1024 * 1024 * 1024 + BS - 1) / BS )) ;;
      2g) profile_blocks=$(( (2 * 1024 * 1024 * 1024 + BS - 1) / BS )) ;;
      4g) profile_blocks=$(( (4 * 1024 * 1024 * 1024 + BS - 1) / BS )) ;;
      8g) profile_blocks=$(( (8 * 1024 * 1024 * 1024 + BS - 1) / BS )) ;;
      16g) profile_blocks=$(( (16 * 1024 * 1024 * 1024 + BS - 1) / BS )) ;;
      32g) profile_blocks=$(( (32 * 1024 * 1024 * 1024 + BS - 1) / BS )) ;;
      64g) profile_blocks=$(( (64 * 1024 * 1024 * 1024 + BS - 1) / BS )) ;;
      128g) profile_blocks=$(( (128 * 1024 * 1024 * 1024 + BS - 1) / BS )) ;;
      *) die "Unknown profile: $PROFILE (use 1g,2g,4g,8g,16g,32g,64g,128g)";;
    esac
  fi

  if [[ "$START_BLOCK" -ge 0 ]]; then
    START_BLOCK_EFF="$START_BLOCK"
  elif [[ "$profile_blocks" -gt 0 ]]; then
    START_BLOCK_EFF=$((profile_blocks - 1))
  else
    START_BLOCK_EFF=$((total_blocks - 1))
  fi

  if [[ "$START_BLOCK_EFF" -ge "$total_blocks" ]]; then
    START_BLOCK_EFF=$((total_blocks - 1))
  fi

  if [[ "$PROGRESS_EVERY" -gt 0 ]]; then
    NEXT_PROGRESS=$((START_BLOCK_EFF - (START_BLOCK_EFF % PROGRESS_EVERY)))
  else
    NEXT_PROGRESS=-1
  fi
}

# Build a tr delete set from hex pad bytes for fast "non-pad" detection.
build_tr_delete_set() {
  local out="" h oct
  for h in $PAD_BYTES; do
    h="${h#0x}"; h="${h,,}"
    [[ "$h" =~ ^[0-9a-f]{2}$ ]] || die "Invalid pad byte: $h"
    oct="$(printf '%03o' "0x$h")"
    out+="\\$oct"
  done
  TR_DELETE_SET="$out"
}

# Build a grep pattern that matches any non-pad byte.
build_grep_pattern() {
  local pattern h
  pattern="[^"
  for h in $PAD_BYTES; do
    h="${h#0x}"; h="${h,,}"
    pattern+="\\x$h"
  done
  pattern+="]"
  GREP_PATTERN="$pattern"
}

init_logging() {
  local log_dir ts
  if [[ -z "$LOG_FILE" ]]; then
    log_dir="boundary_scanner"
    ts="$(date +%Y%m%d_%H%M%S)"
    LOG_FILE="${log_dir}/scan_${ts}.log"
  else
    log_dir="$(dirname "$LOG_FILE")"
  fi
  mkdir -p "$log_dir"

  # Decide progress output target before redirecting stdout.
  if [[ "$QUIET" -eq 0 && -w /dev/tty ]]; then
    PROGRESS_FD="/dev/tty"
  fi
  if [[ "$QUIET" -eq 1 ]]; then
    exec > >(sed -E 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE") 2>&1
  else
    exec > >(tee >(sed -E 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE")) 2>&1
  fi
  echo "${C_BLUE}Logging to:${C_RESET}   $LOG_FILE"

  # Silent probe for grep -P availability (used for last-byte offset).
  if echo "" | grep -P "" >/dev/null 2>&1; then
    GREP_P_OK=1
  else
    GREP_P_OK=0
  fi

}

# Print effective configuration before scanning.
print_plan() {
  echo "${C_CYAN}Image:${C_RESET}        ${C_BOLD}$FILE${C_RESET}"
  echo "${C_CYAN}Size:${C_RESET}         $size_bytes bytes"
  echo "${C_CYAN}Block size:${C_RESET}   ${BLOCK_MIB} MiB (BS=$BS bytes)"
  echo "${C_CYAN}Total blocks:${C_RESET} $total_blocks"
  echo "${C_CYAN}Pad bytes:${C_RESET}    $PAD_BYTES"
  echo "${C_CYAN}Method:${C_RESET}       ${C_YELLOW}$METHOD${C_RESET}"
  if [[ -n "$PROFILE" ]]; then
    echo "${C_CYAN}Profile:${C_RESET}      ${PROFILE,,} (GiB)"
  fi
  echo "${C_CYAN}Start block:${C_RESET}  $START_BLOCK_EFF"
  if [[ -n "$EXTRACT_OUT" ]]; then
    echo "${C_CYAN}Extract out:${C_RESET}  $EXTRACT_OUT"
  fi
  if [[ -n "$EXTRACT_LAST_OUT" ]]; then
    echo "${C_CYAN}Extract last:${C_RESET} $EXTRACT_LAST_OUT"
  fi
  if [[ -n "$EXTRACT_BOUNDARY_OUT" ]]; then
    echo "${C_CYAN}Extract boundary:${C_RESET} $EXTRACT_BOUNDARY_OUT"
  fi
  if [[ "$METHOD" == "tail" ]]; then
    echo "${C_CYAN}Chunk size:${C_RESET}   ${CHUNK_MIB} MiB"
  fi
  if [[ "$PROGRESS_EVERY" -gt 0 ]]; then
    echo "${C_CYAN}Progress:${C_RESET}     every ${PROGRESS_EVERY} blocks"
  else
    echo "${C_CYAN}Progress:${C_RESET}     disabled"
  fi
  echo
}

# Progress update for single-block scans.
progress_update() {
  local cur="$1"
  if [[ "$PROGRESS_EVERY" -le 0 ]]; then
    return
  fi
  if [[ -z "$PROGRESS_FD" ]]; then
    return
  fi
  if [[ "$PROGRESS_EVERY" -eq 1 || $((cur % PROGRESS_EVERY)) -eq 0 ]]; then
    printf "\rChecking block %d/%d..." "$cur" "$total_blocks" >"$PROGRESS_FD"
  fi
}

# Progress update for chunk scans (tail/grep), aligned to block numbers.
progress_update_range() {
  local start="$1" end="$2"
  if [[ "$PROGRESS_EVERY" -le 0 ]]; then
    return
  fi
  if [[ -z "$PROGRESS_FD" ]]; then
    return
  fi
  while (( NEXT_PROGRESS >= start )); do
    printf "\rChecking block %d/%d..." "$NEXT_PROGRESS" "$total_blocks" >"$PROGRESS_FD"
    NEXT_PROGRESS=$((NEXT_PROGRESS - PROGRESS_EVERY))
  done
}

# Final progress line with newline.
final_progress() {
  if [[ "$PROGRESS_EVERY" -gt 0 ]]; then
    if [[ -n "$PROGRESS_FD" ]]; then
      printf "\rChecking block %d/%d... done\n" "$1" "$total_blocks" >"$PROGRESS_FD"
    fi
  fi
}

# Check if a byte range has any non-pad data (slow path for refinement).
chunk_has_nonpad() {
  local off="$1" sz="$2" n
  CHUNK_CHECKS=$((CHUNK_CHECKS + 1))
  REFINE_BYTES_READ=$((REFINE_BYTES_READ + sz))
  n="$(dd if="$FILE" bs=1 skip="$off" count="$sz" status=none \
    | tr -d "$TR_DELETE_SET" | wc -c | tr -d ' ')"
  [[ "${n:-0}" -gt 0 ]]
}

# Check if a block has any non-pad data (fast path for scanning).
block_has_nonpad() {
  # Fast path: block-aligned read at block size.
  local n
  BLOCK_CHECKS=$((BLOCK_CHECKS + 1))
  BLOCK_BYTES_READ=$((BLOCK_BYTES_READ + BS))
  n="$(dd if="$FILE" bs="$BS" skip="$1" count=1 status=none \
    | tr -d "$TR_DELETE_SET" | wc -c | tr -d ' ')"
  [[ "${n:-0}" -gt 0 ]]
}

# Extract to output file up to last non-pad sector (exclusive of pad).
extract_up_to_boundary() {
  local last_nonpad_sector="$1"
  local out="$2"
  local sector_size=512
  local count_sectors=$((last_nonpad_sector + 1))
  local bytes=$((count_sectors * sector_size))
  if [[ "$bytes" -le 0 ]]; then
    die "Extract size is zero; refusing to write $out"
  fi
  dd if="$FILE" of="$out" bs="$sector_size" count="$count_sectors" status=none
  EXTRACT_BYTES_WRITTEN=$((EXTRACT_BYTES_WRITTEN + bytes))
  EXTRACTED_OUT=1
  echo "Extracted $bytes bytes to $out"
}

extract_last_sector() {
  local last_nonpad_sector="$1"
  local out="$2"
  local sector_size=512
  if (( last_nonpad_sector < 0 )); then
    die "No non-pad sector found; refusing to write $out"
  fi
  dd if="$FILE" of="$out" bs="$sector_size" skip="$last_nonpad_sector" count=1 status=none
  EXTRACT_BYTES_WRITTEN=$((EXTRACT_BYTES_WRITTEN + sector_size))
  EXTRACTED_LAST=1
  echo "Extracted last sector to $out"
}

extract_boundary_sectors() {
  local last_nonpad_sector="$1"
  local first_pad_sector="$2"
  local out="$3"
  local sector_size=512
  if (( last_nonpad_sector < 0 )); then
    die "No non-pad sector found; refusing to write boundary sectors"
  fi
  dd if="$FILE" of="$out" bs="$sector_size" skip="$last_nonpad_sector" count=1 status=none
  EXTRACT_BYTES_WRITTEN=$((EXTRACT_BYTES_WRITTEN + sector_size))
  EXTRACTED_BOUNDARY=1
  if (( first_pad_sector * sector_size >= size_bytes )); then
    echo "First pad sector is EOF; wrote only last sector to $out"
  else
    dd if="$FILE" of="$out" bs="$sector_size" seek=1 skip="$first_pad_sector" count=1 conv=notrunc status=none
    EXTRACT_BYTES_WRITTEN=$((EXTRACT_BYTES_WRITTEN + sector_size))
    echo "Extracted boundary sectors to $out"
  fi
}

# Refine within the last non-pad block down to sector-level boundary.
refine_boundary() {
  local last_block="$1"
  REFINES=$((REFINES + 1))
  echo "${C_BOLD}Refine:${C_RESET} starting block-level refinement for block $last_block"
  local range_start=$((last_block * BS))
  local range_end=$(( (last_block + 1) * BS ))
  (( range_end > size_bytes )) && range_end="$size_bytes"

  local range_size=$((range_end - range_start))
  local step=$((range_size / 4))
  local found_start="$range_start" found_end="$range_end"

  while (( step >= 512 )); do
    echo "${C_BOLD}Refine:${C_RESET} narrowing range [$found_start,$found_end) step=$step"
    local i seg_start seg_end
    for ((i=3; i>=0; i--)); do
      seg_start=$((found_start + i*step))
      seg_end=$((seg_start + step))
      (( seg_end > found_end )) && seg_end="$found_end"
      if chunk_has_nonpad "$seg_start" $((seg_end - seg_start)); then
        found_start="$seg_start"
        found_end="$seg_end"
        break
      fi
    done
    step=$(((found_end - found_start) / 4))
  done

  # Sector-level scan backwards to find last non-pad sector.
  echo "${C_BOLD}Refine:${C_RESET} sector scan in narrowed range [$found_start,$found_end)"
  local sector_size=512
  local last_nonpad_sector=-1
  local s_end=$(( (found_end + sector_size - 1) / sector_size ))
  local s_start=$(( found_start / sector_size ))
  local s
  for ((s=s_end-1; s>=s_start; s--)); do
    if chunk_has_nonpad $((s * sector_size)) "$sector_size"; then
      last_nonpad_sector="$s"
      break
    fi
  done

  if (( last_nonpad_sector < 0 )); then
    echo "Refine: no non-pad data found in the last block (unexpected)."
    return
  fi

  local first_pad_sector=$((last_nonpad_sector + 1))
  local last_nonpad_off=$((last_nonpad_sector * sector_size))
  local first_pad_off=$((first_pad_sector * sector_size))
  local last_byte_in_sector
  local last_nonpad_byte_off=-1
  if [[ "$GREP_P_OK" -eq 1 ]]; then
    build_grep_pattern
    last_byte_in_sector="$(dd if="$FILE" bs="$sector_size" skip="$last_nonpad_sector" count=1 status=none \
      | LC_ALL=C grep -aob -P "$GREP_PATTERN" | tail -n 1 | cut -d: -f1 || true)"
    if [[ -n "${last_byte_in_sector:-}" ]]; then
      last_nonpad_byte_off=$((last_nonpad_off + last_byte_in_sector))
      LAST_NONPAD_BYTE_OFF="$last_nonpad_byte_off"
    fi
  fi
  LAST_NONPAD_SECTOR="$last_nonpad_sector"
  echo "${C_GREEN}Refine: completed${C_RESET}"
  echo "Refined boundary:"
  echo "  Last non-pad sector:  $last_nonpad_sector (offset $last_nonpad_off bytes)"
  if [[ "$last_nonpad_byte_off" -ge 0 ]]; then
    echo "  Last non-pad byte:    offset $last_nonpad_byte_off bytes"
  else
    echo "  Last non-pad byte:    unavailable (grep -P not supported)"
  fi
  if (( first_pad_off >= size_bytes )); then
    echo "  First pad sector:     EOF (file ends at $size_bytes bytes)"
  else
    echo "  First pad sector:     $first_pad_sector (offset $first_pad_off bytes)"
  fi

  if [[ -n "$EXTRACT_OUT" ]]; then
    extract_up_to_boundary "$last_nonpad_sector" "$EXTRACT_OUT"
  fi
  if [[ -n "$EXTRACT_LAST_OUT" ]]; then
    extract_last_sector "$last_nonpad_sector" "$EXTRACT_LAST_OUT"
  fi
  if [[ -n "$EXTRACT_BOUNDARY_OUT" ]]; then
    extract_boundary_sectors "$last_nonpad_sector" "$first_pad_sector" "$EXTRACT_BOUNDARY_OUT"
  fi
}

# Scan from end using per-block reads.
scan_dd() {
  local i
  for ((i=START_BLOCK_EFF; i>=0; i--)); do
    progress_update "$i"
    if block_has_nonpad "$i"; then
      final_progress "$i"
      RESULT_FOUND=1
      LAST_BLOCK="$i"
      echo "${C_GREEN}Last non-pad block:${C_RESET} $i"
      echo "${C_YELLOW}Approx last real data offset (block start):${C_RESET} $((i*BS)) bytes"
      if [[ "$REFINE" -eq 1 || -n "$EXTRACT_OUT" || -n "$EXTRACT_LAST_OUT" || -n "$EXTRACT_BOUNDARY_OUT" ]]; then
        refine_boundary "$i"
      fi
      return 0
    fi
  done
  final_progress 0
  echo "No non-pad data found."
  return 1
}

# Scan from end using large chunks, then narrow inside the hit chunk.
scan_tail() {
  local chunk_blocks i start count
  chunk_blocks=$(( (CHUNK_MIB + BLOCK_MIB - 1) / BLOCK_MIB ))
  (( chunk_blocks < 1 )) && chunk_blocks=1

  for ((i=START_BLOCK_EFF; i>=0; i-=chunk_blocks)); do
    start=$(( i - chunk_blocks + 1 ))
    (( start < 0 )) && start=0
    count=$(( i - start + 1 ))
    progress_update_range "$start" "$i"
    CHUNK_BYTES_READ=$((CHUNK_BYTES_READ + count*BS))
    if dd if="$FILE" bs="$BS" skip="$start" count="$count" status=none \
      | tr -d "$TR_DELETE_SET" | wc -c | tr -d ' ' | grep -qv '^0$'; then
      for ((j=i; j>=start; j--)); do
        progress_update "$j"
        if block_has_nonpad "$j"; then
          final_progress "$j"
          RESULT_FOUND=1
          LAST_BLOCK="$j"
          echo "${C_GREEN}Last non-pad block:${C_RESET} $j"
          echo "${C_YELLOW}Approx last real data offset (block start):${C_RESET} $((j*BS)) bytes"
          if [[ "$REFINE" -eq 1 || -n "$EXTRACT_OUT" || -n "$EXTRACT_LAST_OUT" || -n "$EXTRACT_BOUNDARY_OUT" ]]; then
            refine_boundary "$j"
          fi
          return 0
        fi
      done
    fi
  done
  final_progress 0
  echo "No non-pad data found."
  return 1
}

# Scan from end using grep within chunks to find the last non-pad byte.
scan_grep() {
  local pattern last_off last_block abs_off
  local chunk_blocks i start count
  build_grep_pattern
  pattern="$GREP_PATTERN"

  chunk_blocks=$(( (CHUNK_MIB + BLOCK_MIB - 1) / BLOCK_MIB ))
  (( chunk_blocks < 1 )) && chunk_blocks=1

  for ((i=START_BLOCK_EFF; i>=0; i-=chunk_blocks)); do
    start=$(( i - chunk_blocks + 1 ))
    (( start < 0 )) && start=0
    count=$(( i - start + 1 ))
    progress_update_range "$start" "$i"
    CHUNK_BYTES_READ=$((CHUNK_BYTES_READ + count*BS))
    last_off="$(dd if="$FILE" bs="$BS" skip="$start" count="$count" status=none \
      | LC_ALL=C grep -aob -P "$pattern" | tail -n 1 | cut -d: -f1 || true)"
    if [[ -n "${last_off:-}" ]]; then
      abs_off=$((start*BS + last_off))
      last_block=$((abs_off / BS))
      final_progress "$last_block"
      RESULT_FOUND=1
      LAST_BLOCK="$last_block"
      echo "${C_GREEN}Last non-pad block:${C_RESET} $last_block"
      echo "${C_YELLOW}Approx last real data offset (block start):${C_RESET} $((last_block*BS)) bytes"
      if [[ "$REFINE" -eq 1 || -n "$EXTRACT_OUT" || -n "$EXTRACT_LAST_OUT" || -n "$EXTRACT_BOUNDARY_OUT" ]]; then
        refine_boundary "$last_block"
      fi
      return 0
    fi
  done
  final_progress 0
  echo "No non-pad data found."
  return 1
}

# Interpret and summarize results.
interpret_results() {
  echo
  echo "${C_BOLD}${C_BLUE}Summary:${C_RESET}"
  echo "  Method:             $METHOD"
  echo "  Blocks checked:     $BLOCK_CHECKS"
  echo "  Chunk checks:       $CHUNK_CHECKS"
  echo "  Refinements:        $REFINES"
  if [[ -n "${START_TIME:-}" && -n "${END_TIME:-}" ]]; then
    local elapsed=$((END_TIME - START_TIME))
    echo "  Elapsed time:       ${elapsed}s"
    local scan_bytes=$((BLOCK_BYTES_READ + CHUNK_BYTES_READ + REFINE_BYTES_READ))
    if (( elapsed > 0 )); then
      local mib_per_sec=$((scan_bytes / 1024 / 1024 / elapsed))
      echo "  Throughput:         ${mib_per_sec} MiB/s (scan)"
    else
      echo "  Throughput:         n/a (elapsed < 1s)"
    fi
  fi
  if [[ "$RESULT_FOUND" -eq 1 ]]; then
    echo "  Found data:         yes"
    echo "  Last non-pad block: $LAST_BLOCK"
    if [[ "$LAST_NONPAD_SECTOR" -ge 0 ]]; then
      echo "  Last non-pad sector:$LAST_NONPAD_SECTOR"
      echo "  Last data offset:   $((LAST_NONPAD_SECTOR * 512)) bytes"
      if [[ "$LAST_NONPAD_BYTE_OFF" -ge 0 ]]; then
        echo "  Last non-pad byte:  $LAST_NONPAD_BYTE_OFF"
      else
        echo "  Last non-pad byte:  unavailable (grep -P not supported)"
      fi
    else
      echo "  Last non-pad sector: unknown (no refine)"
    fi
  else
    echo "  Found data:         no"
  fi
  if [[ "$EXTRACTED_OUT" -eq 1 || "$EXTRACTED_LAST" -eq 1 || "$EXTRACTED_BOUNDARY" -eq 1 ]]; then
    echo "  Extraction:         wrote $EXTRACT_BYTES_WRITTEN bytes"
    if [[ "$EXTRACTED_OUT" -eq 1 ]]; then
      echo "    - extract-out:    yes"
    fi
    if [[ "$EXTRACTED_LAST" -eq 1 ]]; then
      echo "    - extract-last:   yes"
    fi
    if [[ "$EXTRACTED_BOUNDARY" -eq 1 ]]; then
      echo "    - extract-boundary: yes"
    fi
  fi
}

# Orchestration: parse args -> setup -> choose scan method.
main() {
  parse_args "$@"
  init_logging
  if [[ "$QUIET" -eq 0 ]]; then
    banner
    check_tools
  fi
  read_image_size
  resolve_start_block
  build_tr_delete_set
  START_TIME=$(date +%s)
  print_plan

  case "$METHOD" in
    dd) scan_dd ;;
    tail) scan_tail ;;
    grep) scan_grep ;;
    *) die "Unknown method: $METHOD" ;;
  esac

  END_TIME=$(date +%s)
  interpret_results
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
