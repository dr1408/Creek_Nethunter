#!/usr/bin/env python3
"""Save/validate a prepared mixed-tree WLAN build baseline."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess

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
    paths = subprocess.check_output(['repo', 'list', '-p'], cwd=work, text=True).splitlines()
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

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['save', 'verify'])
    parser.add_argument('--work', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--builder', type=Path, required=True)
    parser.add_argument('--baseline', type=Path, required=True)
    args = parser.parse_args()
    metadata = inventory(args.work, args.builder)
    directory = args.baseline
    if args.action == 'verify':
        expected = json.loads((directory / 'metadata.json').read_text())
        if metadata != expected:
            raise SystemExit('Baseline mismatch: builder, kernel/toolchain revision, source patches '
                             'or workspace changed. Run a new full baseline build.')
        for rel in ('msm-kernel/.config', 'msm-kernel/Module.symvers',
                    'msm-kernel/include/generated/autoconf.h',
                    'msm-kernel/scripts/mod/modpost',
                    'gki_kernel/dist/vmlinux.symvers'):
            if not (args.out / rel).is_file():
                raise SystemExit('Incomplete baseline: ' + rel)
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
    (directory / 'metadata.json').write_text(json.dumps(metadata, indent=2) + '\n')
    # Never export the full runner environment (it can contain credentials).
    (directory / 'build-env.sh').write_text('\n'.join(
        f'export {key}={shlex.quote(os.environ[key])}' for key in ENV_KEYS if key in os.environ
    ) + '\n')
    print('Prepared WLAN baseline saved before external WLAN compilation.')

if __name__ == '__main__':
    main()
