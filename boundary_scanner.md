# boundary_scanner.sh

## Purpose
`boundary_scanner.sh` scans a raw image file to find the last block/sector that contains non‑pad data (e.g., not `0xFF`). It reports the last non‑pad block, an approximate last real data offset, and (by default) refines to the last non‑pad sector.

## Quick Start
```bash
./boundary_scanner.sh -f image.dd
```

## Core Options
- `-f, --file PATH` Image file to scan (required).
- `-b, --block-mib N` Block size in MiB (default: `1`).
- `-p, --pad-bytes "..."` Pad bytes in hex (default: `"ff"`).
- `-m, --method METHOD` Scan method: `dd`, `tail`, `grep` (default: `dd`).
- `-c, --chunk-mib N` Chunk size in MiB for `tail`/`grep` (default: `64`).
- `-s, --start-block N` Start scanning from block N (default: last block).
- `-P, --profile SIZE` Start from card size profile: `1g,2g,4g,8g,16g,32g,64g,128g` (GiB).
- `-x, --extract-out FILE` Extract image up to last non‑pad sector into FILE.
- `-L, --extract-last FILE` Extract only the last non‑pad 512‑byte sector into FILE.
- `-B, --extract-boundary FILE` Extract last non‑pad and first pad sectors into FILE.
- `--log-file FILE` Write full output to FILE (default: `boundary_scanner/scan_YYYYmmdd_HHMMSS.log`).
- `-q, --quiet` Suppress console output (log still written). Skips tool check.
- `--progress N` Progress update interval in blocks (default: `100`).
- `--no-refine` Skip sector‑level boundary refinement.

Notes:
- If both `--start-block` and `--profile` are set, `--start-block` wins.
- Start block is clamped to the image size if it exceeds total blocks.
- `--extract-out` writes a new file trimmed to the last non‑pad sector.
- `--extract-last` writes only the last non‑pad 512‑byte sector.
- `--extract-boundary` writes last and first sectors into a single file.
- `--log-file` controls where the log is written (directory is created if needed).
- `--quiet` suppresses console output and skips the tool check, but still writes the full log (including summary).
- Progress updates are shown on the terminal only and are not written to the log.
- Warning: Results are indicative only and do not prove a card is fake.

## Methods
- `dd` (default): Scans block‑by‑block from the end, reading 1 MiB per block by default. Fast and precise.
- `tail`: Scans large chunks from the end, then narrows inside the hit chunk to the exact block. Faster on large images.
- `grep`: Scans chunks using `grep -aob -P` to find the last non‑pad byte. Progress is aligned to block numbers.

## Refinement
After the last non‑pad block is found, the script narrows the boundary within that block down to 512‑byte sectors (unless `--no-refine` is set). It reports:
- last non‑pad sector and byte offset
- first pad sector (or EOF)

## Examples
```bash
# Basic scan
./boundary_scanner.sh -f image.dd

# Tail method with larger blocks
./boundary_scanner.sh -f image.dd -m tail -b 2 -c 128

# Grep method with progress every 50 blocks
./boundary_scanner.sh -f image.dd -m grep --progress 50

# Known pad pattern
./boundary_scanner.sh -f image.dd -p "ff 00"

# Start from a profile size (GiB)
./boundary_scanner.sh -f image.dd -P 8g

# Explicit start block
./boundary_scanner.sh -f image.dd -s 12000

# Extract up to boundary
./boundary_scanner.sh -f image.dd -x trimmed.dd

# Extract last sector only
./boundary_scanner.sh -f image.dd -L last_sector.bin

# Extract last real + first padded sectors into one file
./boundary_scanner.sh -f image.dd -B boundary.bin

# Custom log destination
./boundary_scanner.sh -f image.dd --log-file boundary_scanner/custom.log

# Silent run (log only)
./boundary_scanner.sh -f image.dd -q

# No refinement
./boundary_scanner.sh -f image.dd --no-refine
```

## Output
Typical output includes:
- image and block size
- total blocks and pad byte(s)
- method and progress configuration
- last non‑pad block and approximate offset
- refined boundary (sector‑level) if enabled
- last non‑pad byte offset (if `grep -P` is available)

## Dependencies
Requires standard Unix tools: `dd`, `tr`, `grep`, `stat`, `awk`.
