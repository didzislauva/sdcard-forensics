# sdcard-forensics

**Read‑only forensic tooling for flash images.**  
Find real data boundaries, detect wrap/alias patterns, and generate synthetic images to validate your analysis — without touching the source image.

---

## What You Can Achieve

- **Locate the last real data** in a padded or over‑reported image.
- **Detect wrap/alias patterns** that are common in fake‑capacity flash.
- **Generate controlled test images** to validate tools and edge cases.
- **Extract evidence slices** (trimmed image, last sector, or boundary sectors).
- **Produce timestamped logs** suitable for case notes and audits.

---

## Tools

### `boundary_scanner.sh`
Finds the last non‑pad block/sector in a raw image and optionally extracts trimmed output or boundary sectors.

**Best for:**  
- Finding where “real” data ends  
- Identifying padding boundaries  
- Creating trimmed images for downstream analysis

**Features**  
- Scan methods: `dd`, `tail`, `grep`  
- Sector‑level refinement (512 bytes)  
- Extract options: trim to boundary, last sector, or boundary pair  
- Timestamped logs (ANSI stripped)  
- Single‑line progress in terminal

Docs: `boundary_scanner.md`

---

### `fakeflash_forensic_pro.sh`
Detects wrap/alias behavior typical of fake flash by hashing sample regions and comparing tail windows to earlier candidates.

**Best for:**  
- High‑confidence wrap detection  
- Profiling suspected real sizes  
- Forensic signals (duplicate blocks, tail alias)

**Features**  
- Profile presets for common sizes  
- Advanced overrides (block, sample, tail, candidates)  
- Tail heuristic + duplicate block detection  
- Timestamped logs + quiet mode + run summary

Docs: `fakeflash_forensic_pro.md`

---

### `image_generator.sh`
Generates **synthetic raw images** for testing and validation. Supports empty/full/partial/weird/range modes with precise control over padding and last‑sector placement.

**Best for:**  
- Regression tests for boundary detection  
- Creating tricky off‑by‑one cases  
- Simulating fake capacity with early end‑of‑data  
- Range‑only sector fills for targeted scans

**Features**  
- GiB profiles: `1g,2g,4g,8g,16g,32g`  
- Modes: `empty`, `full`, `partial`, `weird`, `range`  
- Padding control (`ff` / `00`)  
- Random / pattern / seeded data  
- Partial‑sector writes and range fills

Docs: `image_generator.md`

---

## Requirements

### Required Tools
- `dd`, `stat`, `split`, `sort`, `uniq`, `awk`, `head`, `xxd`, `mktemp`, `sed`, `wc`, `tr`, `basename`, `grep`
- `python3` (required for image generation and precise offsets)

### Optional (recommended)
- `pv` (nicer progress in `fakeflash_forensic_pro.sh`)  
- `b3sum` (faster hashing if available)

---

## Quick Start

```bash
# Boundary scan
./boundary_scanner.sh -f image.dd

# Fake flash detection
./fakeflash_forensic_pro.sh -p 64G image.dd

# Generate a fake 2GiB image with data ending early (weird mode)
./image_generator.sh -o fake2g.dd --mode weird --fake-gib 2
```

---

## Safety / Forensics Notes
- **Read‑only by design**: source images are never modified.  
- Results are **indicative only** and do not prove authenticity.  
- Uniform data (all‑FF or all‑00) can produce false signals.  
- Always corroborate with additional evidence.

---

## What Else Could Be Added

If you want more capability, the next logical additions are:

1. **Automatic cross‑tool workflow**  
Run `boundary_scanner.sh` automatically after `fakeflash_forensic_pro.sh` and append results to the same log.

2. **Confidence scoring**  
Aggregate duplicate‑block rate + tail‑match rate into a numeric confidence metric.

3. **Export formats**  
JSON summary for integration in reports or dashboards.

4. **Batch mode**  
Run multiple images from a directory, produce per‑image logs + summary CSV.

5. **Report bundles**  
Auto‑collect logs, boundary slices, and summary in a single archive.

---

## License
See `LICENSE`.
