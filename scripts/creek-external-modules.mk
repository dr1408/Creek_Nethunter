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
DATA := $(KP)/vendor/qcom/opensource/data-kernel/drivers/emac-dwc-eqos

WLAN_PLATFORM_SYMVERS := $(WLAN_PLATFORM)/Module.symvers
DISPLAY_SYMVERS := $(O)/../vendor/qcom/opensource/display-drivers/Module.symvers
# KBUILD_MIXED_TREE already supplies GKI vmlinux.symvers, while the vendor
# kernel build supplies its own Module.symvers. Passing either base file again
# through KBUILD_EXTRA_SYMBOLS causes duplicate exports during modpost.
COMMON_ARGS := ARCH=arm64 LLVM=1 KERNEL_SRC=$(VENDOR_KERNEL_SRC) O=$(O) KBUILD_MIXED_TREE=$(KBUILD_MIXED_TREE)


.PHONY: all wlan-platform wlan-qcacld display camera audio data external-dt
# Every external module re-enters the same msm-kernel O= directory. Parallel
# recursive Kbuild invocations race while generating shared kernel files.
.NOTPARALLEL: all wlan-platform wlan-qcacld display camera audio data external-dt
all: wlan-platform wlan-qcacld display camera audio data external-dt

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
	$(call build_module,wlan platform,$(WLAN_PLATFORM),../vendor/qcom/opensource/wlan/platform,USE_EXTERNAL_CONFIGS=1 CONFIG_CNSS_OUT_OF_TREE=y CONFIG_ICNSS2=m CONFIG_ICNSS2_QMI=y CONFIG_CNSS_QMI_SVC=m CONFIG_CNSS_GENL=m CONFIG_WCNSS_MEM_PRE_ALLOC=m CONFIG_CNSS_UTILS=m,vendor/qcom/opensource/wlan/platform)

wlan-qcacld:
	$(call build_module,qcacld-3.0,$(WLAN_QCACLD),../vendor/qcom/opensource/wlan/qcacld-3.0,WLAN_CHIPSET=qca_cld3 WLAN_PROFILE=blair_gki_wlan KBUILD_EXTRA_SYMBOLS='$(WLAN_PLATFORM_SYMVERS)',vendor/qcom/opensource/wlan/qcacld-3.0)

display:
	$(call build_module,display,$(DISPLAY),../vendor/qcom/opensource/display-drivers,MODNAME=msm_drm BOARD_PLATFORM=bengal,vendor/qcom/opensource/display-drivers)

camera:
	$(call build_module,camera,$(CAMERA),../vendor/qcom/opensource/camera-kernel,MODNAME=camera BOARD_PLATFORM=bengal CAMERA_KERNEL_ROOT=$(CAMERA) KERNEL_ROOT=$(KERNEL_SRC),vendor/qcom/opensource/camera-kernel)

audio:
	$(call build_module,audio,$(AUDIO),../vendor/qcom/opensource/audio-kernel,MODNAME=audio_dlkm BOARD_PLATFORM=bengal TARGET_SUPPORT=bengal AUDIO_ROOT=$(AUDIO) CONFIG_SND_SOC_BENGAL=m,vendor/qcom/opensource/audio-kernel)

data:
	@if [ -f "$(DATA)/Makefile" ]; then \
		$(MAKE) -C "$(DATA)" M=../vendor/qcom/opensource/data-kernel/drivers/emac-dwc-eqos $(COMMON_ARGS) modules; \
		$(MAKE) -C "$(DATA)" M=../vendor/qcom/opensource/data-kernel/drivers/emac-dwc-eqos $(COMMON_ARGS) INSTALL_MOD_PATH=$(INSTALL_MOD_PATH) INSTALL_MOD_DIR=extra/vendor/qcom/opensource/data-kernel modules_install; \
	else \
		echo "[creek] data-kernel emac module is not present; skipping"; \
	fi

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
