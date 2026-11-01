"""Verify the production eUICC v2 parser using synthetic target-bound responses."""
from pathlib import Path
import os, subprocess, tempfile
HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[2]
with tempfile.TemporaryDirectory(prefix='zte-esim-model-') as tmp:
    binary=Path(tmp)/'test';vendor=Path(tmp)/'cjson.o'
    flags=[os.environ.get('CC','clang'),'-std=c11','-Wall','-Wextra','-Werror','-g','-fsanitize=address,undefined','-fno-omit-frame-pointer']
    subprocess.run([*flags,'-Wno-deprecated-declarations','-c',str(ROOT/'third_party/lpac/cjson/cJSON.c'),'-o',str(vendor)],check=True)
    subprocess.run([*flags,str(HERE/'esim_model_test.c'),str(HERE.parent/'esim-model.c'),str(vendor),'-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True,env={**os.environ,'ASAN_OPTIONS':'detect_leaks=0:halt_on_error=1','UBSAN_OPTIONS':'halt_on_error=1'})
