#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# fakeflash_forensic_pro.sh  (READ-ONLY)
# Wrap/alias detection for potentially fake flash disk images.
# ============================================================

usage () {
  cat <<'USAGE'
Usage:
  Simple mode (choose a profile by size):
    fakeflash_forensic_pro.sh -p 8G image.dd
    fakeflash_forensic_pro.sh --profile 64G image.dd

  Advanced mode (override tunables):
    fakeflash_forensic_pro.sh -b 4 -S 3 -t 128 -c "1024 2048 3072 4096 5120 6144 7168" image.dd
    fakeflash_forensic_pro.sh --block-mib 8 --sample-gib 8 --tail-mib 256 --candidates "8192 16384 32768 40960 49152" image.dd

Options:
  -p, --profile SIZE     One of: 8G, 16G, 32G, 64G, 128G, 256G
  -b, --block-mib N       Block size in MiB (e.g., 4, 8, 16)
  -S, --sample-gib N      Sample size in GiB (hash first N GiB)
  -t, --tail-mib N        Tail window in MiB (compare last N MiB)
  -c, --candidates "..."  Candidate capacities in MiB (space-separated)
      --dump-duplicates   Dump first occurrence of each duplicate block to CWD
      --log FILE          Write full log to FILE (default: ./fakeflash_forensic_pro.log)
      --monochrome        Disable ANSI colors on console output
  -h, --help              Show help

Notes:
  - If no profile is given and no advanced flags are set, the script auto-picks
    the closest profile based on the image size.
  - Advanced flags override the selected profile.
USAGE
}

# Print error and exit.
die () {
  echo "$1" >&2
  exit 1
}

# Parse CLI arguments into globals used by the rest of the pipeline.
parse_args () {
  if [[ $# -lt 1 ]]; then
    usage
    exit 1
  fi

  profile=""
  block_mib_override=""
  sample_gib_override=""
  tail_mib_override=""
  candidates_override=""
  DUMP_DUP=0
  LOG_FILE=""
  MONOCHROME=0
  IMG=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -p|--profile)
        [[ $# -lt 2 ]] && die "Missing value for $1"
        profile="$2"; shift 2 ;;
      -b|--block-mib)
        [[ $# -lt 2 ]] && die "Missing value for $1"
        block_mib_override="$2"; shift 2 ;;
      -S|--sample-gib)
        [[ $# -lt 2 ]] && die "Missing value for $1"
        sample_gib_override="$2"; shift 2 ;;
      -t|--tail-mib)
        [[ $# -lt 2 ]] && die "Missing value for $1"
        tail_mib_override="$2"; shift 2 ;;
      -c|--candidates)
        [[ $# -lt 2 ]] && die "Missing value for $1"
        candidates_override="$2"; shift 2 ;;
      --dump-duplicates)
        DUMP_DUP=1; shift ;;
      --log)
        [[ $# -lt 2 ]] && die "Missing value for $1"
        LOG_FILE="$2"; shift 2 ;;
      --monochrome)
        MONOCHROME=1; shift ;;
      -h|--help)
        usage; exit 0 ;;
      -* )
        die "Unknown option: $1" ;;
      *)
        [[ -n "$IMG" ]] && die "Unexpected extra argument: $1"
        IMG="$1"; shift ;;
    esac
  done

  [[ -n "$IMG" ]] || die "Missing image.dd"
  [[ -f "$IMG" ]] || die "File not found: $IMG"
}

# Initialize ANSI colors and prefixed labels for output consistency.
init_colors () {
  if [[ "$MONOCHROME" -eq 1 ]]; then
    CLR_RESET=""; CLR_DIM=""; CLR_BOLD=""
    CLR_RED=""; CLR_YELLOW=""; CLR_GREEN=""; CLR_CYAN=""
  elif [[ -t 1 || -t 2 || -w /dev/tty ]]; then
    CLR_RESET=$'\033[0m'
    CLR_DIM=$'\033[2m'
    CLR_BOLD=$'\033[1m'
    CLR_RED=$'\033[31m'
    CLR_YELLOW=$'\033[33m'
    CLR_GREEN=$'\033[32m'
    CLR_CYAN=$'\033[36m'
  else
    CLR_RESET=""; CLR_DIM=""; CLR_BOLD=""
    CLR_RED=""; CLR_YELLOW=""; CLR_GREEN=""; CLR_CYAN=""
  fi

  P_INFO="${CLR_GREEN}[*]${CLR_RESET}"
  P_WARN="${CLR_YELLOW}[!]${CLR_RESET}"
  P_Q="${CLR_YELLOW}[?]${CLR_RESET}"
  P_ERR="${CLR_RED}[!]${CLR_RESET}"
  P_CHECK="${CLR_CYAN}[CHECK]${CLR_RESET}"
}

# Check required tools and report status before heavy operations.
check_tools () {
  local need_tools=(dd stat split sort uniq awk head xxd mktemp sed wc tr basename)
  local missing=()

  banner "Checking tools"

  for t in "${need_tools[@]}"; do
    if command -v "$t" >/dev/null 2>&1; then
      printf "%s %s ... %sok%s\n" "$P_CHECK" "$t" "$CLR_GREEN" "$CLR_RESET"
    else
      printf "%s %s ... %smissing%s\n" "$P_CHECK" "$t" "$CLR_RED" "$CLR_RESET"
      missing+=("$t")
    fi
  done

  if [[ "${#missing[@]}" -gt 0 ]]; then
    printf "%s Missing required tools:%s %s\n" "$P_ERR" "$CLR_RESET" "${missing[*]}"
    exit 1
  fi
}

# Route stdout/stderr to both console and log, stripping ANSI in the log.
init_logging () {
  if [[ -z "$LOG_FILE" ]]; then
    LOG_FILE="${PWD}/fakeflash_forensic_pro.log"
  fi
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"
  exec > >(tee >(sed -E $'s/\x1b\[[0-9;]*m//g' >> "$LOG_FILE")) 2>&1
}

# Read image size in bytes, with macOS stat fallback.
read_image_size () {
  size_bytes=$(stat -c%s "$IMG" 2>/dev/null || stat -f%z "$IMG")
}

# Auto-pick a profile if none provided and no advanced overrides are set.
auto_pick_profile () {
  if [[ -n "$profile" ]]; then
    return
  fi
  if [[ -n "$block_mib_override" || -n "$sample_gib_override" || -n "$tail_mib_override" || -n "$candidates_override" ]]; then
    return
  fi

  local size_gib best_profile best_diff diff cmp
  size_gib=$(awk -v b="$size_bytes" 'BEGIN{printf "%.3f", b/1024/1024/1024}')
  best_profile="8G"
  best_diff=$(awk -v s="$size_gib" 'BEGIN{d=s-8; if(d<0)d=-d; printf "%.3f", d}')
  for p in 16 32 64 128 256; do
    diff=$(awk -v s="$size_gib" -v p="$p" 'BEGIN{d=s-p; if(d<0)d=-d; printf "%.3f", d}')
    cmp=$(awk -v a="$diff" -v b="$best_diff" 'BEGIN{print (a<b)?1:0}')
    if [[ "$cmp" -eq 1 ]]; then
      best_diff="$diff"
      best_profile="${p}G"
    fi
  done
  profile="$best_profile"
}

# Apply profile defaults for block/sample/tail/candidates.
apply_profile_defaults () {
  if [[ -z "$profile" ]]; then
    return
  fi

  case "$profile" in
    8G|8g)
      BLOCK_MIB=4; SAMPLE_GIB=3; TAIL_MIB=128
      CANDIDATES_MIB=(1024 2048 3072 4096 5120 6144 7168)
      ;;
    16G|16g)
      BLOCK_MIB=4; SAMPLE_GIB=4; TAIL_MIB=128
      CANDIDATES_MIB=(2048 4096 6144 8192 10240 12288 14336)
      ;;
    32G|32g)
      BLOCK_MIB=8; SAMPLE_GIB=8; TAIL_MIB=256
      CANDIDATES_MIB=(4096 8192 12288 16384 20480 24576 28672)
      ;;
    64G|64g)
      BLOCK_MIB=8; SAMPLE_GIB=12; TAIL_MIB=256
      CANDIDATES_MIB=(8192 16384 32768 40960 49152)
      ;;
    128G|128g)
      BLOCK_MIB=16; SAMPLE_GIB=16; TAIL_MIB=512
      CANDIDATES_MIB=(16384 32768 49152 65536 81920 98304 114688)
      ;;
    256G|256g)
      BLOCK_MIB=16; SAMPLE_GIB=24; TAIL_MIB=512
      CANDIDATES_MIB=(32768 65536 98304 131072 163840 196608 229376)
      ;;
    *)
      die "Unknown profile: $profile" ;;
  esac
}

# Apply advanced overrides on top of profile defaults.
apply_overrides () {
  [[ -n "$block_mib_override" ]] && BLOCK_MIB="$block_mib_override"
  [[ -n "$sample_gib_override" ]] && SAMPLE_GIB="$sample_gib_override"
  [[ -n "$tail_mib_override" ]] && TAIL_MIB="$tail_mib_override"
  if [[ -n "$candidates_override" ]]; then
    read -r -a CANDIDATES_MIB <<< "$candidates_override"
  fi
}

# Validate the core tunables exist before compute-heavy steps.
validate_tunables () {
  if [[ -z "${BLOCK_MIB:-}" || -z "${SAMPLE_GIB:-}" || -z "${TAIL_MIB:-}" || -z "${CANDIDATES_MIB:-}" ]]; then
    die "Missing required tunables. Provide a profile or set -b -S -t -c."
  fi
}

# Compute block geometry, ranges, and window sizes.
compute_geometry () {
  BS=$((BLOCK_MIB*1024*1024))
  total_sectors=$((size_bytes/512))
  last_lba=$((total_sectors-1))
  total_blocks=$(( (size_bytes + BS - 1) / BS ))

  sample_blocks=$(( (SAMPLE_GIB*1024) / BLOCK_MIB ))
  tail_blocks=$(( TAIL_MIB / BLOCK_MIB ))
  (( sample_blocks > total_blocks )) && sample_blocks=$total_blocks
  (( tail_blocks > total_blocks )) && tail_blocks=$total_blocks

  tail_skip=$(( total_blocks - tail_blocks ))
}

# Select hash command and progress tool once.
init_tools_optional () {
  have_pv=0
  if command -v pv >/dev/null 2>&1; then
    have_pv=1
  fi

  hash_cmd="sha256sum"
  if command -v b3sum >/dev/null 2>&1; then
    hash_cmd="b3sum"
  fi
}

# Standard banner for phases.
banner () {
  echo
  echo "${CLR_CYAN}============================================================${CLR_RESET}"
  echo "${CLR_BOLD}$1${CLR_RESET}"
  echo "${CLR_CYAN}============================================================${CLR_RESET}"
}

# Format bytes as MiB (used for info printing only).
human () {
  awk -v b="$1" 'BEGIN{printf "%.1f MiB", b/1024/1024}'
}

# Sequential read of a block window and split into fixed-size chunk files.
read_and_split () {
  local label="$1" skip="$2" count="$3" prefix="$4"
  local bytes=$((count*BS))
  printf "%s %s: reading %s  (skip=%s blocks, count=%s blocks)\n" "$P_INFO" "$label" "$(human "$bytes")" "$skip" "$count"

  if [[ $have_pv -eq 1 ]]; then
    dd if="$IMG" bs="$BS" skip="$skip" count="$count" status=none \
      | pv -ptebar -s "$bytes" \
      | split -b "$BS" -d -a 6 - "$tmpdir/${prefix}_"
  else
    dd if="$IMG" bs="$BS" skip="$skip" count="$count" status=progress \
      | split -b "$BS" -d -a 6 - "$tmpdir/${prefix}_"
  fi
}

# Hash all chunk files, emit one hash per line, with tty-only progress.
hash_chunks () {
  local prefix="$1" out="$2"
  local files n i f

  mapfile -t files < <(ls -1 "$tmpdir/${prefix}_"* 2>/dev/null | sort)
  n="${#files[@]}"
  : > "$out"
  if [[ $n -eq 0 ]]; then
    echo "    [!] No chunks found for prefix $prefix"
    return 1
  fi

  printf "%s Hashing %s chunks (%s) with %s ...\n" "$P_INFO" "$n" "$prefix" "$hash_cmd"
  i=0
  for f in "${files[@]}"; do
    i=$((i+1))
    if [[ -w /dev/tty ]]; then
      printf "\r    hashing: %d/%d" "$i" "$n" > /dev/tty 2>/dev/null || true
    fi
    $hash_cmd "$f" | awk '{print $1}' >> "$out"
  done
  printf "    hashing: %d/%d  (done)\n" "$n" "$n"
}

# Show a colored hexdump of the tail block (colorized by byte class).
show_tail_hexdump () {
  banner "PHASE 0 — Tail heuristic (not proof)"
  printf "%s Showing first ~256 bytes of the LAST 1MiB (quick look for FF/00 padding):\n" "$P_INFO"

  local last_1m_skip
  last_1m_skip=$(( (size_bytes - 1048576) / 1 ))
  dd if="$IMG" bs=1 skip="$last_1m_skip" count=256 status=none | xxd -g 1 -c 16 \
    | awk -v red="$CLR_RED" -v yel="$CLR_YELLOW" -v grn="$CLR_GREEN" -v rst="$CLR_RESET" '
      function hex2dec(h,  i, c, n, v) {
        n = 0
        for (i=1; i<=length(h); i++) {
          c = toupper(substr(h, i, 1))
          v = index("0123456789ABCDEF", c) - 1
          if (v < 0) return -1
          n = n*16 + v
        }
        return n
      }
      {
        out=$1
        for (i=2; i<=17; i++) {
          b=$i
          if (b=="00" || b=="ff" || b=="FF") b=red b rst
          else {
            dec = hex2dec(b)
            if (dec >= 32 && dec <= 126) b=grn b rst
            else b=yel b rst
          }
          out=out " " b
        }
        if (NF>17) {
          asc = $18
          asc_out = ""
          for (i=1; i<=length(asc) && i<=16; i++) {
            ch = substr(asc, i, 1)
            b = $(i+1)
            if (b=="00" || b=="ff" || b=="FF") asc_out = asc_out red ch rst
            else if (ch == ".") asc_out = asc_out yel ch rst
            else asc_out = asc_out grn ch rst
          }
          out=out "  " asc_out
        }
        print out
      }'

  echo "    Note: lots of FF or 00 is suspicious, but can be normal padding."
  echo
}

# Hash sample region and report duplicate blocks with optional dumps.
sample_hash_and_report () {
  banner "PHASE 1 — Sample hashing (duplicate block detection)"
  read_and_split "Sample region" 0 "$sample_blocks" "samp"
  hash_chunks "samp" "$tmpdir/sample_hashes.txt"

  awk '{print NR-1, $1}' "$tmpdir/sample_hashes.txt" > "$tmpdir/sample_indexed.txt"
  dup_count=$(awk '{print $2}' "$tmpdir/sample_indexed.txt" | sort | uniq -d | wc -l | tr -d ' ')

  if [[ "$dup_count" -eq 0 ]]; then
    printf "%s No duplicate %sMiB-block hashes in the sampled region.\n" "$P_INFO" "$BLOCK_MIB"
    return
  fi

  printf "%s Found %s duplicate %sMiB-block hash(es) in the sampled region (suspicious).\n" "$P_WARN" "$dup_count" "$BLOCK_MIB"
  echo "    Showing up to 5 duplicate hashes (duplicates usually mean repeated blocks):"
  awk '{print $2}' "$tmpdir/sample_indexed.txt" | sort | uniq -d | head -n 5 | sed 's/^/    /'

  echo
  echo "    Duplicate block locations (sample region, block index -> byte offset):"
  mapfile -t dup_hashes < <(awk '{print $2}' "$tmpdir/sample_indexed.txt" | sort | uniq -d | head -n 5)

  local h idxs idx byte_off mib_off first_idx out_block img_base
  for h in "${dup_hashes[@]}"; do
    echo "    Hash: $h"
    mapfile -t idxs < <(awk -v h="$h" '$2==h {print $1}' "$tmpdir/sample_indexed.txt")
    for idx in "${idxs[@]}"; do
      byte_off=$((idx*BS))
      mib_off=$((idx*BLOCK_MIB))
      printf "      block=%s  offset=%s bytes  (~%s MiB)\n" "$idx" "$byte_off" "$mib_off"
    done
    if [[ "$DUMP_DUP" -eq 1 ]]; then
      first_idx="${idxs[0]}"
      img_base="$(basename "$IMG")"
      out_block="${PWD}/dup_${img_base}_hash_${h}_block${first_idx}.bin"
      dd if="$IMG" bs="$BS" skip="$first_idx" count=1 status=none of="$out_block"
      echo "      dumped first block to: $out_block"
    fi
  done
}

# Hash the tail window into an array for comparison.
hash_tail_window () {
  banner "PHASE 2 — Tail window hashing"
  read_and_split "Tail window" "$tail_skip" "$tail_blocks" "tail"
  hash_chunks "tail" "$tmpdir/tail_hashes.txt"
  mapfile -t tail_arr < "$tmpdir/tail_hashes.txt"
}

# Compare tail hashes against candidate earlier windows to detect wrap.
compare_candidates () {
  banner "PHASE 3 — Tail-alias comparison vs candidate real capacities"
  echo "${P_INFO} For each candidate size, compare:"
  echo "    last ${TAIL_MIB}MiB  vs  region that is candidate_size earlier"
  echo "    (High match rate strongly suggests wrap/modulo aliasing.)"
  echo

  best_hits=0
  best_cand=0

  local cand off_blocks comp_skip prefix hits i
  for cand in "${CANDIDATES_MIB[@]}"; do
    off_blocks=$(( cand / BLOCK_MIB ))
    if (( off_blocks <= 0 )); then
      continue
    fi
    if (( off_blocks >= total_blocks )); then
      continue
    fi
    if (( tail_skip - off_blocks < 0 )); then
      continue
    fi

    comp_skip=$(( tail_skip - off_blocks ))
    prefix="cmp_${cand}"

    echo "${P_INFO} Candidate ${cand} MiB: comparing tail vs skip=$comp_skip blocks (offset=$off_blocks blocks)"
    read_and_split "  Compare window (${cand}MiB)" "$comp_skip" "$tail_blocks" "$prefix"
    hash_chunks "$prefix" "$tmpdir/${prefix}_hashes.txt"
    mapfile -t comp_arr < "$tmpdir/${prefix}_hashes.txt"

    hits=0
    for ((i=0; i<tail_blocks; i++)); do
      [[ "${tail_arr[$i]}" == "${comp_arr[$i]}" ]] && hits=$((hits+1))
    done

    printf "    Result: %2d/%2d matches (%.1f%%)\n" "$hits" "$tail_blocks" "$(awk -v h="$hits" -v t="$tail_blocks" 'BEGIN{print (t? (100*h/t):0)}')"

    if (( hits > best_hits )); then
      best_hits=$hits
      best_cand=$cand
    fi

    rm -f "$tmpdir/${prefix}_"* || true
  done
}

# Interpret comparison results and emit next-step hints.
interpret_results () {
  banner "INTERPRETATION"
  local half=$(( (tail_blocks+1)/2 ))

  if (( best_hits >= half )); then
    printf "%s STRONG wrap/alias signal.\n" "$P_ERR"
    echo "    Best candidate ≈ ${best_cand} MiB with ${best_hits}/${tail_blocks} matches."
    echo "    This is consistent with fake capacity / modulo mapping."
    echo
    echo "What to do next (still read-only):"
    echo "  - Re-run with TAIL_MIB=512 for higher confidence (if time allows)."
    echo "  - If matches are high, the real NAND size is often near the best candidate."
  elif (( best_hits > 0 )); then
    printf "%s Weak/ambiguous signal.\n" "$P_Q"
    echo "    Best candidate ≈ ${best_cand} MiB with ${best_hits}/${tail_blocks} matches."
    echo "    This can happen with padding (all-00/all-FF) or repeated metadata."
    echo
    echo "Try:"
    echo "  - Increase BLOCK_MIB to 16 (reduces false matches on uniform data)"
    echo "  - Increase TAIL_MIB to 512 (more samples)"
    echo "  - Also inspect whether tail blocks are mostly identical (padding)."
  else
    printf "%s No tail-alias matches for the tested candidates.\n" "$P_INFO"
    echo "    This does NOT prove genuine, but it did not detect the common wrap pattern."
    echo
    echo "Try if still suspicious:"
    echo "  - Add more candidates (e.g., 6144MiB, 12288MiB, 24576MiB)"
    echo "  - Increase SAMPLE_GIB to 16 if your disk is fast enough"
  fi

  echo
  echo "${P_INFO} Done."
  echo "    Temporary files were stored in: $tmpdir (auto-cleaned on exit)"
}

# Print a run summary once all parameters are resolved.
print_summary () {

  banner "Image and workflow information"
  echo "${P_INFO} Image:        $IMG"
  echo "${P_INFO} Size:         $((size_bytes/1024/1024)) MiB  ($size_bytes bytes)"
  echo "${P_INFO} Profile:      ${profile:-custom}"
  echo "${P_INFO} Sectors:      $total_sectors  (last LBA: $last_lba)"
  echo "${P_INFO} Block size:   ${BLOCK_MIB} MiB  (BS=$BS bytes)"
  echo "${P_INFO} Total blocks: $total_blocks"
  echo "${P_INFO} Sample:       first ${SAMPLE_GIB} GiB  -> ${sample_blocks} blocks (~$((sample_blocks*BLOCK_MIB)) MiB)"
  echo "${P_INFO} Tail window:  last ${TAIL_MIB} MiB -> ${tail_blocks} blocks"
  echo "${P_INFO} Candidates:   ${CANDIDATES_MIB[*]} MiB"
  echo "${P_INFO} Progress:     $([[ $have_pv -eq 1 ]] && echo "pv" || echo "dd status=progress (if supported)")"
  echo "${P_INFO} Hash:         $hash_cmd"
  echo
}

# Main orchestrator tying all steps together in a read-only workflow.
main () {
  parse_args "$@"
  init_colors
  init_logging
  check_tools

  read_image_size
  auto_pick_profile
  apply_profile_defaults
  apply_overrides
  validate_tunables
  compute_geometry
  init_tools_optional

  tmpdir="$(mktemp -d)"
  cleanup() { rm -rf "$tmpdir"; }
  trap cleanup EXIT

  print_summary
  show_tail_hexdump
  sample_hash_and_report
  hash_tail_window
  compare_candidates
  interpret_results
}

main "$@"
