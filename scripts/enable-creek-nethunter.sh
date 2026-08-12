#!/usr/bin/env bash
set -euo pipefail

ROOT=${1:?kernel_platform path is required}
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMON="$ROOT/common"
MSM="$ROOT/msm-kernel"
PATCH_DIR="$REPO_ROOT/patches/common"

# BBG builds a host helper with clang-14. Some GitHub runner images do not
# expose an unversioned `ld` in PATH, even when binutils/lld are installed.
# Provide one before BBG setup so flask header generation succeeds.
HOST_TOOLS="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/nethunter-host-tools"
mkdir -p "$HOST_TOOLS"
if command -v ld.lld >/dev/null 2>&1; then
  ln -sf "$(command -v ld.lld)" "$HOST_TOOLS/ld"
elif command -v ld.bfd >/dev/null 2>&1; then
  ln -sf "$(command -v ld.bfd)" "$HOST_TOOLS/ld"
elif command -v ld >/dev/null 2>&1; then
  ln -sf "$(command -v ld)" "$HOST_TOOLS/ld"
else
  echo "ERROR: no host linker (ld.lld, ld.bfd, or ld) found" >&2
  exit 1
fi
export PATH="$HOST_TOOLS:$PATH"
# build.sh later prepends its hermetic tool directories, so place the alias
# there as well. BBG's clang invocation must find `ld` during mrproper.
for host_bin in \
  "$ROOT/build/kernel/build-tools/path/linux-x86" \
  "$ROOT/prebuilts/kernel-build-tools/linux-x86/bin"; do
  if [ -d "$host_bin" ]; then
    ln -sf "$(command -v ld.lld || command -v ld.bfd)" "$host_bin/ld"
  fi
done

if [ ! -d "$COMMON" ]; then
  echo "ERROR: common kernel source not found: $COMMON" >&2
  exit 1
fi
if [ ! -x "$COMMON/scripts/config" ]; then
  echo "ERROR: scripts/config not found or not executable in common source" >&2
  exit 1
fi

apply_patch_file() {
  local tree=$1
  local patch_file=$2
  local name
  name=$(basename "$patch_file")
  if git -C "$tree" apply --check "$patch_file" >/dev/null 2>&1; then
    echo "[nethunter] applying $name"
    git -C "$tree" apply "$patch_file"
  elif git -C "$tree" apply --reverse --check "$patch_file" >/dev/null 2>&1; then
    echo "[nethunter] $name already applied"
  else
    echo "[nethunter] git apply failed for $name, trying patch --dry-run"
    if (cd "$tree" && patch -p1 --dry-run < "$patch_file" >/dev/null); then
      (cd "$tree" && patch -p1 < "$patch_file")
    elif (cd "$tree" && patch -R -p1 --dry-run < "$patch_file" >/dev/null); then
      echo "[nethunter] $name already applied"
    else
      echo "ERROR: $name does not apply cleanly to $tree" >&2
      exit 1
    fi
  fi
}

for patch in \
  "$PATCH_DIR/gki-ptrace.patch" \
  "$PATCH_DIR/droidspaces-sysvipc-kabi-6-7-8.patch" \
  "$PATCH_DIR/droidspaces-cgroup-prefix.patch" \
  "$PATCH_DIR/bbrv3-android13-5.15.patch"; do
  test -f "$patch"
  apply_patch_file "$COMMON" "$patch"
done

# Baseband Guard (BBG): source is injected into common/security as an LSM.
echo "[nethunter] setting up Baseband Guard"
(
  cd "$COMMON"
  if ! curl -fsSL https://github.com/vc-teahouse/Baseband-guard/raw/main/setup.sh | bash -s main; then
    echo "ERROR: Baseband Guard setup failed" >&2
    exit 1
  fi
)

COMMON_DEFCONFIG="$COMMON/arch/arm64/configs/gki_defconfig"
NETHUNTER_CONFIG="$COMMON/arch/arm64/configs/nethunter.config"
test -f "$COMMON_DEFCONFIG"

# Keep the common GKI module allow-list in sync with modules selected by the
# common fragment below. MSM-only drivers are deliberately excluded: they are
# built from msm-kernel and belong to the vendor module staging flow.
GKI_MODULES_LIST="$COMMON/android/gki_aarch64_modules"
if [ -f "$GKI_MODULES_LIST" ]; then
  # Remove stale MSM-only entries left by older NetHunter revisions.
  sed -i \
    -e '/^drivers\/net\/wireless\/mediatek\//d' \
    -e '/^drivers\/net\/wireless\/realtek\//d' \
    "$GKI_MODULES_LIST"
  for module in \
    net/ipv4/tcp_bic.ko \
    net/ipv4/tcp_westwood.ko \
    net/ipv4/tcp_htcp.ko; do
    grep -qxF "$module" "$GKI_MODULES_LIST" || echo "$module" >> "$GKI_MODULES_LIST"
  done
fi

# Creek GKI enables CONFIG_TRIM_UNUSED_KSYMS through TRIM_NONLISTED_KMI in
# build.config.gki.aarch64. Disable that broad export trimming so MSM/vendor
# NetHunter wireless modules can link against the normal common GKI exports.
# KMI strict mode depends on TRIM_NONLISTED_KMI in Android build.sh, so disable
# that paired check too.
GKI_AARCH64_CONFIG="$COMMON/build.config.gki.aarch64"
if [ -f "$GKI_AARCH64_CONFIG" ]; then
  sed -i '/^TRIM_NONLISTED_KMI=/d' "$GKI_AARCH64_CONFIG"
  sed -i '/^KMI_SYMBOL_LIST_STRICT_MODE=/d' "$GKI_AARCH64_CONFIG"
fi
: > "$NETHUNTER_CONFIG"
CFG="$COMMON/scripts/config --file $NETHUNTER_CONFIG"

# DroidSpaces/container support + ABI-safe SYSVIPC patches above.
$CFG \
  -e CONFIG_SYSVIPC \
  -e CONFIG_DEVTMPFS \
  -e CONFIG_PID_NS \
  -e CONFIG_POSIX_MQUEUE \
  -e CONFIG_USER_NS \
  -e CONFIG_TMPFS_XATTR \
  -e CONFIG_TMPFS_POSIX_ACL \
  -e CONFIG_FW_CACHE

# Baseband Guard LSM.
$CFG -e CONFIG_BBG \
  --set-str CONFIG_LSM "landlock,lockdown,yama,loadpin,safesetid,integrity,selinux,smack,tomoyo,apparmor,bpf,baseband_guard"
sed -i '/^[[:space:]]*config[[:space:]]\+LSM$/,/^[[:space:]]*help[[:space:]]*$/{ /^[[:space:]]*default/ { /baseband_guard/! s/selinux/selinux,baseband_guard/ } }' "$COMMON/security/Kconfig"

# BBRv3 and traffic schedulers.
$CFG \
  -e CONFIG_TCP_CONG_ADVANCED \
  -e CONFIG_TCP_CONG_BBR \
  -e CONFIG_TCP_CONG_BBR3 \
  -e CONFIG_DEFAULT_BBR3 \
  -d CONFIG_DEFAULT_CUBIC \
  -d CONFIG_DEFAULT_RENO \
  -d CONFIG_DEFAULT_BBR \
  --set-str CONFIG_DEFAULT_TCP_CONG bbr3 \
  -e CONFIG_NET_SCH_FQ \
  -e CONFIG_NET_SCH_FQ_CODEL \
  -e CONFIG_NET_SCH_CAKE \
  -e CONFIG_NET_SCH_PIE \
  -e CONFIG_NET_SCH_FQ_PIE

# NetHunter: Bluetooth USB, SDR, CAN, USB serial, TTL, IP set.
$CFG \
  -e CONFIG_RFKILL \
  -e CONFIG_BT_HCIBTUSB \
  -e CONFIG_BT_HCIBTUSB_BCM \
  -e CONFIG_BT_HCIBTUSB_RTL \
  -e CONFIG_BT_HCIVHCI \
  -e CONFIG_BT_HCIBCM203X \
  -e CONFIG_BT_HCIBPA10X \
  -e CONFIG_BT_HCIBFUSB \
  -e CONFIG_USB_AIRSPY \
  -e CONFIG_USB_HACKRF \
  -e CONFIG_CAN \
  -e CONFIG_CAN_DEV \
  -e CONFIG_CAN_CALC_BITTIMING \
  -e CONFIG_CAN_LEDS \
  -e CONFIG_CAN_VCAN \
  -e CONFIG_CAN_GRCAN \
  -e CONFIG_CAN_XILINXCAN \
  -e CONFIG_CAN_C_CAN \
  -e CONFIG_CAN_C_CAN_PLATFORM \
  -e CONFIG_CAN_C_CAN_PCI \
  -e CONFIG_CAN_CC770 \
  -e CONFIG_CAN_CC770_ISA \
  -e CONFIG_CAN_CC770_PLATFORM \
  -e CONFIG_CAN_M_CAN \
  -e CONFIG_CAN_M_CAN_PCI \
  -e CONFIG_CAN_M_CAN_PLATFORM \
  -e CONFIG_CAN_M_CAN_TCAN4X5X \
  -e CONFIG_CAN_HI311X \
  -e CONFIG_CAN_MCP251X \
  -e CONFIG_CAN_8DEV_USB \
  -e CONFIG_CAN_EMS_USB \
  -e CONFIG_CAN_ESD_USB2 \
  -e CONFIG_CAN_GS_USB \
  -e CONFIG_CAN_KVASER_USB \
  -e CONFIG_CAN_PEAK_USB \
  -e CONFIG_NETLINK_DIAG \
  -e CONFIG_VSOCKETS \
  -e CONFIG_NET_SCHED \
  -e CONFIG_NET_EMATCH_CANID \
  -e CONFIG_USB_SERIAL \
  -e CONFIG_USB_SERIAL_CONSOLE \
  -e CONFIG_USB_SERIAL_GENERIC \
  -e CONFIG_USB_SERIAL_CH341 \
  -e CONFIG_USB_SERIAL_FTDI_SIO \
  -e CONFIG_USB_SERIAL_PL2303 \
  -e CONFIG_IP_NF_TARGET_TTL \
  -e CONFIG_IP6_NF_TARGET_HL \
  -e CONFIG_IP6_NF_MATCH_HL \
  -e CONFIG_IP_SET \
  --set-val CONFIG_IP_SET_MAX 65534 \
  -e CONFIG_IP_SET_BITMAP_IP \
  -e CONFIG_IP_SET_BITMAP_IPMAC \
  -e CONFIG_IP_SET_BITMAP_PORT \
  -e CONFIG_IP_SET_HASH_IP \
  -e CONFIG_IP_SET_HASH_IPMARK \
  -e CONFIG_IP_SET_HASH_IPPORT \
  -e CONFIG_IP_SET_HASH_IPPORTIP \
  -e CONFIG_IP_SET_HASH_IPPORTNET \
  -e CONFIG_IP_SET_HASH_IPMAC \
  -e CONFIG_IP_SET_HASH_MAC \
  -e CONFIG_IP_SET_HASH_NETPORTNET \
  -e CONFIG_IP_SET_HASH_NET \
  -e CONFIG_IP_SET_HASH_NETNET \
  -e CONFIG_IP_SET_HASH_NETPORT \
  -e CONFIG_IP_SET_HASH_NETIFACE \
  -e CONFIG_IP_SET_LIST_SET

# NFS client + server. Keep Kerberos disabled for simple sec=sys Android use.
$CFG \
  -e CONFIG_NETWORK_FILESYSTEMS \
  -e CONFIG_NFS_FS \
  -e CONFIG_NFS_V3 \
  -e CONFIG_NFS_V3_ACL \
  -e CONFIG_NFS_V4 \
  -e CONFIG_NFS_V4_1 \
  -e CONFIG_NFS_V4_2 \
  -e CONFIG_NFSD \
  -e CONFIG_NFSD_V3 \
  -e CONFIG_NFSD_V3_ACL \
  -e CONFIG_NFSD_V4 \
  -d CONFIG_RPCSEC_GSS_KRB5

# MSM-only wireless drivers are configured in the MSM gki_defconfig, matching
# nullptr's module action. They must not be merged into common GKI: cfg80211
# and mac80211 are MSM-side modules for Creek.
MSM_GKI_DEFCONFIG="$MSM/arch/arm64/configs/gki_defconfig"
if [ ! -x "$MSM/scripts/config" ]; then
  echo "ERROR: scripts/config not found or not executable in MSM source" >&2
  exit 1
fi
if [ ! -f "$MSM_GKI_DEFCONFIG" ]; then
  echo "ERROR: MSM gki_defconfig not found: $MSM_GKI_DEFCONFIG" >&2
  exit 1
fi
MSM_CFG="$MSM/scripts/config --file $MSM_GKI_DEFCONFIG"

# Match nullptr's MSM module action: write these settings to the MSM primary
# gki_defconfig, never to vendor/creek_GKI.config. CFG80211/MAC80211 remain
# modules; MAC80211_LEDS and RC_MINSTREL are boolean features and are y.
$MSM_CFG \
  --keep-case \
  -m CONFIG_MAC80211 \
  -e CONFIG_WLAN_VENDOR_REALTEK \
  -e CONFIG_WLAN_VENDOR_MEDIATEK \
  -e CONFIG_MAC80211_LEDS \
  -e CONFIG_MAC80211_RC_MINSTREL \
  -m CONFIG_CAN_SLCAN \
  -m CONFIG_MT7601U \
  -m CONFIG_MT76x0U \
  -m CONFIG_MT76x2U \
  -m CONFIG_MT7603E \
  -m CONFIG_MT7615E \
  -m CONFIG_MT7663U \
  -m CONFIG_MT7915E \
  -m CONFIG_MT7921E

# Keep the common GKI defconfig untouched. Its NetHunter fragment is merged
# by the inner GKI build; MSM module settings above belong to MSM gki_defconfig.
VENDOR_BUILD_CONFIG="$MSM/build.config.msm.creek"
if [ ! -f "$VENDOR_BUILD_CONFIG" ]; then
  echo "ERROR: Creek vendor build config not found: $VENDOR_BUILD_CONFIG" >&2
  exit 1
fi

# VARIANT=gki makes the vendor build invoke a second, inner GKI build through
# GKI_BUILD_CONFIG. The fragment must be added to that inner config, not to
# the vendor/MSM config.
GKI_CONFIG_REF=$(sed -n 's/^[[:space:]]*GKI_BUILD_CONFIG[[:space:]]*=[[:space:]]*//p' "$VENDOR_BUILD_CONFIG" | tail -n1 | tr -d '"' | tr -d "'" | xargs || true)
if [ -n "$GKI_CONFIG_REF" ] && [ -f "$ROOT/$GKI_CONFIG_REF" ]; then
  GKI_BUILD_CONFIG_FILE="$ROOT/$GKI_CONFIG_REF"
elif [ -n "$GKI_CONFIG_REF" ] && [ -f "$COMMON/$GKI_CONFIG_REF" ]; then
  GKI_BUILD_CONFIG_FILE="$COMMON/$GKI_CONFIG_REF"
else
  GKI_BUILD_CONFIG_FILE=$(find "$COMMON" -maxdepth 1 -type f -name 'build.config.gki*' | sort | head -n1)
fi
if [ -z "${GKI_BUILD_CONFIG_FILE:-}" ] || [ ! -f "$GKI_BUILD_CONFIG_FILE" ]; then
  echo "ERROR: unable to locate inner GKI build config" >&2
  exit 1
fi

# Keep DEFCONFIG as a single filename: Creek's check_defconfig treats the
# value as a path. Run the stock check first, then merge our fragment before
# compilation through POST_DEFCONFIG_CMDS.
sed -i '/^[[:space:]]*DEFCONFIG=/d' "$GKI_BUILD_CONFIG_FILE"
sed -i '/^[[:space:]]*POST_DEFCONFIG_CMDS=/d' "$GKI_BUILD_CONFIG_FILE"
cat >> "$GKI_BUILD_CONFIG_FILE" <<'EOF_GKI_NETHUNTER'

DEFCONFIG="gki_defconfig"
merge_nethunter_config() {
  echo "[nethunter] merging nethunter.config after check_defconfig"
  (cd "${KERNEL_DIR}" && make "${TOOL_ARGS[@]}" O="${OUT_DIR}" "${MAKE_ARGS[@]}" nethunter.config)
}
POST_DEFCONFIG_CMDS="check_defconfig; merge_nethunter_config"
EOF_GKI_NETHUNTER
echo "[nethunter] inner GKI config: $GKI_BUILD_CONFIG_FILE"
echo "[nethunter] using config fragment: $NETHUNTER_CONFIG"

# Helpful build snapshots.
mkdir -p "$ROOT/nethunter-debug"
{
  echo "# Creek NetHunter config additions"
  grep -E 'CONFIG_(BBG|TCP_CONG_BBR3|DEFAULT_BBR3|DEFAULT_TCP_CONG|SYSVIPC|PID_NS|USER_NS|POSIX_MQUEUE|NFS|NFSD|USB_AIRSPY|USB_HACKRF|IP_SET|NET_SCH_CAKE|NET_SCH_PIE|NET_SCH_FQ_PIE)=' "$NETHUNTER_CONFIG" || true
} > "$ROOT/nethunter-debug/nethunter-config-summary.txt"

echo "[nethunter] Creek NetHunter common patches/configs enabled"
