#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  image_generator.sh -o OUTFILE [options]

Modes:
  --mode empty|full|partial|weird|range

Size profiles (GiB):
  --profile 1g|2g|4g|8g|16g|32g
  --fake-gib N            Explicit fake size in GiB (overrides profile)

Partial mode sizing:
  --data-gib N            Real data size at start (GiB)
  --data-mib N            Real data size at start (MiB)
  --data-percent P        Real data size as % of fake size

Weird mode:
  --percent P             Last real sector position within first half (0-100)
  --fill-before N         Fill N sectors before last sector (default: 0)
  --partial-bytes N       Fixed bytes in last sector (1-255); otherwise random

Range mode:
  --fill-range SPEC       Sector ranges to fill, e.g. 23423-23555,30000,40000:40010

Data / padding:
  --pad ff|00             Pad byte (default: ff)
  --data random|pattern|seeded
  --seed N                Seed for deterministic data and partial bytes

Other:
  -o, --output FILE       Output image file (required)
  -h, --help              Show help

Notes:
  - GiB is used throughout (1 GiB = 1024^3 bytes).
  - Weird mode: fake size is set, real region is in the first half only.
  - Results are for testing only; large images can take time to generate.

Examples:
  # 2GiB fake, weird mode, last sector at end of first half (default), pad FF
  image_generator.sh -o fake2g.dd --mode weird --profile 2g

  # 2GiB fake, weird mode, last sector at 35% of first half, pad 00
  image_generator.sh -o fake2g_35.dd --mode weird --fake-gib 2 --percent 35 --pad 00

  # Partial image: 8GiB fake, first 3GiB real data, pad FF
  image_generator.sh -o partial8g.dd --mode partial --fake-gib 8 --data-gib 3

  # Full random data, 1GiB
  image_generator.sh -o full1g.dd --mode full --profile 1g --data random

  # Fill specific sector ranges
  image_generator.sh -o range2g.dd --mode range --fake-gib 2 --fill-range 23423-23555,30000,40000:40010
USAGE
}

die() { echo "ERROR: $1" >&2; exit 1; }

# -----------------------------
# Defaults and CLI parsing
# -----------------------------
init_defaults() {
  MODE="partial"
  PROFILE=""
  FAKE_GIB=""
  DATA_GIB=""
  DATA_MIB=""
  DATA_PERCENT=""
  PERCENT=100
  FILL_BEFORE=0
  PARTIAL_BYTES=""
  FILL_RANGE=""
  PAD="ff"
  DATA_MODE="random"
  SEED=""
  OUT=""
}

parse_args() {
  if [[ $# -eq 0 ]]; then
    usage
    exit 0
  fi
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode) MODE="$2"; shift 2 ;;
      --profile) PROFILE="$2"; shift 2 ;;
      --fake-gib) FAKE_GIB="$2"; shift 2 ;;
      --data-gib) DATA_GIB="$2"; shift 2 ;;
      --data-mib) DATA_MIB="$2"; shift 2 ;;
      --data-percent) DATA_PERCENT="$2"; shift 2 ;;
      --percent) PERCENT="$2"; shift 2 ;;
      --fill-before) FILL_BEFORE="$2"; shift 2 ;;
      --partial-bytes) PARTIAL_BYTES="$2"; shift 2 ;;
      --fill-range) FILL_RANGE="$2"; shift 2 ;;
      --pad) PAD="$2"; shift 2 ;;
      --data) DATA_MODE="$2"; shift 2 ;;
      --seed) SEED="$2"; shift 2 ;;
      -o|--output) OUT="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown argument: $1" ;;
    esac
  done
}

validate_args() {
  [[ -n "$OUT" ]] || die "Missing -o/--output"
  command -v python3 >/dev/null 2>&1 || die "python3 is required"

  case "$MODE" in
    empty|full|partial|weird|range) : ;;
    *) die "Unknown mode: $MODE" ;;
  esac

  case "$PAD" in
    ff|00) : ;;
    *) die "--pad must be ff or 00" ;;
  esac

  case "$DATA_MODE" in
    random|pattern|seeded) : ;;
    *) die "--data must be random|pattern|seeded" ;;
  esac
}

# -----------------------------
# Size resolution
# -----------------------------
apply_profile() {
  [[ -z "$PROFILE" ]] && return
  case "${PROFILE,,}" in
    1g) FAKE_GIB=1 ;;
    2g) FAKE_GIB=2 ;;
    4g) FAKE_GIB=4 ;;
    8g) FAKE_GIB=8 ;;
    16g) FAKE_GIB=16 ;;
    32g) FAKE_GIB=32 ;;
    *) die "Unknown profile: $PROFILE" ;;
  esac
}

calc_fake_bytes() {
  [[ -n "$FAKE_GIB" ]] || die "Missing fake size (use --fake-gib or --profile)"
  FAKE_BYTES=$(python3 - <<PY
print(int(float("$FAKE_GIB") * 1024 * 1024 * 1024))
PY
)
}

# -----------------------------
# Output helpers
# -----------------------------
write_pad() {
  local bytes="$1" pad="$2" out="$3"
  python3 - <<PY
pad = bytes.fromhex("$pad")
size = int("$bytes")
chunk = pad * 1048576
with open("$out", "wb") as f:
    remaining = size
    while remaining > 0:
        n = min(remaining, len(chunk))
        f.write(chunk[:n])
        remaining -= n
PY
}

write_data_bytes() {
  local bytes="$1" out="$2" offset="$3"
  local bs=1048576
  local full_mib=$((bytes / bs))
  local rem=$((bytes % bs))
  local off_rem=$((offset % bs))

  # Fast path: random without seed via /dev/urandom
  if [[ "$DATA_MODE" == "random" && -z "$SEED" && "$off_rem" -eq 0 ]]; then
    if (( full_mib > 0 )); then
      dd if=/dev/urandom of="$out" bs=$bs seek=$((offset/bs)) count=$full_mib conv=notrunc status=none
    fi
    if (( rem > 0 )); then
      dd if=/dev/urandom of="$out" bs=1 seek=$((offset + full_mib*bs)) count=$rem conv=notrunc status=none
    fi
    return
  fi

  python3 - <<PY
import os, random
size = int("$bytes")
mode = "$DATA_MODE"
seed = "$SEED"
if mode == "seeded":
    rnd = random.Random(int(seed) if seed else 0)
    data = bytearray(size)
    for i in range(size):
        data[i] = rnd.randrange(0, 256)
elif mode == "pattern":
    pat = bytes([0xAA, 0x55])
    data = (pat * (size//2 + 1))[:size]
else:
    if seed:
        rnd = random.Random(int(seed))
        data = bytearray(size)
        for i in range(size):
            data[i] = rnd.randrange(0, 256)
    else:
        data = os.urandom(size)

with open("$out", "r+b") as f:
    f.seek(int("$offset"))
    f.write(data)
PY
}

write_partial_sector() {
  local sector_index="$1" out="$2" pad="$3"
  python3 - <<PY
import os, random
pad = bytes.fromhex("$pad")
seed = "$SEED"
if "$PARTIAL_BYTES":
    n = int("$PARTIAL_BYTES")
else:
    rnd = random.Random(int(seed) if seed else None)
    n = rnd.randrange(1, 256)

data_mode = "$DATA_MODE"
if data_mode == "seeded":
    rnd = random.Random(int(seed) if seed else 0)
    real = bytes(rnd.randrange(0,256) for _ in range(n))
elif data_mode == "pattern":
    pat = bytes([0xAA, 0x55])
    real = (pat * (n//2 + 1))[:n]
else:
    real = os.urandom(n)

buf = real + (pad * (512 - n))
with open("$out", "r+b") as f:
    f.seek(int("$sector_index") * 512)
    f.write(buf)
PY
}

# -----------------------------
# Mode implementations
# -----------------------------
run_empty() {
  :
}

run_full() {
  echo "Writing full data"
  write_data_bytes "$FAKE_BYTES" "$OUT" 0
}

resolve_partial_bytes() {
  if [[ -n "$DATA_GIB" ]]; then
    DATA_BYTES=$(python3 - <<PY
print(int(float("$DATA_GIB") * 1024 * 1024 * 1024))
PY
)
  elif [[ -n "$DATA_MIB" ]]; then
    DATA_BYTES=$(python3 - <<PY
print(int(float("$DATA_MIB") * 1024 * 1024))
PY
)
  elif [[ -n "$DATA_PERCENT" ]]; then
    DATA_BYTES=$(python3 - <<PY
print(int($FAKE_BYTES * (float("$DATA_PERCENT") / 100.0)))
PY
)
  else
    die "partial mode requires --data-gib, --data-mib, or --data-percent"
  fi

  if (( DATA_BYTES > FAKE_BYTES )); then
    DATA_BYTES=$FAKE_BYTES
  fi
}

run_partial() {
  resolve_partial_bytes
  echo "Writing partial data: $DATA_BYTES bytes"
  write_data_bytes "$DATA_BYTES" "$OUT" 0
}

calc_weird_last_sector() {
  HALF_BYTES=$((FAKE_BYTES / 2))
  LAST_SECTOR_INDEX=$(( (HALF_BYTES * PERCENT / 100) / 512 ))
  if (( LAST_SECTOR_INDEX < 0 )); then LAST_SECTOR_INDEX=0; fi
}

run_weird_fill_before() {
  if (( FILL_BEFORE <= 0 )); then
    return
  fi

  START_SECTOR=$((LAST_SECTOR_INDEX - FILL_BEFORE + 1))
  if (( START_SECTOR < 0 )); then START_SECTOR=0; fi
  SECTORS_TO_FILL=$((LAST_SECTOR_INDEX - START_SECTOR + 1))

  echo "Filling $SECTORS_TO_FILL sector(s) before last sector"
  BYTES_TO_FILL=$((SECTORS_TO_FILL * 512))
  write_data_bytes "$BYTES_TO_FILL" "$OUT" $((START_SECTOR * 512))
}

run_weird() {
  calc_weird_last_sector
  echo "Weird mode: fake=${FAKE_GIB}GiB, real=half, last_sector=$LAST_SECTOR_INDEX (percent=$PERCENT)"
  run_weird_fill_before
  write_partial_sector "$LAST_SECTOR_INDEX" "$OUT" "$PAD"
}

# -----------------------------
# Range mode
# -----------------------------
parse_fill_ranges() {
  [[ -n "$FILL_RANGE" ]] || die "range mode requires --fill-range"
  IFS=',' read -r -a RANGE_PARTS <<< "$FILL_RANGE"
  RANGE_LIST=()
  for part in "${RANGE_PARTS[@]}"; do
    if [[ "$part" =~ ^[0-9]+$ ]]; then
      RANGE_LIST+=("$part:$part")
    elif [[ "$part" =~ ^[0-9]+[-:][0-9]+$ ]]; then
      RANGE_LIST+=("${part/-/:}")
    else
      die "Invalid range spec: $part"
    fi
  done
}

run_range() {
  parse_fill_ranges
  local max_sector=$((FAKE_BYTES / 512 - 1))
  local last=-1
  for r in "${RANGE_LIST[@]}"; do
    local start=${r%%:*}
    local end=${r##*:}
    if (( start > end )); then
      local tmp=$start; start=$end; end=$tmp
    fi
    if (( start < 0 )); then start=0; fi
    if (( end > max_sector )); then end=$max_sector; fi
    if (( end < 0 )); then continue; fi
    local count=$((end - start + 1))
    echo "Filling sectors $start..$end ($count sectors)"
    write_data_bytes $((count * 512)) "$OUT" $((start * 512))
    if (( end > last )); then last=$end; fi
  done
  RANGE_LAST="$last"
}
# -----------------------------
# Summary
# -----------------------------
calc_last_data_sector() {
  if [[ "$MODE" == "weird" ]]; then
    LAST_DATA_SECTOR=$LAST_SECTOR_INDEX
  elif [[ "$MODE" == "partial" ]]; then
    LAST_DATA_SECTOR=$(( (DATA_BYTES + 511) / 512 - 1 ))
  elif [[ "$MODE" == "full" ]]; then
    LAST_DATA_SECTOR=$(( (FAKE_BYTES + 511) / 512 - 1 ))
  elif [[ "$MODE" == "range" ]]; then
    LAST_DATA_SECTOR=${RANGE_LAST:-"-1"}
  else
    LAST_DATA_SECTOR="-1"
  fi
}

print_summary() {
  if [[ -n "$LAST_DATA_SECTOR" && "$LAST_DATA_SECTOR" != "-1" ]]; then
    echo "Expected last data sector: $LAST_DATA_SECTOR (offset $((LAST_DATA_SECTOR * 512)) bytes)"
  else
    echo "Expected last data sector: none"
  fi
  echo "Done."
}

# -----------------------------
# Main
# -----------------------------
main() {
  init_defaults
  parse_args "$@"
  validate_args
  apply_profile
  calc_fake_bytes

  echo "Creating $OUT (${FAKE_GIB} GiB), pad=$PAD"
  write_pad "$FAKE_BYTES" "$PAD" "$OUT"

  case "$MODE" in
    empty) run_empty ;;
    full) run_full ;;
    partial) run_partial ;;
    weird) run_weird ;;
    range) run_range ;;
  esac

  calc_last_data_sector
  print_summary
}

main "$@"
