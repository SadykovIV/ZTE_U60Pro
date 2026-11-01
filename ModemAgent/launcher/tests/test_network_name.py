"""Host-only display callback and exact captured B31 ABI proof; no vendor execution."""
from pathlib import Path
import os
import re
import struct
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent

class NetworkNameTests(unittest.TestCase):
    def test_provider_unicode_bounds_and_abi_mutations(self):
        with tempfile.TemporaryDirectory(prefix='zte-network-name-') as temp:
            binary = Path(temp) / 'test'
            subprocess.run([os.environ.get('CC','clang'),'-std=c11','-Wall','-Wextra','-Werror',
                            '-g','-fsanitize=address,undefined','-fno-omit-frame-pointer',
                            str(HERE.parent/'network-name.c'),str(HERE/'network_name_test.c'),
                            '-o',str(binary)],check=True)
            subprocess.run([str(binary)],check=True,env={**os.environ,
                'ASAN_OPTIONS':f'detect_leaks={int(sys.platform != "darwin")}:halt_on_error=1',
                'UBSAN_OPTIONS':'halt_on_error=1'})

    def test_reference_prologs_slots_and_sdk_imports(self):
        reference = os.environ.get('ZTE_STOCK_UI')
        if not reference:
            self.skipTest('No private B31 reference ELF supplied')
        sys.path.insert(0,str(HERE.parent))
        import abi
        data=Path(reference).read_bytes()
        self.assertEqual(abi.verify(data),'b31')
        h=struct.unpack_from('<16sHHIQQQIHHHHHH',data)
        segments=[struct.unpack_from('<IIQQQQQQ',data,h[5]+i*h[9]) for i in range(h[10])]
        def body(address,size):
            for kind,_,off,va,_,length,_,_ in segments:
                if kind==1 and va<=address and address+size<=va+length:
                    return data[off+address-va:off+address-va+size]
            raise AssertionError('Unmapped reference address')
        source=(HERE.parent/'network-name-abi.h').read_text()
        entries=re.findall(r'\{(0x[0-9a-f]+), (0x[0-9a-f]+), \{([^}]+)\}\}',source)
        self.assertEqual(len(entries),2)
        for slot,target,words in entries:
            slot,target=int(slot,0),int(target,0)
            self.assertEqual(struct.unpack('<Q',body(slot,8))[0],target)
            self.assertEqual(body(target,32),b''.join(struct.pack('<I',int(w,0)) for w in words.split(',')))
        dynamic={}
        for kind,_,off,_,_,size,_,_ in segments:
            if kind==2:
                for tag,value in struct.iter_unpack('<QQ',data[off:off+size]):dynamic[tag]=value
        symbols={}
        for offset,info,_ in struct.iter_unpack('<QQq',body(dynamic[7],dynamic[8])):
            if offset not in (0xe7f210,0xe793f8):continue
            self.assertEqual(info & 0xffffffff,0x401)  # R_AARCH64_GLOB_DAT: resolved, never lazy PLT.
            name=struct.unpack('<I',body(dynamic[6]+(info>>32)*dynamic[11],4))[0]
            raw=body(dynamic[5]+name,64)
            symbols[offset]=raw.split(b'\0',1)[0].decode()
        self.assertEqual(symbols,{0xe7f210:'ZTD_GetWanLongProvider',0xe793f8:'ZTD_GetWanProvider'})

if __name__=='__main__': unittest.main()
