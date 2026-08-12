# Creek_Nethunter

GitHub Actions builder for the Redmi/Xiaomi Creek stock GKI mixed build.

It uses:

- Google GKI `common` for the kernel image and GKI/system_dlkm modules.
- Xiaomi `msm-kernel` as the vendor/device kernel for external modules.
- Xiaomi Creek device-tree and QCOM vendor module sources.
- The stock Creek vendor_boot module lists captured from the device.
- The qcacld monitor-mode/frame-injection port, applied after source sync.

The workflow builds `boot.img`, `vendor_boot.img`, `vendor_dlkm.img`,
`system_dlkm.img`, DTB/DTBO outputs, and all Xiaomi external modules. It also
runs a placement check and uploads the build log and module-placement report.

The stock module lists are under `stock-modules/`. Modules selected by the
vendor_boot lists are staged for first-stage loading; remaining built modules
are placed in vendor_dlkm by the Xiaomi build system. A stock vendor_boot
image itself is not committed to this repository.

## Modules not available from the current sources

The following stock Xiaomi modules are currently missing from the build because
their matching vendor source is not available in this tree.

Normal `vendor_boot`:

```text
bootinfo.ko
mi_memory.ko
mi_thermal_interface.ko
qrng_dlkm.ko
qseecom_dlkm.ko
swinfo.ko
```

Recovery `vendor_boot`:

```text
bootinfo.ko
hdcp_qseecom_dlkm.ko
lct_tp.ko
mi_memory.ko
mi_thermal_interface.ko
msm-mmrm.ko
msm_drm.ko
qseecom_dlkm.ko
smcinvoke_dlkm.ko
swinfo.ko
```

Additional `vendor_dlkm` modules not currently built:

```text
ipam.ko
ipanetm.ko
ipa_clientsm.ko
rndisipam.ko
rmnet_core.ko
rmnet_ctl.ko
rmnet_wlan.ko
```

`icnss2.ko` and the CNSS modules are built from the available source and are
not part of this missing-module list.
