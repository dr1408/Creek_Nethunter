#!/usr/bin/env python3
"""Save/validate a prepared mixed-tree WLAN build baseline."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import copy

ENV_KEYS = (
    'PATH', 'LD_LIBRARY_PATH', 'ARCH', 'SUBARCH', 'LLVM', 'LLVM_IAS',
    'CC', 'LD', 'AR', 'NM', 'OBJCOPY', 'OBJDUMP', 'READELF', 'STRIP',
    'HOSTCC', 'HOSTCXX', 'HOSTAR', 'HOSTLD', 'CROSS_COMPILE',
    'CROSS_COMPILE_COMPAT', 'CLANG_TRIPLE', 'KBUILD_BUILD_USER',
    'KBUILD_BUILD_HOST', 'KBUILD_BUILD_TIMESTAMP', 'SOURCE_DATE_EPOCH',
    'DTC', 'HOSTCFLAGS', 'HOSTCXXFLAGS', 'HOSTLDFLAGS',
)

def git(root, *args):
    return subprocess.check_output(['git', '-C', str(root), *args], text=True).strip()

def inventory(work, builder):
    # repo's own persisted project list avoids invoking the repo launcher under
    # build.sh's hermetic PATH (which deliberately excludes $HOME/bin).
    paths = (work / '.repo/project.list').read_text().splitlines()
    result = {}
    for rel in paths:
        # All WLAN sources may change: platform modules are rebuilt too.
        if rel == 'kernel_platform/vendor/qcom/opensource/wlan':
            continue
        root = work / rel
        diff = subprocess.check_output(['git', '-C', str(root), 'diff', '--binary', 'HEAD'])
        result[rel] = {'revision': git(root, 'rev-parse', 'HEAD'),
                       'patch_sha256': hashlib.sha256(diff).hexdigest()}
    return {'schema': 1, 'builder': git(builder, 'rev-parse', 'HEAD'),
            'workspace': str(builder.resolve()), 'sources': result}

LEGACY_BUILDER = '5dcb097a99f240b6ab3a814c73de92610639c6d3'
MSM_PROJECT = 'kernel_platform/msm-kernel'

def legacy_channel_compatible(actual, expected, work, patch):
    """Compare a virtual index with the old channel patch reapplied.
    No worktree/index files belonging to the source checkout are changed.
    This exception cannot admit any other kernel/config/toolchain difference.
    """
    if expected.get('builder') != LEGACY_BUILDER or patch is None:
        return False
    candidate = copy.deepcopy(actual)
    candidate['builder'] = expected['builder']
    try:
        with tempfile.TemporaryDirectory() as temp:
            env = dict(os.environ, GIT_INDEX_FILE=str(Path(temp) / 'index'))
            root = work / MSM_PROJECT
            prefix = ['git', '-C', str(root)]
            subprocess.run(prefix + ['read-tree', 'HEAD'], env=env,
                           check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            subprocess.run(prefix + ['add', '-u', '--', '.'], env=env,
                           check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            subprocess.run(prefix + ['apply', '--cached', str(patch.resolve())],
                           env=env, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            diff = subprocess.check_output(prefix + ['diff', '--cached', '--binary', 'HEAD'],
                                           env=env)
            candidate['sources'][MSM_PROJECT]['patch_sha256'] = hashlib.sha256(diff).hexdigest()
    except (subprocess.CalledProcessError, KeyError):
        return False
    return candidate == expected


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['save', 'verify'])
    parser.add_argument('--work', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--builder', type=Path, required=True)
    parser.add_argument('--baseline', type=Path, required=True)
    parser.add_argument('--allow-pre-reset-baseline', action='store_true')
    args = parser.parse_args()
    directory = args.baseline
    if args.action == 'save':
        directory.mkdir(parents=True, exist_ok=True)
        # Capture the kernel-stage tool environment before any fallible work.
        # A later workflow retry must NOT replace it with the runner's PATH.
        env_file = directory / 'build-env.sh'
        if not env_file.exists():
            env_file.write_text('\n'.join(
                f'export {key}={shlex.quote(os.environ[key])}'
                for key in ENV_KEYS if key in os.environ
            ) + '\n')
    metadata = inventory(args.work, args.builder)
    if args.action == 'verify':
        expected = json.loads((directory / 'metadata.json').read_text())
        marker = directory / 'requires-cfg80211-rebuild'
        marker.unlink(missing_ok=True)
        legacy = False
        if metadata != expected:
            patch = args.builder / 'scripts/baseline-compat/legacy-cfg80211-channel.patch'
            legacy = args.allow_pre_reset_baseline and legacy_channel_compatible(
                metadata, expected, args.work, patch)
            if not legacy:
                raise SystemExit('Baseline mismatch: kernel/toolchain, patches, builder or workspace '
                                 'changed beyond the supported channel-patch removal.')

        for rel in ('msm-kernel/.config', 'msm-kernel/Module.symvers',
                    'msm-kernel/include/generated/autoconf.h',
                    'msm-kernel/scripts/mod/modpost',
                    'gki_kernel/dist/vmlinux.symvers'):
            if not (args.out / rel).is_file():
                raise SystemExit('Incomplete baseline: ' + rel)
        if legacy:
            marker.write_text('Baseline included the reverted channel patch. Rebuild cfg80211.\n')
            print('Verified old baseline: ONLY the known cfg80211 patch was removed; '
                  'cfg80211 rebuild is mandatory.')
        print('Baseline source/config provenance verified.')
        return
    # Snapshot at external-WLAN entry, after kernel preparation, before QCACLD.
    for rel in ('msm-kernel/Module.symvers', 'msm-kernel/.config',
                'msm-kernel/include/generated/autoconf.h',
                'msm-kernel/scripts/mod/modpost', 'gki_kernel/dist/vmlinux.symvers'):
        if not (args.out / rel).is_file():
            raise SystemExit('Cannot save an incomplete baseline: ' + rel)
    directory.mkdir(parents=True, exist_ok=True)
    archive = directory / 'prepared-out.tar'
    temporary = directory / 'prepared-out.tar.partial'
    paths = ['msm-kernel', 'gki_kernel/dist']
    # build.sh may place host tools outside the kernel O= directory.
    paths += [p for p in ('host', 'host_tools', '.path', 'gki_kernel/host',
                          'gki_kernel/host_tools') if (args.out / p).exists()]
    subprocess.run(['tar', '-C', str(args.out), '--exclude=*.o', '--exclude=*.a',
                    '-cf', str(temporary), *paths], check=True)
    temporary.replace(archive)
    # Publish the completeness marker last, after a successful archive.
    (directory / 'metadata.json').write_text(json.dumps(metadata, indent=2) + '\n')
    print('Prepared WLAN baseline saved before external WLAN compilation.')

if __name__ == '__main__':
    main()
