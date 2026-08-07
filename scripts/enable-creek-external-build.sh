#!/usr/bin/env bash
set -euo pipefail

ROOT=${1:?kernel_platform path is required}
KERNEL=${ROOT}/msm-kernel

test -f "${KERNEL}/build.config.msm.creek"
for f in \
  vendor/qcom/opensource/wlan/platform/Makefile \
  vendor/qcom/opensource/wlan/qcacld-3.0/Makefile \
  vendor/qcom/opensource/audio-kernel/Makefile \
  vendor/qcom/opensource/camera-kernel/Makefile \
  vendor/qcom/opensource/display-drivers/Makefile; do
  test -f "${ROOT}/${f}"
done

echo "Creek external source roots are present"
for d in \
  vendor/qcom/opensource/wlan/platform \
  vendor/qcom/opensource/wlan/qcacld-3.0 \
  vendor/qcom/opensource/audio-kernel \
  vendor/qcom/opensource/camera-kernel \
  vendor/qcom/opensource/display-drivers; do
  if [ -e "${ROOT}/${d}" ]; then
    printf '  %s\n' "${d}"
  else
    printf '  %s (not present)\n' "${d}"
  fi
done
