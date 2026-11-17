import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT/'scripts/creek-wlan-baseline.py'

class Baseline(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.builder = self.root/'builder'
        self.kernel = self.builder/'work/kernel_platform/msm-kernel'
        self.kernel.mkdir(parents=True)
        for repo in (self.builder, self.kernel):
            subprocess.run(['git','init','-q',str(repo)],check=True)
            (repo/'tracked').write_text('original')
            subprocess.run(['git','-C',str(repo),'add','tracked'],check=True)
            subprocess.run(['git','-C',str(repo),'-c','user.name=Test',
                            '-c','user.email=test@example.invalid','commit','-qm','initial'],check=True)
        self.out=self.builder/'out'
        for rel in ('msm-kernel/.config','msm-kernel/Module.symvers',
                    'msm-kernel/include/generated/autoconf.h',
                    'msm-kernel/scripts/mod/modpost','gki_kernel/dist/vmlinux.symvers',
                    'msm-kernel/test.o','msm-kernel/test.a','host/bin/tool',
                    'msm-kernel/net/wireless/cfg80211.ko'):
            p=self.out/rel
            p.parent.mkdir(parents=True,exist_ok=True)
            p.write_text(rel)
        tools=self.root/'tools'
        tools.mkdir()
        repo=tools/'repo'
        repo.write_text('#!/bin/sh\nprintf "%s\\n" kernel_platform/msm-kernel kernel_platform/vendor/qcom/opensource/wlan\n')
        repo.chmod(0o755)
        self.env=dict(os.environ,PATH=str(tools)+':'+os.environ['PATH'],
                      GITHUB_TOKEN='must-not-save-this')
        self.baseline=self.builder/'baseline'

    def run_script(self,action,ok=True):
        result=subprocess.run(['python3',str(SCRIPT),action,'--work',str(self.builder/'work'),
                               '--out',str(self.out),'--builder',str(self.builder),
                               '--baseline',str(self.baseline)],env=self.env,
                              text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        if ok:
            self.assertEqual(result.returncode,0,result.stderr)
        else:
            self.assertNotEqual(result.returncode,0)
        return result

    def test_snapshot_and_provenance(self):
        self.run_script('save')
        with tarfile.open(self.baseline/'prepared-out.tar') as archive:
            names=archive.getnames()
            self.assertIn('msm-kernel/Module.symvers',names)
            self.assertIn('host/bin/tool',names)
            self.assertIn('msm-kernel/net/wireless/cfg80211.ko',names)
            self.assertNotIn('msm-kernel/test.o',names)
            self.assertNotIn('msm-kernel/test.a',names)
        self.assertNotIn('must-not-save-this',(self.baseline/'build-env.sh').read_text())
        metadata=json.loads((self.baseline/'metadata.json').read_text())
        self.assertNotIn('kernel_platform/vendor/qcom/opensource/wlan',metadata['sources'])
        self.run_script('verify')
        (self.kernel/'tracked').write_text('changed ABI')
        self.assertIn('Baseline mismatch',self.run_script('verify',False).stderr)

    def test_incomplete_baseline_is_rejected(self):
        (self.out/'msm-kernel/Module.symvers').unlink()
        self.run_script('save',False)
        self.assertFalse((self.baseline/'metadata.json').exists())

    def test_missing_prepared_file_rejected_on_restore(self):
        self.run_script('save')
        (self.out/'msm-kernel/scripts/mod/modpost').unlink()
        self.assertIn('Incomplete baseline',self.run_script('verify',False).stderr)

if __name__=='__main__':
    unittest.main()
