#!/bin/bash

# ===============================
# Flash Fake Capacity Test (Method 1 - Reversible)
# ===============================

set -e

if [ "$EUID" -ne 0 ]; then
  echo "Run as root: sudo ./flash_forensic_test.sh /dev/sdX"
  exit 1
fi

if [ -z "$1" ]; then
  echo "Usage: sudo $0 /dev/sdX"
  exit 1
fi

DEV="$1"

echo "[*] Target device: $DEV"

# Get total sectors (512-byte sectors)
TOTAL=$(blockdev --getsz "$DEV")
LAST=$((TOTAL-1))
S1=$LAST
S2=$((LAST-2048))
S3=$((LAST-65536))

echo "[*] Total sectors: $TOTAL"
echo "[*] Testing sectors:"
echo "    S1 (last):     $S1"
echo "    S2 (-1MiB):    $S2"
echo "    S3 (-32MiB):   $S3"
echo

# Backup sectors
echo "[*] Backing up original sectors..."
dd if="$DEV" bs=512 skip=$S1 count=1 of=orig_S1.bin status=none
dd if="$DEV" bs=512 skip=$S2 count=1 of=orig_S2.bin status=none
dd if="$DEV" bs=512 skip=$S3 count=1 of=orig_S3.bin status=none

# Create patterns
echo "[*] Creating test patterns..."
python3 <<EOF
def make(fn, tag):
    s=(tag.encode('ascii')+b'\n')
    data=(s*((512//len(s))+1))[:512]
    open(fn,'wb').write(data)
make('pat_S1.bin', 'FORENSIC_TEST_S1_2026')
make('pat_S2.bin', 'FORENSIC_TEST_S2_2026')
make('pat_S3.bin', 'FORENSIC_TEST_S3_2026')
EOF


echo
echo "================================================="
echo ">>> Patterns created                             "
echo ">>> Press ENTER to write them to card.           "
echo ">>> Be aware that IF THE CARD IS NOT BACKED UP,  "
echo ">>> in case of faked card due to sector warping  "
echo ">>> will be lost!                                "
echo ">>> Enter to continue, Ctrl+C to cancel          "
echo "================================================="
read


# Write patterns
echo "[*] Writing patterns..."
dd if=pat_S1.bin of="$DEV" bs=512 seek=$S1 conv=notrunc status=none
dd if=pat_S2.bin of="$DEV" bs=512 seek=$S2 conv=notrunc status=none
dd if=pat_S3.bin of="$DEV" bs=512 seek=$S3 conv=notrunc status=none
sync

echo
echo "================================================="
echo ">>> IMPORTANT: Physically remove and reinsert the card."
echo ">>> Then press ENTER to continue verification."
echo "================================================="
read

echo "[*] Reading back sectors..."
echo "--- Sector S1 ---"
dd if="$DEV" bs=512 skip=$S1 count=1 status=none | strings | head
echo "--- Sector S2 ---"
dd if="$DEV" bs=512 skip=$S2 count=1 status=none | strings | head
echo "--- Sector S3 ---"
dd if="$DEV" bs=512 skip=$S3 count=1 status=none | strings | head

echo
echo "[*] Searching entire device for patterns (wrap detection)..."
dd if="$DEV" bs=4M status=none | LC_ALL=C grep -aob 'FORENSIC_TEST_S1_2026' || true
dd if="$DEV" bs=4M status=none | LC_ALL=C grep -aob 'FORENSIC_TEST_S2_2026' || true
dd if="$DEV" bs=4M status=none | LC_ALL=C grep -aob 'FORENSIC_TEST_S3_2026' || true

echo
echo "[*] Restoring original sectors..."
dd if=orig_S1.bin of="$DEV" bs=512 seek=$S1 conv=notrunc status=none
dd if=orig_S2.bin of="$DEV" bs=512 seek=$S2 conv=notrunc status=none
dd if=orig_S3.bin of="$DEV" bs=512 seek=$S3 conv=notrunc status=none
sync

echo "[*] Restore complete."
echo
echo "Test finished."

