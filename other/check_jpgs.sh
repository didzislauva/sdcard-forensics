#!/usr/bin/env bash
set -u

# Validate JPG/JPEG files in the current directory only (non-recursive),
# print per-file status, and write a CSV report with image metadata.

report_file="${1:-jpg_report.csv}"

choose_validator() {
  if command -v jpeginfo >/dev/null 2>&1; then
    echo "jpeginfo"
    return
  fi
  if command -v identify >/dev/null 2>&1; then
    echo "identify"
    return
  fi
  if command -v ffmpeg >/dev/null 2>&1; then
    echo "ffmpeg"
    return
  fi
  echo ""
}

validate_with_jpeginfo() {
  local f="$1"
  jpeginfo -c -- "$f" >/dev/null 2>&1
}

validate_with_identify() {
  local f="$1"
  identify -quiet -- "$f" >/dev/null 2>&1
}

validate_with_ffmpeg() {
  local f="$1"
  ffmpeg -v error -i "$f" -f null - >/dev/null 2>&1
}

csv_escape() {
  local s="$1"
  s="${s//\"/\"\"}"
  printf '"%s"' "$s"
}

write_csv_row() {
  local file_name="$1"
  local status="$2"
  local validator_name="$3"
  local size_bytes="$4"
  local width="$5"
  local height="$6"
  local format="$7"
  local colorspace="$8"
  local exif_datetime="$9"
  local camera_make="${10}"
  local camera_model="${11}"
  local orientation="${12}"
  local sha256="${13}"

  {
    csv_escape "$file_name"; printf ","
    csv_escape "$status"; printf ","
    csv_escape "$validator_name"; printf ","
    csv_escape "$size_bytes"; printf ","
    csv_escape "$width"; printf ","
    csv_escape "$height"; printf ","
    csv_escape "$format"; printf ","
    csv_escape "$colorspace"; printf ","
    csv_escape "$exif_datetime"; printf ","
    csv_escape "$camera_make"; printf ","
    csv_escape "$camera_model"; printf ","
    csv_escape "$orientation"; printf ","
    csv_escape "$sha256"; printf "\n"
  } >> "$report_file"
}

validator="$(choose_validator)"
if [[ -z "$validator" ]]; then
  echo "No JPEG validator found."
  echo "Install one of: jpeginfo (preferred), ImageMagick (identify), or ffmpeg."
  exit 2
fi

has_identify=0
has_exiftool=0
has_sha256sum=0

command -v identify >/dev/null 2>&1 && has_identify=1
command -v exiftool >/dev/null 2>&1 && has_exiftool=1
command -v sha256sum >/dev/null 2>&1 && has_sha256sum=1

ok=0
bad=0
total=0

printf '%s\n' '"file_name","status","validator","size_bytes","width","height","format","colorspace","exif_datetime_original","camera_make","camera_model","orientation","sha256"' > "$report_file"

for f in ./*; do
  [[ -f "$f" ]] || continue
  case "$f" in
    *.jpg|*.JPG|*.jpeg|*.JPEG)
      total=$((total + 1))

      file_name="${f#./}"
      size_bytes="$(wc -c < "$f" | tr -d '[:space:]')"
      width=""
      height=""
      format=""
      colorspace=""
      exif_datetime=""
      camera_make=""
      camera_model=""
      orientation=""
      sha256=""
      status="BAD"

      if "validate_with_${validator}" "$f"; then
        status="OK"
        ok=$((ok + 1))
        printf 'OK   %s\n' "$file_name"
      else
        bad=$((bad + 1))
        printf 'BAD  %s\n' "$file_name"
      fi

      if [[ "$has_identify" -eq 1 ]]; then
        identify_data="$(identify -quiet -format '%w,%h,%m,%[colorspace]\n' -- "$f" 2>/dev/null || true)"
        if [[ -n "$identify_data" ]]; then
          IFS=, read -r width height format colorspace <<< "$identify_data"
        fi
      fi

      if [[ "$has_exiftool" -eq 1 ]]; then
        mapfile -t exif_data < <(exiftool -s3 -DateTimeOriginal -Make -Model -Orientation -- "$f" 2>/dev/null || true)
        exif_datetime="${exif_data[0]:-}"
        camera_make="${exif_data[1]:-}"
        camera_model="${exif_data[2]:-}"
        orientation="${exif_data[3]:-}"
      fi

      if [[ "$has_sha256sum" -eq 1 ]]; then
        sha256="$(sha256sum -- "$f" 2>/dev/null | awk '{print $1}')"
      fi

      write_csv_row "$file_name" "$status" "$validator" "$size_bytes" "$width" "$height" "$format" "$colorspace" "$exif_datetime" "$camera_make" "$camera_model" "$orientation" "$sha256"
      ;;
  esac
done

echo "---"
echo "Validator: $validator"
echo "Total JPG/JPEG: $total"
echo "OK: $ok"
echo "BAD: $bad"
echo "CSV report: $report_file"
echo "Metadata tools: identify=$has_identify exiftool=$has_exiftool sha256sum=$has_sha256sum"

if [[ "$bad" -gt 0 ]]; then
  exit 1
fi
