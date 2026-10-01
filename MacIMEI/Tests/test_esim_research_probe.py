#!/usr/bin/env python3
"""Execute only a synthetic, path-remapped research probe. No modem access."""
import hashlib, json, os, pathlib, subprocess, tempfile, unittest
ROOT=pathlib.Path(__file__).resolve().parents[1]
class ProbeTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='zte-esim-research-'); self.base=pathlib.Path(self.temp.name)
        self.bin=self.base/'bin';self.bin.mkdir()
        spec=json.loads((ROOT/'Resources/FirmwareResearch/probes.json').read_text())
        self.command=next(p['command'] for p in spec['probes'] if p['id']=='esim-components')
        self.assertNotIn('ubus call',self.command);self.assertNotIn('uci ',self.command)
        self.assertNotIn('lpac ',self.command);self.assertNotIn('/dev/',self.command.replace('/dev/null',''))
        paths=['/usr/bin/zte_topsw_mdm','/usr/lib/libzte_SDKowrt.so','/usr/bin/qcrilNrd','/data/zte-agent']
        self.files={p:self.base/('file'+str(i)) for i,p in enumerate(paths)}
        for old,new in self.files.items():
            new.write_bytes(b'PRIVATE-SYNTHETIC-NOT-OUTPUT\0ZTD_GetCurrentSimSlot\0ZTD_SetActiveSimSlot\0')
            self.command=self.command.replace(old,str(new))
        self.command=self.command.replace('PATH=/usr/sbin:/usr/bin:/sbin:/bin','PATH='+str(self.bin)+':/usr/bin:/bin')
        self.mock('stat',"import os,sys; assert sys.argv[1:3]==['-c','%s']; print(os.path.getsize(sys.argv[3]))")
        self.mock('sha256sum',"import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest()+'  '+sys.argv[1])")
        self.mock('strings',"import sys; print(open(sys.argv[1],'rb').read().decode().replace('\\0','\\n'))")
        self.setUbus()
    def tearDown(self): self.temp.cleanup()
    def mock(self,name,body):
        p=self.bin/name;p.write_text('#!'+os.sys.executable+'\n'+body+'\n');p.chmod(0o700)
    def setUbus(self,fail=False):
        self.mock('ubus',"import sys,json; assert sys.argv[1:]==['-t','5','-v','list','zwrt_zte_mdm.api']; "+("sys.exit(1)" if fail else "print('\\n'.join(['  "+'"'+"'+name+'"+'"'+": {}' for name in ['zte_get_current_slot_info','get_sim_info','zwrt_zte_mdm_activate_sim','zwrt_mdm_change_provision_session']])+ '\\nPRIVATE-SYNTHETIC-NOT-OUTPUT')"))
    def runProbe(self):
        r=subprocess.run(['/bin/sh','-c',self.command],capture_output=True,text=True,timeout=10)
        self.assertEqual(r.returncode,0,r.stderr);self.assertNotIn('PRIVATE-SYNTHETIC',r.stdout+r.stderr)
        self.assertIn('FR_FACT physical_euicc_management=not-assessed',r.stdout)
        self.assertIn('FR_FACT native_isdr_access=not-assessed',r.stdout)
        return r.stdout
    def test_metadata_only(self):
        out=self.runProbe();self.assertIn('FR_FACT esim_method_get_sim_info=1',out)
        self.assertIn('SDK_SYMBOL ZTD_GetCurrentSimSlot',out)
        self.assertIn(hashlib.sha256(self.files['/data/zte-agent'].read_bytes()).hexdigest(),out)
    def test_api_failure_is_unknown(self):
        self.setUbus(True);self.assertIn('FR_FACT esim_method_inventory=unknown',self.runProbe())
    def test_oversized_binary_is_not_read(self):
        with self.files['/usr/bin/qcrilNrd'].open('wb') as f:f.truncate(67108865)
        self.assertIn('FR_FACT esim_qcril_sha256=not-assessed',self.runProbe())
if __name__=='__main__':unittest.main()
