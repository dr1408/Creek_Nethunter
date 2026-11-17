#!/usr/bin/env bash
set -euo pipefail
: "${KP:?}" "${OUT_DIR:?}" "${BASELINE:?}" "${GITHUB_WORKSPACE:?}"
# Trusted artifact produced by this repository's full-build workflow.
source "$BASELINE/build-env.sh"
jobs="${BUILD_JOBS:-auto}"
if [[ "$jobs" == auto ]]; then jobs="$(nproc --all)"; fi
[[ "$jobs" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid jobs value" >&2; exit 1; }
mixed="$OUT_DIR/gki_kernel/dist"
mkdir -p "$GITHUB_WORKSPACE/artifacts/wlan-modules"
# Use the same source/config/symvers and tool environment as the baseline.
# No kernel build.sh, images, camera, audio or display builds are invoked.
rebuild_cfg="${REBUILD_CFG80211:-false}"
if [[ -f "$BASELINE/requires-cfg80211-rebuild" ]]; then
    rebuild_cfg=true
    echo "Rebuilding cfg80211: removing the old baseline's channel patch"
fi
if [[ "$rebuild_cfg" == true ]]; then
    make -C "$KP/msm-kernel" O="$OUT_DIR/msm-kernel" \
        ARCH=arm64 LLVM=1 KBUILD_MIXED_TREE="$mixed" \
        M="$KP/msm-kernel/net/wireless" -j"$jobs" modules
    cp "$KP/msm-kernel/net/wireless/cfg80211.ko" \
        "$OUT_DIR/msm-kernel/net/wireless/cfg80211.ko"
fi
make -f "$GITHUB_WORKSPACE/scripts/creek-external-modules.mk" \
    KERNEL_SRC="$KP/msm-kernel" O="$OUT_DIR/msm-kernel" \
    INSTALL_MOD_PATH="$OUT_DIR/wlan-staging" KBUILD_MIXED_TREE="$mixed" \
    CREEK_WLAN_BASELINE_DIR= -j"$jobs" wlan-qcacld
dest="$GITHUB_WORKSPACE/artifacts/wlan-modules"
find "$OUT_DIR/wlan-staging/lib/modules" -type f -name '*.ko' \
    -exec cp -f {} "$dest/" \;
test -f "$dest/qca_cld3_wlan.ko"
test -f "$OUT_DIR/msm-kernel/net/wireless/cfg80211.ko"
cp "$OUT_DIR/msm-kernel/net/wireless/cfg80211.ko" "$dest/"
{
    echo "QCACLD revision: $(git -C "$KP/vendor/qcom/opensource/wlan" rev-parse HEAD)"
    echo "cfg80211 rebuilt: $rebuild_cfg"
    echo "Kernel release: $(cat "$OUT_DIR/msm-kernel/include/config/kernel.release")"
    sha256sum "$BASELINE/metadata.json" "$dest/"*.ko
} > "$GITHUB_WORKSPACE/artifacts/logs/module-provenance.txt"
