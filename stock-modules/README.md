# Stock Creek module lists

Captured from a rooted Redmi Creek device via ADB on 2026-08-07.

- Device: `creek`
- Android: `15`
- Kernel: `5.15.167-android13-8-gbf0a81a7f319`
- `vendor_dlkm.modules.load`: `/vendor_dlkm/lib/modules/modules.load`
- `vendor_dlkm.modules.blocklist`: `/vendor_dlkm/lib/modules/modules.blocklist`
- `system_dlkm.modules.load`: `/system_dlkm/lib/modules/5.15.167/modules.load`

## Stock vendor_boot module lists

Extracted from the rooted device's `vendor_boot_a` (Android 15, kernel 5.15.167-android13-8-gbf0a81a7f319):

- `vendor_boot.modules.load`: normal vendor ramdisk modules (`lib/modules/modules.load`)
- `vendor_boot.modules.load.recovery`: recovery vendor ramdisk modules (`lib/modules/modules.load.recovery`)
- `vendor_boot.ramdisk.lz4`: stock vendor ramdisk base used when rebuilding `vendor_boot.img`
- `vendor_boot.cmdline`: stock vendor_boot command line

The vendor_boot image is not committed; only its exact module lists are retained.
