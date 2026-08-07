#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-$(pwd)/kernel_platform}"
KERNEL="$ROOT/msm-kernel"
VENDOR_DTS="$KERNEL/arch/arm64/boot/dts/vendor"

mkdir -p "$VENDOR_DTS"

# build.sh recursively invokes the GKI build. Do not let the outer external
# module makefile run during that recursive common-kernel build: vendor modules
# must be built only after GKI artifacts exist, against msm-kernel with
# KBUILD_MIXED_TREE set. The upstream script clears EXT_MODULES but older
# branches do not clear EXT_MODULES_MAKEFILE.
BUILD_SH="$ROOT/build/build.sh"
REAL_BUILD_SH="$(readlink -f "$BUILD_SH")"
if [ ! -f "$REAL_BUILD_SH" ]; then
  echo "ERROR: resolved build.sh target not found: $REAL_BUILD_SH" >&2
  exit 1
fi
if grep -q 'GKI_ENVIRON+=("EXT_MODULES=")' "$REAL_BUILD_SH" \
   && ! grep -q 'GKI_ENVIRON+=("EXT_MODULES_MAKEFILE=")' "$REAL_BUILD_SH"; then
  sed -i '/GKI_ENVIRON+=("EXT_MODULES=")/a\  GKI_ENVIRON+=("EXT_MODULES_MAKEFILE=")' "$REAL_BUILD_SH"
  sed -i '/GKI_ENVIRON+=("EXT_MODULES_MAKEFILE=")/a\  GKI_ENVIRON+=("BUILD_BOOT_IMG=" "BUILD_VENDOR_BOOT_IMG=" "BUILD_INIT_BOOT_IMG=" "BUILD_VENDOR_KERNEL_BOOT=" "BUILD_DTBO_IMG=" "SKIP_VENDOR_BOOT=1")' "$REAL_BUILD_SH"
fi

# QCOM DTs are out-of-tree in Xiaomi's kernel_devicetree repo.
# arch/arm64/boot/dts/Makefile only descends into vendor/ when vendor/Makefile exists.
# Without this, dtbs_install creates no dtb_staging directory and build.sh fails in install_dtbs.
if [ ! -e "$VENDOR_DTS/Makefile" ]; then
  ln -s "$ROOT/kernel-devicetree/Makefile" "$VENDOR_DTS/Makefile"
fi
if [ ! -e "$VENDOR_DTS/qcom" ]; then
  ln -s "$ROOT/kernel-devicetree/qcom" "$VENDOR_DTS/qcom"
fi
if [ ! -e "$VENDOR_DTS/bindings" ] && [ -e "$ROOT/kernel-devicetree/bindings" ]; then
  ln -s "$ROOT/kernel-devicetree/bindings" "$VENDOR_DTS/bindings"
fi

echo "Prepared Creek stock source layout"
echo "ROOT=$ROOT"
echo "KERNEL=$KERNEL"
echo "VENDOR_DTS=$VENDOR_DTS"
echo "BUILD_SH=$BUILD_SH -> $(readlink "$BUILD_SH" 2>/dev/null || true)"
echo "REAL_BUILD_SH=$REAL_BUILD_SH"
echo "REAL_GETTOP=$(dirname "$REAL_BUILD_SH")/gettop.sh"
test -f "$(dirname "$REAL_BUILD_SH")/gettop.sh"
ls -la "$VENDOR_DTS"
