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
        project_list=self.builder/'work/.repo/project.list'
        project_list.parent.mkdir()
        project_list.write_text('kernel_platform/msm-kernel\n'
                                'kernel_platform/vendor/qcom/opensource/wlan\n')
        self.env=dict(os.environ, GITHUB_TOKEN='must-not-save-this')
        self.baseline=self.builder/'baseline'

    def run_script(self,action,ok=True,extra=()):
        result=subprocess.run(['python3',str(SCRIPT),action,'--work',str(self.builder/'work'),
                               '--out',str(self.out),'--builder',str(self.builder),
                               '--baseline',str(self.baseline),*extra],env=self.env,
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

    def test_retry_preserves_kernel_environment_without_repo_on_path(self):
        self.run_script('save')
        before=(self.baseline/'build-env.sh').read_text()
        self.env['CC']='different-workflow-compiler'
        self.run_script('save')
        self.assertEqual(before,(self.baseline/'build-env.sh').read_text())

    def test_known_pre_reset_baseline_requires_cfg_rebuild(self):
        tracked=self.kernel/'tracked'
        tracked.write_text('legacy channel change')
        patch=subprocess.check_output(['git','-C',str(self.kernel),'diff','--binary','HEAD'])
        compat=self.builder/'scripts/baseline-compat/legacy-cfg80211-channel.patch'
        compat.parent.mkdir(parents=True)
        compat.write_bytes(patch)
        self.run_script('save')
        meta=self.baseline/'metadata.json'
        data=json.loads(meta.read_text())
        data['builder']='5dcb097a99f240b6ab3a814c73de92610639c6d3'
        meta.write_text(json.dumps(data))
        tracked.write_text('original')
        self.run_script('verify',False)
        self.run_script('verify',extra=('--allow-pre-reset-baseline',))
        self.assertTrue((self.baseline/'requires-cfg80211-rebuild').is_file())
        self.assertEqual('original',tracked.read_text())
        self.assertEqual('',subprocess.check_output(
            ['git','-C',str(self.kernel),'diff','HEAD'],text=True))
        tracked.write_text('unrelated kernel change')
        self.run_script('verify',False,extra=('--allow-pre-reset-baseline',))
        self.assertFalse((self.baseline/'requires-cfg80211-rebuild').exists())

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
