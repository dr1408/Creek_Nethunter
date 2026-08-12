# Xiaomi Creek external-module stage. build.sh supplies KERNEL_SRC, O,
# INSTALL_MOD_PATH and KBUILD_MIXED_TREE.

SHELL := /bin/bash
KERNEL_SRC ?= $(error KERNEL_SRC is required)
O ?= $(error O is required)
INSTALL_MOD_PATH ?= $(error INSTALL_MOD_PATH is required)
KBUILD_MIXED_TREE ?=
CREEK_DIST_DIR ?= $(abspath $(O)/../../dist)

# build.sh may invoke this makefile while KERNEL_SRC still points at common.
# External vendor modules must use Xiaomi's msm-kernel as the source and the
# GKI output through KBUILD_MIXED_TREE.
VENDOR_KERNEL_SRC := $(if $(findstring /msm-kernel,$(KERNEL_SRC)),$(KERNEL_SRC),$(abspath $(KERNEL_SRC)/../msm-kernel))
KP := $(abspath $(VENDOR_KERNEL_SRC)/..)
WLAN_PLATFORM := $(KP)/vendor/qcom/opensource/wlan/platform
WLAN_QCACLD := $(KP)/vendor/qcom/opensource/wlan/qcacld-3.0
DISPLAY := $(KP)/vendor/qcom/opensource/display-drivers
CAMERA := $(KP)/vendor/qcom/opensource/camera-kernel
AUDIO := $(KP)/vendor/qcom/opensource/audio-kernel
NETHUNTER_DIR := $(KP)/nethunter-external
RTW88 := $(NETHUNTER_DIR)/rtw88
RTL8XXXU := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../rtl)

WLAN_PLATFORM_SYMVERS := $(WLAN_PLATFORM)/Module.symvers
DISPLAY_SYMVERS := $(O)/../vendor/qcom/opensource/display-drivers/Module.symvers
# KBUILD_MIXED_TREE supplies the common GKI vmlinux symbols to this
# vendor build. Do not pass vmlinux.symvers again: older Creek Kbuild then
# sees every built-in export twice during modpost.
COMMON_ARGS := ARCH=arm64 LLVM=1 KERNEL_SRC=$(VENDOR_KERNEL_SRC) O=$(O) KBUILD_MIXED_TREE=$(KBUILD_MIXED_TREE)

# MiCode's blair GKI build passes this complete platform configuration to
# both the platform modules and QCACLD through WLAN_PLATFORM_KBUILD_OPTIONS.
# Keep one source here so the two independent wrapper invocations cannot
# select different ICNSS2/SNOC configurations.
WLAN_PROFILE := blair_gki_wlan
WLAN_PLATFORM_KCONFIG := CONFIG_CNSS_OUT_OF_TREE=y CONFIG_ICNSS2=m CONFIG_ICNSS2_QMI=y CONFIG_CNSS_QMI_SVC=m CONFIG_CNSS_GENL=m CONFIG_WCNSS_MEM_PRE_ALLOC=m CONFIG_CNSS_UTILS=m
# Bazel force-includes config_to_feature.h, which maps CONFIG_* options from
# blair_gki_wlan_defconfig to the legacy feature macros used by QCACLD code.
# Standalone Kbuild does not include that file globally, so add it through
# KCFLAGS and bridge only the object-selection variables Kbuild cannot infer.
WLAN_QCACLD_KCONFIG := CONFIG_IPA_WDI_UNIFIED_API=y CONFIG_REMOVE_PKT_LOG=n CONFIG_PKT_LOG=y CONFIG_PKTLOG_LEGACY=y CONFIG_NL80211_TESTMODE=y CONFIG_WLAN_DEBUGFS=y CONFIG_QCA_WIFI_FTM=y CONFIG_QCA_WIFI_FTM_NL80211=y CONFIG_CFG80211_SINGLE_NETDEV_MULTI_LINK_SUPPORT=y CONFIG_CFG80211_RU_PUNCT_NOTIFY=y QCA_WIFI_FTM_NL80211=y WLAN_OPEN_SOURCE=y BUILD_DEBUG_VERSION=y BUILD_DIAG_VERSION=y
WLAN_QCACLD_KCFLAGS := KCFLAGS=-Wno-macro-redefined\ -DCFG80211_SINGLE_NETDEV_MULTI_LINK_SUPPORT=1\ -DCONFIG_IPA_WDI_UNIFIED_API=1\ -include\ $(WLAN_QCACLD)/configs/default_config.h\ -include\ $(WLAN_QCACLD)/configs/creek_blair_gki_autoconf.h\ -include\ $(WLAN_QCACLD)/configs/config_to_feature.h


.PHONY: all wlan-platform wlan-qcacld display camera audio rtw88 rtl8xxxu external-dt
# Every external module re-enters the same msm-kernel O= directory. Parallel
# recursive Kbuild invocations race while generating shared kernel files.
.NOTPARALLEL: all wlan-platform wlan-qcacld display camera audio rtw88 rtl8xxxu external-dt
all: wlan-platform wlan-qcacld display camera audio rtw88 rtl8xxxu external-dt

wlan-qcacld: wlan-platform

define build_module
	@echo "[creek] building $(1)"
	# Use Xiaomi's wrapper Makefile so it supplies WLAN_ROOT,
	# WLAN_PLATFORM_ROOT, DISPLAY_ROOT, and AUDIO_ROOT correctly.
	# Enter the module directory before invoking its wrapper. Xiaomi's wrappers
	# use PWD when deriving M, so make -C would leave PWD pointing at KP.
	cd $(2) && $(if $(6),export $(6);,) $(MAKE) M=$(2) $(COMMON_ARGS) $(4) all
	cd $(2) && $(if $(6),export $(6);,) $(MAKE) M=$(2) $(COMMON_ARGS) $(4) INSTALL_MOD_PATH=$(INSTALL_MOD_PATH) INSTALL_MOD_DIR=extra/$(5) modules_install
endef

wlan-platform:
	$(call build_module,wlan platform,$(WLAN_PLATFORM),../vendor/qcom/opensource/wlan/platform,USE_EXTERNAL_CONFIGS=1 $(WLAN_PLATFORM_KCONFIG),vendor/qcom/opensource/wlan/platform)

wlan-qcacld:
	$(call build_module,qcacld-3.0,$(WLAN_QCACLD),../vendor/qcom/opensource/wlan/qcacld-3.0,WLAN_CHIPSET=qca_cld3 MODNAME=wlan DEVNAME=wlan WLAN_CTRL_NAME=wlan $(WLAN_QCACLD_KCFLAGS) KBUILD_EXTRA='WLAN_PROFILE=$(WLAN_PROFILE) MODNAME=wlan DEVNAME=wlan WLAN_CTRL_NAME=wlan $(WLAN_PLATFORM_KCONFIG) $(WLAN_QCACLD_KCONFIG)' KBUILD_EXTRA_SYMBOLS='$(WLAN_PLATFORM_SYMVERS)',vendor/qcom/opensource/wlan/qcacld-3.0)
	@echo "[creek] normalizing qcacld filename to stock qca_cld3_wlan.ko"
	@set -e; \
	for ko in $$(find "$(INSTALL_MOD_PATH)/lib/modules" -type f -path '*/extra/vendor/qcom/opensource/wlan/qcacld-3.0/wlan.ko' 2>/dev/null); do \
		mv -f "$$ko" "$${ko%/wlan.ko}/qca_cld3_wlan.ko"; \
	done; \
	find "$(INSTALL_MOD_PATH)/lib/modules" -type f -name 'modules.order*' -exec sed -i \
		-e 's#extra/vendor/qcom/opensource/wlan/qcacld-3.0/wlan\.ko#extra/vendor/qcom/opensource/wlan/qcacld-3.0/qca_cld3_wlan.ko#g' \
		-e 's#vendor/qcom/opensource/wlan/qcacld-3.0/wlan\.ko#vendor/qcom/opensource/wlan/qcacld-3.0/qca_cld3_wlan.ko#g' {} + 2>/dev/null || true; \
	for kdir in "$(INSTALL_MOD_PATH)"/lib/modules/*; do \
		[ -d "$$kdir" ] || continue; \
		depmod -b "$(INSTALL_MOD_PATH)" "$$(basename "$$kdir")"; \
	done

display:
	$(call build_module,display,$(DISPLAY),../vendor/qcom/opensource/display-drivers,MODNAME=msm_drm BOARD_PLATFORM=bengal,vendor/qcom/opensource/display-drivers)

camera:
	$(call build_module,camera,$(CAMERA),../vendor/qcom/opensource/camera-kernel,MODNAME=camera BOARD_PLATFORM=bengal CAMERA_KERNEL_ROOT=$(CAMERA) KERNEL_ROOT=$(KERNEL_SRC),vendor/qcom/opensource/camera-kernel)

audio:
	$(call build_module,audio,$(AUDIO),../vendor/qcom/opensource/audio-kernel,MODNAME=audio_dlkm BOARD_PLATFORM=bengal TARGET_SUPPORT=bengal AUDIO_ROOT=$(AUDIO) CONFIG_SND_SOC_BENGAL=m,vendor/qcom/opensource/audio-kernel)

rtw88:
	@if [ ! -d "$(RTW88)" ]; then \
		echo "[creek] cloning rtw88"; \
		mkdir -p "$(NETHUNTER_DIR)"; \
		git clone --depth=1 https://github.com/lwfinger/rtw88.git "$(RTW88)"; \
	fi
	@echo "[creek] building NetHunter rtw88"
	cd $(RTW88) && $(MAKE) KSRC=$(VENDOR_KERNEL_SRC) KERNEL_SRC=$(VENDOR_KERNEL_SRC) ARCH=arm64 LLVM=1 O=$(O) KBUILD_MIXED_TREE=$(KBUILD_MIXED_TREE) all
	@set -e; \
		for kdir in "$(INSTALL_MOD_PATH)"/lib/modules/*; do \
			[ -d "$$kdir" ] || continue; \
			dest="$$kdir/extra/nethunter/rtw88"; \
			mkdir -p "$$dest"; \
			cp -f $(RTW88)/*.ko "$$dest/"; \
			find "$$dest" -maxdepth 1 -type f -name '*.ko' -printf 'extra/nethunter/rtw88/%f\n' >> "$$kdir/modules.order"; \
			awk '!seen[$$0]++' "$$kdir/modules.order" > "$$kdir/modules.order.tmp" && mv "$$kdir/modules.order.tmp" "$$kdir/modules.order"; \
			depmod -b "$(INSTALL_MOD_PATH)" "$$(basename "$$kdir")"; \
		done

rtl8xxxu:
	@test -f "$(RTL8XXXU)/rtl8188eufw_fw.h" || { echo "[creek] missing embedded RTL8188EUS firmware header" >&2; exit 1; }
	@echo "[creek] building GKI rtl8xxxu (embedded RTL8188EUS firmware)"
	$(MAKE) -C $(VENDOR_KERNEL_SRC) M=$(RTL8XXXU) $(COMMON_ARGS) modules
	$(MAKE) -C $(VENDOR_KERNEL_SRC) M=$(RTL8XXXU) $(COMMON_ARGS) INSTALL_MOD_PATH=$(INSTALL_MOD_PATH) INSTALL_MOD_DIR=extra/nethunter/rtl8xxxu modules_install
	@set -e; \
	for kdir in "$(INSTALL_MOD_PATH)"/lib/modules/*; do \
		[ -d "$$kdir" ] || continue; \
		depmod -b "$(INSTALL_MOD_PATH)" "$$(basename "$$kdir")"; \
	done

# Auxiliary camera/display DT repositories are built when their Makefile
# supports the standard external dtbs target. The kernel DT tree remains the
# authoritative stock DT source.
external-dt:
	@for d in "$(KP)/vendor/qcom/proprietary/camera-devicetree" "$(KP)/vendor/qcom/proprietary/display-devicetree"; do \
		if [ -f "$$d/Makefile" ]; then \
			echo "[creek] building external DTs: $$d"; \
			$(MAKE) -C "$$d" $(COMMON_ARGS) dtbs || echo "[creek] external DT target unavailable: $$d"; \
			find "$(O)" -type f \( -name '*.dtb' -o -name '*.dtbo' \) -exec cp -f {} "$(CREEK_DIST_DIR)/" \; 2>/dev/null || true; \
		fi; \
	done
