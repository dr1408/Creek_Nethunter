#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-$(pwd)/kernel_platform}"
KERNEL="$ROOT/msm-kernel"
VENDOR_DTS="$KERNEL/arch/arm64/boot/dts/vendor"

mkdir -p "$VENDOR_DTS"

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
ls -la "$VENDOR_DTS"
