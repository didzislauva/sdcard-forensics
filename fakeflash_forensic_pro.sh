#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# fakeflash_forensic_pro.sh  (READ-ONLY)
# Wrap/alias detection for potentially fake flash disk images.
#
# Usage:
#   ./fakeflash_forensic_pro.sh image.dd
#
# Tuned defaults for 64GB image + ~10min target:
#   - block size 8MiB
#   - hash first 12GiB (sample)
#   - analyze last 256MiB (tail window)
#   - compare tail window to earlier windows for candidate real sizes
#
# Requirements:
#   dd, stat, split, sort, uniq, awk, head
# Optional:
#   pv (best progress), b3sum (faster hashing than sha256)
# ============================================================

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <image.dd>"
  exit 1
fi

IMG="$1"
[[ -f "$IMG" ]] || { echo "File not found: $IMG"; exit 1; }

# -----------------------------
# PERF TUNABLES (64GB, ~10min)
# -----------------------------
BLOCK_MIB=8            # 8MiB blocks (coarser = fewer hashes; good trade-off)
SAMPLE_GIB=12          # hash first 12GiB
TAIL_MIB=256           # analyze last 256MiB
CANDIDATES_MIB=(8192 16384 32768 40960 49152)   # 8/16/32/40/48 GiB candidates

# If your machine/storage is slow, reduce:
#   SAMPLE_GIB=8
#   TAIL_MIB=128
# or increase BLOCK_MIB=16

BS=$((BLOCK_MIB*1024*1024))  # bytes

# macOS stat fallback
size_bytes=$(stat -c%s "$IMG" 2>/dev/null || stat -f%z "$IMG")
total_sectors=$((size_bytes/512))
last_lba=$((total_sectors-1))
total_blocks=$(( (size_bytes + BS - 1) / BS ))

sample_blocks=$(( (SAMPLE_GIB*1024) / BLOCK_MIB ))
tail_blocks=$(( TAIL_MIB / BLOCK_MIB ))
(( sample_blocks > total_blocks )) && sample_blocks=$total_blocks
(( tail_blocks > total_blocks )) && tail_blocks=$total_blocks

tail_skip=$(( total_blocks - tail_blocks ))

have_pv=0
command -v pv >/dev/null 2>&1 && have_pv=1

hash_cmd="sha256sum"
command -v b3sum >/dev/null 2>&1 && hash_cmd="b3sum"

tmpdir="$(mktemp -d)"
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT

banner () {
  echo
  echo "============================================================"
  echo "$1"
  echo "============================================================"
}

human () { # bytes -> human-ish MiB
  awk -v b="$1" 'BEGIN{printf "%.1f MiB", b/1024/1024}'
}

echo "[*] Image:        $IMG"
echo "[*] Size:         $((size_bytes/1024/1024)) MiB  ($size_bytes bytes)"
echo "[*] Sectors:      $total_sectors  (last LBA: $last_lba)"
echo "[*] Block size:   ${BLOCK_MIB} MiB  (BS=$BS bytes)"
echo "[*] Total blocks: $total_blocks"
echo "[*] Sample:       first ${SAMPLE_GIB} GiB  -> ${sample_blocks} blocks (~$((sample_blocks*BLOCK_MIB)) MiB)"
echo "[*] Tail window:  last ${TAIL_MIB} MiB -> ${tail_blocks} blocks"
echo "[*] Candidates:   ${CANDIDATES_MIB[*]} MiB"
echo "[*] Progress:     $([[ $have_pv -eq 1 ]] && echo "pv" || echo "dd status=progress (if supported)")"
echo "[*] Hash:         $hash_cmd"
echo

# Read helper: sequential read window and split into fixed-size chunk files.
# Args: label, skip_blocks, count_blocks, out_prefix
read_and_split () {
  local label="$1"
  local skip="$2"
  local count="$3"
  local prefix="$4"

  local bytes=$((count*BS))
  echo "[*] $label: reading $(human "$bytes")  (skip=$skip blocks, count=$count blocks)"

  if [[ $have_pv -eq 1 ]]; then
    # dd reads sequentially; pv shows progress
    dd if="$IMG" bs="$BS" skip="$skip" count="$count" status=none \
      | pv -ptebar -s "$bytes" \
      | split -b "$BS" -d -a 6 - "$tmpdir/${prefix}_"
  else
    # GNU dd can show progress. If unsupported, dd may ignore it.
    dd if="$IMG" bs="$BS" skip="$skip" count="$count" status=progress \
      | split -b "$BS" -d -a 6 - "$tmpdir/${prefix}_"
  fi
}

# Hash helper: hash chunk files and write one hash per line in order.
# Args: prefix, out_file
hash_chunks () {
  local prefix="$1"
  local out="$2"

  local files
  mapfile -t files < <(ls -1 "$tmpdir/${prefix}_"* 2>/dev/null | sort)

  local n="${#files[@]}"
  : > "$out"
  if [[ $n -eq 0 ]]; then
    echo "    [!] No chunks found for prefix $prefix"
    return 1
  fi

  echo "[*] Hashing $n chunks ($prefix) with $hash_cmd ..."
  local i=0
  for f in "${files[@]}"; do
    i=$((i+1))
    # print live status every chunk
    printf "\r    hashing: %d/%d" "$i" "$n" >&2
    $hash_cmd "$f" | awk '{print $1}' >> "$out"
  done
  printf "\r    hashing: %d/%d  (done)\n" "$n" "$n" >&2
}

banner "PHASE 0 — Tail heuristic (not proof)"
echo "[*] Showing first ~256 bytes of the LAST 1MiB (quick look for FF/00 padding):"
# Read last 1MiB, show first 256 bytes of it
last_1m_skip=$(( (size_bytes - 1048576) / 1 ))
dd if="$IMG" bs=1 skip="$last_1m_skip" count=256 status=none | xxd -g 1
echo "    Note: lots of FF or 00 is suspicious, but can be normal padding."
echo

banner "PHASE 1 — Sample hashing (duplicate block detection)"
read_and_split "Sample region" 0 "$sample_blocks" "samp"
hash_chunks "samp" "$tmpdir/sample_hashes.txt"

dup_count=$(sort "$tmpdir/sample_hashes.txt" | uniq -d | wc -l | tr -d ' ')
if [[ "$dup_count" -eq 0 ]]; then
  echo "[*] No duplicate ${BLOCK_MIB}MiB-block hashes in the sampled region."
else
  echo "[!] Found $dup_count duplicate ${BLOCK_MIB}MiB-block hash(es) in the sampled region (suspicious)."
  echo "    Showing up to 5 duplicate hashes (duplicates usually mean repeated blocks):"
  sort "$tmpdir/sample_hashes.txt" | uniq -d | head -n 5 | sed 's/^/    /'
fi

banner "PHASE 2 — Tail window hashing"
read_and_split "Tail window" "$tail_skip" "$tail_blocks" "tail"
hash_chunks "tail" "$tmpdir/tail_hashes.txt"
mapfile -t tail_arr < "$tmpdir/tail_hashes.txt"

banner "PHASE 3 — Tail-alias comparison vs candidate real capacities"
echo "[*] For each candidate size, compare:"
echo "    last ${TAIL_MIB}MiB  vs  region that is candidate_size earlier"
echo "    (High match rate strongly suggests wrap/modulo aliasing.)"
echo

best_hits=0
best_cand=0

for cand in "${CANDIDATES_MIB[@]}"; do
  off_blocks=$(( cand / BLOCK_MIB ))
  if (( off_blocks <= 0 )); then
    continue
  fi
  if (( off_blocks >= total_blocks )); then
    continue
  fi
  if (( tail_skip - off_blocks < 0 )); then
    # Would underflow; can't compare this candidate for this image size.
    continue
  fi

  comp_skip=$(( tail_skip - off_blocks ))
  prefix="cmp_${cand}"

  echo "[*] Candidate ${cand} MiB: comparing tail vs skip=$comp_skip blocks (offset=$off_blocks blocks)"
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

  # Cleanup compare chunks for this candidate to save disk space
  rm -f "$tmpdir/${prefix}_"* || true
done

banner "INTERPRETATION"
half=$(( (tail_blocks+1)/2 ))

if (( best_hits >= half )); then
  echo "[!] STRONG wrap/alias signal."
  echo "    Best candidate ≈ ${best_cand} MiB with ${best_hits}/${tail_blocks} matches."
  echo "    This is consistent with fake capacity / modulo mapping."
  echo
  echo "What to do next (still read-only):"
  echo "  - Re-run with TAIL_MIB=512 for higher confidence (if time allows)."
  echo "  - If matches are high, the real NAND size is often near the best candidate."
elif (( best_hits > 0 )); then
  echo "[?] Weak/ambiguous signal."
  echo "    Best candidate ≈ ${best_cand} MiB with ${best_hits}/${tail_blocks} matches."
  echo "    This can happen with padding (all-00/all-FF) or repeated metadata."
  echo
  echo "Try:"
  echo "  - Increase BLOCK_MIB to 16 (reduces false matches on uniform data)"
  echo "  - Increase TAIL_MIB to 512 (more samples)"
  echo "  - Also inspect whether tail blocks are mostly identical (padding)."
else
  echo "[*] No tail-alias matches for the tested candidates."
  echo "    This does NOT prove genuine, but it did not detect the common wrap pattern."
  echo
  echo "Try if still suspicious:"
  echo "  - Add more candidates (e.g., 6144MiB, 12288MiB, 24576MiB)"
  echo "  - Increase SAMPLE_GIB to 16 if your disk is fast enough"
fi

echo
echo "[*] Done."
echo "    Temporary files were stored in: $tmpdir (auto-cleaned on exit)"

