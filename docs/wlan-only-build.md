# Faster WLAN iterations on GitHub Actions

## Create the baseline once

Run **Build Creek Stock Kernel** from this builder revision. Immediately before
external WLAN compilation it saves prepared MSM/GKI outputs and a restricted
build-tool environment. The workflow uploads **creek-wlan-baseline** even if a
subsequent QCACLD compile fails. A failure before kernel preparation cannot
produce a usable baseline.

Copy the numeric run ID from its URL, for example the number following
`/actions/runs/`. Baseline artifacts expire after 14 days.

## Subsequent driver builds

Run **Build Creek WLAN Only** on the same builder commit:

- **baseline_run_id:** the full-build run containing that artifact.
- **rebuild_cfg80211:** leave false for normal QCACLD/OL/WMA changes.
- **jobs:** auto, or a positive integer.

This syncs sources, restores the prepared outputs, verifies provenance, and
builds WLAN platform dependencies plus QCACLD only. It does not invoke the full
kernel/image, audio, display or camera build. Source sync and artifact transfer
still take time; no particular runtime is guaranteed.

Download **creek-wlan-only**. It contains `qca_cld3_wlan.ko`, platform modules,
`cfg80211.ko`, logs and revision/checksum provenance. With the cfg80211 option
off, cfg80211 is copied unchanged from the baseline; with it on, that wireless
core directory is compiled as a module against the same prepared tree.

Use the modules only with the kernel corresponding to the baseline. This is
not an ABI compatibility bypass, nor an installer/reloader.

## Compatibility and recovery

The verifier requires identical builder commit, workspace path, non-WLAN
repository revisions and tracked source patches. The whole WLAN repository is
allowed to change because the platform dependencies are also rebuilt.
Kernel/toolchain/build configuration changes require a fresh baseline.
The script rejects incomplete prepared trees. Module symbol/version checking
remains enabled.

Outputs are stored as a separate artifact, not an opportunistic Actions cache.
The ordinary Clean output option does not restore prior runs. Cancelling or
timing out a runner can prevent artifact upload; ordinary driver compile
failures are covered by the always-upload step.

Validation:
```sh
python3 -m unittest discover -s tests -p test_wlan_baseline.py -v
bash -n scripts/build-creek-wlan-only.sh
actionlint -shellcheck= .github/workflows/build-creek-stock.yml .github/workflows/build-creek-wlan-only.yml
```

These are host/fixture and workflow checks, not a completed target build.
