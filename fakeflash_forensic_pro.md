# fakeflash_forensic_pro.sh

## Purpose
`fakeflash_forensic_pro.sh` is a **read‑only** forensic helper that looks for wrap/alias patterns typical of fake flash media. It hashes sample regions and compares tail blocks against earlier candidate windows to detect modulo mapping. It **does not prove** a card is fake; it only provides indicators.

## Quick Start
```bash
./fakeflash_forensic_pro.sh -p 64G image.dd
```

## Modes
- **Simple mode**: choose a profile size (recommended).
- **Advanced mode**: override block size, sample size, tail window, and candidate list.

## Options
- `-p, --profile SIZE` One of: `8G, 16G, 32G, 64G, 128G, 256G`.
- `-b, --block-mib N` Block size in MiB.
- `-S, --sample-gib N` Sample size in GiB (hash first N GiB).
- `-t, --tail-mib N` Tail window in MiB (compare last N MiB).
- `-c, --candidates "..."` Candidate capacities in MiB (space‑separated).
- `--dump-duplicates` Dump first occurrence of each duplicate block to CWD.
- `--log FILE` Write full log to FILE (default: `./fakeflash_forensic_pro/scan_YYYYmmdd_HHMMSS.log`).
- `--monochrome` Disable ANSI colors on console output.
- `-q, --quiet` Suppress console output (log still written).
- `-h, --help` Show help.

Notes:
- If no profile is given and no advanced flags are set, the script auto‑picks the closest profile based on the image size.
- Advanced flags override the selected profile.
- Warning: Results are indicative only and do not prove a card is fake.

## Workflow (Phases)
1. **Phase 0 — Tail heuristic**
   - Shows a quick hex preview of the last 1 MiB to visually spot padding (`FF/00`).
   - This is **not** proof, just a hint.

2. **Phase 1 — Sample hashing**
   - Hashes the first `SAMPLE_GIB` GiB into block‑sized chunks.
   - Flags duplicate block hashes (suspicious of repeated data).

3. **Phase 2 — Tail window hashing**
   - Hashes the last `TAIL_MIB` MiB into block‑sized chunks.

4. **Phase 3 — Candidate comparison**
   - Compares the tail hashes against candidate earlier windows (possible “real” sizes).
   - A high match rate strongly suggests modulo wrap/aliasing.

5. **Interpretation + Summary**
   - Classifies signal strength (strong / weak / none).
   - Prints a final run summary with best candidate, duplicates count, elapsed time, and log path.

## Examples
```bash
# Simple profile run
./fakeflash_forensic_pro.sh -p 64G image.dd

# Auto‑profile selection (no profile given)
./fakeflash_forensic_pro.sh image.dd

# Advanced overrides
./fakeflash_forensic_pro.sh -b 8 -S 8 -t 256 -c "8192 16384 32768 40960 49152" image.dd

# Dump duplicate blocks to the current directory
./fakeflash_forensic_pro.sh -p 32G --dump-duplicates image.dd

# Custom log location
./fakeflash_forensic_pro.sh -p 128G --log ./logs/fakeflash_scan.log image.dd

# Quiet run (log only)
./fakeflash_forensic_pro.sh -p 64G -q image.dd
```

## Output Highlights
- Profile and geometry (block size, total blocks, tail window)
- Duplicate block hashes (if any)
- Candidate comparison match rates
- Interpretation hints
- Run summary (best candidate, duplicates, elapsed time, log)

## Dependencies
Required:
- `dd`, `stat`, `split`, `sort`, `uniq`, `awk`, `head`, `xxd`, `mktemp`, `sed`, `wc`, `tr`, `basename`

Optional:
- `pv` (for nicer progress display)
- `b3sum` (preferred hash if available; falls back to `sha256sum`)

## Limitations
- This tool is read‑only and does not repair or modify images.
- It detects common wrap/alias patterns, but **does not guarantee** authenticity.
- Uniform data (all‑zero or all‑FF) can cause false positives.

## Tuning Guide
Use these knobs to balance **speed**, **confidence**, and **false positives**:

1. **Block size (`-b`)**
   - Larger blocks (8–16 MiB) reduce false positives on uniform data.
   - Smaller blocks (2–4 MiB) can be more sensitive but slower.

2. **Sample size (`-S`)**
   - Increase for more confidence, especially on large cards.
   - For quick checks, keep it small (e.g., 3–4 GiB).

3. **Tail window (`-t`)**
   - Larger tail windows (256–512 MiB) improve wrap detection.
   - Smaller windows run faster but reduce confidence.

4. **Candidates (`-c`)**
   - Include likely true capacities in MiB.
   - If suspicious, expand the list (e.g., add 6144/12288/24576).

5. **When to re‑run**
   - If results are ambiguous, try:
     - `-b 16` to reduce padding‑driven matches.
     - `-t 512` for more tail samples.
     - `-S 16` for a larger sample region.
