# sdcard-forensics

**Read‑only forensic tooling for flash images.**  
Find real data boundaries, detect wrap/alias patterns, and extract evidence slices — without touching the source image.

---

## What You Can Achieve

- **Locate the last real data** in a padded or over‑reported image.
- **Detect wrap/alias patterns** that are common in fake‑capacity flash.
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

## Requirements

### Required Tools
- `dd`, `stat`, `split`, `sort`, `uniq`, `awk`, `head`, `xxd`, `mktemp`, `sed`, `wc`, `tr`, `basename`, `grep`

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
```

---

## Safety / Forensics Notes
- **Read‑only by design**: source images are never modified.  
- Results are **indicative only** and do not prove authenticity.  
- Uniform data (all‑FF or all‑00) can produce false signals.  
- Always corroborate with additional evidence.

---


## License
See `LICENSE`.
