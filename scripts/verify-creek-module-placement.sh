#!/usr/bin/env bash
set -euo pipefail

ROOT=${1:?workspace root is required}
OUT=${2:?output directory is required}
DIST=${3:?dist directory is required}
STOCK=${4:?stock module-list directory is required}
REPORT=${5:?report path is required}

boot_list="$STOCK/vendor_boot.modules.load"
recovery_list="$STOCK/vendor_boot.modules.load.recovery"
dlkm_list="$DIST/vendor_dlkm.modules.load"

for f in "$boot_list" "$recovery_list"; do
  test -s "$f" || { echo "missing stock list: $f" >&2; exit 1; }
done

for image in vendor_boot.img vendor_dlkm.img system_dlkm.img; do
  test -s "$DIST/$image" || { echo "missing required output: $DIST/$image" >&2; exit 1; }
done

staging_root=""
for candidate in "$OUT/staging/lib/modules" "$OUT/gki_kernel/common/lib/modules" "$OUT/common/lib/modules"; do
  if compgen -G "$candidate/*" >/dev/null 2>&1; then
    staging_root=$(echo "$candidate"/* | awk '{print $1}')
    break
  fi
done

if [ -z "$staging_root" ]; then
  echo "no installed module staging tree found" >&2
  exit 1
fi

all_modules=$(mktemp)
trap 'rm -f "$all_modules"' EXIT
find "$staging_root" -type f -name '*.ko' -printf '%f\n' | sort -u > "$all_modules"

unique_list() {
  sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$1" | sort -u
}

boot_names=$(mktemp)
recovery_names=$(mktemp)
trap 'rm -f "$all_modules" "$boot_names" "$recovery_names"' EXIT
unique_list "$boot_list" > "$boot_names"
unique_list "$recovery_list" > "$recovery_names"

boot_present=$(comm -12 "$boot_names" "$all_modules" | sort -u)
recovery_present=$(comm -12 "$recovery_names" "$all_modules" | sort -u)
boot_missing=$(comm -23 "$boot_names" "$all_modules" | sort -u)
recovery_missing=$(comm -23 "$recovery_names" "$all_modules" | sort -u)

mkdir -p "$(dirname "$REPORT")"
{
  echo "Creek stock module placement verification"
  echo "workspace=$ROOT"
  echo "staging_root=$staging_root"
  echo "built_modules=$(wc -l < "$all_modules")"
  echo "stock_vendor_boot=$(wc -l < "$boot_names")"
  echo "stock_vendor_boot_recovery=$(wc -l < "$recovery_names")"
  echo "vendor_boot_present=$(printf '%s\n' "$boot_present" | sed '/^$/d' | wc -l)"
  echo "vendor_boot_missing=$(printf '%s\n' "$boot_missing" | sed '/^$/d' | wc -l)"
  echo "vendor_boot_recovery_present=$(printf '%s\n' "$recovery_present" | sed '/^$/d' | wc -l)"
  echo "vendor_boot_recovery_missing=$(printf '%s\n' "$recovery_missing" | sed '/^$/d' | wc -l)"
  echo
  echo "[vendor_boot modules present in build]"
  printf '%s\n' "$boot_present" | sed '/^$/d'
  echo
  echo "[vendor_boot modules missing from source/build]"
  printf '%s\n' "$boot_missing" | sed '/^$/d'
  echo
  echo "[vendor_boot recovery modules missing from source/build]"
  printf '%s\n' "$recovery_missing" | sed '/^$/d'
} > "$REPORT"

# The build must never place a module in vendor_dlkm if it is selected for
# normal vendor_boot loading. build.sh normally performs this subtraction;
# verify it explicitly so a bad modules.load cannot silently boot-loop.
if [ -f "$dlkm_list" ]; then
  dlkm_names=$(mktemp)
  trap 'rm -f "$all_modules" "$boot_names" "$recovery_names" "$dlkm_names"' EXIT
  unique_list "$dlkm_list" > "$dlkm_names"
  boot_names_for_overlap=$(mktemp)
  dlkm_names_for_overlap=$(mktemp)
  awk -F/ '{print $NF}' "$boot_names" | sort -u > "$boot_names_for_overlap"
  awk -F/ '{print $NF}' "$dlkm_names" | sort -u > "$dlkm_names_for_overlap"
  overlap=$(comm -12 "$boot_names_for_overlap" "$dlkm_names_for_overlap")
  rm -f "$boot_names_for_overlap" "$dlkm_names_for_overlap"
  if [ -n "$overlap" ]; then
    echo "vendor_dlkm/vendor_boot overlap detected:" >&2
    echo "$overlap" >&2
    exit 1
  fi
  {
    echo
    echo "vendor_dlkm_modules=$(wc -l < "$dlkm_names")"
    echo "[vendor_dlkm/vendor_boot overlap]"
    echo "none"
  } >> "$REPORT"
fi

# Preserve the exact source lists beside the generated images for flashing and
# debugging. The generated lists are also checked to contain only built files.
mkdir -p "$DIST"
cp -f "$boot_list" "$DIST/stock.vendor_boot.modules.load"
cp -f "$recovery_list" "$DIST/stock.vendor_boot.modules.load.recovery"

for generated in "$DIST/vendor_boot.modules.load" "$DIST/vendor_boot.modules.load.recovery"; do
  if [ -f "$generated" ]; then
    while IFS= read -r module; do
      [ -z "$module" ] && continue
      module_name=$(basename "$module")
      grep -Fxq "$module" "$all_modules" || grep -Fxq "$module_name" "$all_modules" || {
        echo "generated list contains unbuilt module: $module ($generated)" >&2
        exit 1
      }
    done < <(sed '/^[[:space:]]*#/d;/^[[:space:]]*$/d' "$generated")
  fi
done

echo "Module placement verification completed"
cat "$REPORT"
