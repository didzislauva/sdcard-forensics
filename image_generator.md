# image_generator.sh

## Purpose
`image_generator.sh` creates **synthetic raw images** for testing forensic workflows. It can generate empty, full, partial, weird‑boundary, and range‑filled images with **known boundaries** and predictable padding. The goal is to stress‑test detection tools like `boundary_scanner.sh` and `fakeflash_forensic_pro.sh` under controlled conditions.

All sizes are **GiB** (1 GiB = 1024^3 bytes). The tool never reads source media — it only writes new test files.

---

## Key Use Cases
- Verify last‑data boundary detection
- Validate pad detection (`ff` vs `00`)
- Create “fake size” images with data ending early
- Generate tricky off‑by‑one or odd‑boundary scenarios
- Fill isolated sector ranges for targeted scanning tests

---

## Modes

### 1. `empty`
Creates an image fully padded with the selected pad byte.

### 2. `full`
Fills the entire image with data (random, patterned, or seeded).

### 3. `partial`
Writes real data **only at the start**, then pads the rest.
Useful for testing boundary detection when the image ends early.

### 4. `weird`
Creates a “fake size” image where the **last real sector** is placed inside the **first half** of the image. By default, **only one sector** is written, and it is **partially filled** with real bytes.

### 5. `range`
Fills **only specific sector ranges**, leaving everything else padded. Useful for very targeted tests.

---

## Profiles
Convenience profiles for common sizes (GiB):
- `1g`, `2g`, `4g`, `8g`, `16g`, `32g`

Use `--fake-gib` to override.

---

## Options

### Core
- `--mode empty|full|partial|weird|range`
- `--profile 1g|2g|4g|8g|16g|32g`
- `--fake-gib N`
- `-o, --output FILE` (required)

### Partial mode
- `--data-gib N`
- `--data-mib N`
- `--data-percent P`

### Weird mode
- `--percent P` (0–100)
- `--fill-before N` (sectors, default 0)
- `--partial-bytes N` (1–255; otherwise random)

### Range mode
- `--fill-range SPEC`
  - Examples: `23423-23555`, `40000:40010`, `30000`
  - Multiple ranges: `23423-23555,30000,40000:40010`

### Data and padding
- `--pad ff|00` (default `ff`)
- `--data random|pattern|seeded`
- `--seed N` (for deterministic bytes)

---

## Weird Mode (Detailed)
This mode simulates fake capacity with real data ending early.

**Rules:**
- `fake size` is defined by `--fake-gib` or `--profile`
- `real size` is implicitly **half** of fake size
- `--percent` controls where the last real sector is within the first half
  - `0%` → first sector
  - `100%` → last sector of the first half

**Default write behavior:**
- Only **one sector** is written at `last_real_sector`
- That sector is **partially filled** with random bytes (`1..255`)
- All remaining bytes are pad (`ff` or `00`)

**Optional:**
- `--fill-before N` fills up to `N` sectors immediately preceding the last sector
  - The start is clamped to sector 0 to avoid negative indices

---

## Range Mode (Detailed)
Use this when you want **only specific sectors** written.

Example:
```bash
./image_generator.sh -o range2g.dd --mode range --fake-gib 2 \
  --fill-range 23423-23555,30000,40000:40010
```

This writes data into those ranges and leaves everything else padded.
The reported “last data sector” is the **highest** sector written.

---

## Examples

### 1) Fake 2GiB, last sector in first half
```bash
./image_generator.sh -o fake2g.dd --mode weird --profile 2g
```

### 2) Fake 2GiB, last sector at 35% of first half
```bash
./image_generator.sh -o fake2g_35.dd --mode weird --fake-gib 2 --percent 35 --pad 00
```

### 3) Partial 8GiB, first 3GiB real
```bash
./image_generator.sh -o partial8g.dd --mode partial --fake-gib 8 --data-gib 3
```

### 4) Full 1GiB random
```bash
./image_generator.sh -o full1g.dd --mode full --profile 1g --data random
```

### 5) Targeted sector ranges
```bash
./image_generator.sh -o range2g.dd --mode range --fake-gib 2 \
  --fill-range 23423-23555,30000,40000:40010
```

---

## Output Summary
At the end of each run, the script prints:
- expected **last data sector**
- its byte offset

This is the value you can compare against `boundary_scanner.sh` results.

---

## Data Modes

- `random`  
  Uses `/dev/urandom` when possible. Fast, non‑deterministic unless `--seed` is set.

- `pattern`  
  Repeating `0xAA 0x55` pattern. Deterministic and easy to spot in hex.

- `seeded`  
  Deterministic pseudo‑random bytes. Use `--seed` to reproduce the same image.

---

## Notes & Caveats
- Large images (8–32 GiB) can take time and disk space.
- Non‑MiB offsets fall back to Python writing for accuracy.
- The tool is meant for **testing only**, not production forensic imaging.

