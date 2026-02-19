#!/bin/bash

FILE="image.dd"
BS=$((1024*1024))   # 1MB blocks

size=$(stat -c%s "$FILE")
blocks=$((size/BS))

echo "Total blocks: $blocks"

for ((i=blocks-1; i>=0; i--)); do
    dd if="$FILE" bs=$BS skip=$i count=1 2>/dev/null | \
    tr -d '\xff' | grep -q . && break

    if (( i % 100 == 0 )); then
        echo "Checking block $i..."
    fi
done

echo "Last non-FF block: $i"
echo "Approx last real data offset: $((i*BS)) bytes"
