#!/usr/bin/env python3
"""Exercise the actual bundled static ARM64 supervisor in a diskless, NIC-less Linux VM."""
from pathlib import Path
import hashlib,json,shutil,stat,subprocess
ROOT=Path(__file__).resolve().parents[1];BASE=ROOT/'.build/host-tools-vm';BASE.mkdir(parents=True,exist_ok=True)
BINARY=ROOT/'Resources/HostTools/zte-timeout';KERNEL=ROOT/'.build/diagnostics-vm/kernel.bin'
assert KERNEL.is_file(),'Expected previously authenticated OpenWrt ARM64 QA kernel'
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
assert sha(BINARY)==json.loads((BINARY.parent/'SHA256.json').read_text())['zte-timeout']
cc=shutil.which('aarch64-linux-musl-gcc');qemu=shutil.which('qemu-system-aarch64');assert cc and qemu
fixture=BASE/'fixture'
subprocess.run([cc,'-std=c11','-Os','-static','-Wall','-Wextra','-Werror',str(ROOT/'Native/tests/zte_timeout_vm.c'),'-o',str(fixture)],check=True)
output=bytearray();ino=0

def add(name,mode,data=b'',major=0,minor=0):
 global ino
 ino+=1;name=name.encode()+b'\0';fields=[ino,mode,0,0,2 if stat.S_ISDIR(mode) else 1,0,len(data),0,0,major,minor,len(name),0]
 output.extend(b'070701'+b''.join(('%08x'%v).encode() for v in fields)+name);output.extend(b'\0'*((-len(output))%4));output.extend(data);output.extend(b'\0'*((-len(output))%4))
for name in ['proc','sys','dev','tmp']:add(name,stat.S_IFDIR|0o755)
for name,path in [('init',fixture),('fixture',fixture),('zte-timeout',BINARY)]:add(name,stat.S_IFREG|0o700,path.read_bytes())
add('dev/console',stat.S_IFCHR|0o600,major=5,minor=1);add('dev/null',stat.S_IFCHR|0o666,major=1,minor=3);add('TRAILER!!!',0)
initrd=BASE/'initramfs.cpio';initrd.write_bytes(output)
command=[qemu,'-machine','virt,accel=tcg','-cpu','cortex-a53','-m','256M','-nographic','-monitor','none','-serial','stdio','-kernel',str(KERNEL),'-initrd',str(initrd),'-append','console=ttyAMA0 rdinit=/init panic=1','-nic','none','-no-reboot']
(BASE/'command.json').write_text(json.dumps(command,indent=2)+'\n')
(BASE/'inputs.json').write_text(json.dumps({'helper_sha256':sha(BINARY),'kernel_sha256':sha(KERNEL),'test_source_sha256':sha(ROOT/'Native/tests/zte_timeout_vm.c'),'helper_source_sha256':sha(ROOT/'Native/zte_timeout.c'),'initrd_sha256':sha(initrd)},indent=2)+'\n')
r=subprocess.run(command,stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=50)
(BASE/'runtime.log').write_bytes(r.stdout)
text=r.stdout.decode(errors='replace');print(text[text.find('HOST_TIMEOUT_VM_BEGIN'):])
assert 'HOST_TIMEOUT_VM_EXIT 0' in text and 'failures=0' in text and 'HOST_TIMEOUT_FAIL' not in text,'Real ARM64 supervisor test failed'
