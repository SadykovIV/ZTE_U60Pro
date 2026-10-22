"""Execute production launcher callbacks against in-memory host widgets."""
from pathlib import Path
import os, subprocess, tempfile
HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[2]
def main():
    source=(HERE.parent/'launcher.c').read_text()
    replacements={
      '#include <sys/auxv.h>':'#define AT_PHDR 3\n#define AT_ENTRY 9\nstatic unsigned long getauxval(unsigned long x){(void)x;return 0;}',
      '#define F(a,r,...) ((r(*)(__VA_ARGS__))(uintptr_t)launcher_abi_address(abi,(a)))':'#define F(a,r,...) ((r(*)(__VA_ARGS__))(uintptr_t)test_address((a)))',
      '__attribute__((constructor)) static void init(void)':'static void init(void)',
      '"/tmp/zte-launcher/ready"':'"/dev/null"',
    }
    for before,after in replacements.items():
        assert source.count(before)==1,before
        source=source.replace(before,after)
    assert 'subscription_button' not in source and 'backend_update_subscriptions()' not in source
    with tempfile.TemporaryDirectory(prefix='launcher-ui-callbacks-') as temporary:
        temporary=Path(temporary);generated=temporary/'launcher-under-test.c';generated.write_text(source)
        binary=temporary/'ui-test';vendor=temporary/'cJSON.o'
        flags=[os.environ.get('CC','clang'),'-std=c11','-Wall','-Wextra','-Werror','-O1','-g','-fsanitize=address,undefined','-fno-omit-frame-pointer']
        subprocess.run([*flags,'-Wno-deprecated-declarations','-c',str(ROOT/'third_party/lpac/cjson/cJSON.c'),'-o',str(vendor)],check=True)
        subprocess.run([*flags,'-I'+str(HERE.parent),'-DLAUNCHER_TEST_SOURCE="'+str(generated)+'"',str(HERE/'ui_interaction_test.c'),str(HERE.parent/'info-layout.c'),str(HERE.parent/'vpn-model.c'),str(HERE.parent/'display-text.c'),str(vendor),'-o',str(binary)],check=True)
        subprocess.run([str(binary)],check=True,env={**os.environ,'ASAN_OPTIONS':'detect_leaks=0:halt_on_error=1','UBSAN_OPTIONS':'halt_on_error=1'},timeout=60)
if __name__=='__main__':main()
