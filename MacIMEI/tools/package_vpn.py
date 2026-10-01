#!/usr/bin/env python3
"""Compatibility entry point for the complete public modem/eSIM resource build."""
from pathlib import Path
import subprocess,sys
ROOT=Path(__file__).resolve().parents[2]
if __name__ == '__main__':
    subprocess.run([sys.executable,str(ROOT/'tools/build.py'),'--modem-only',*sys.argv[1:]],cwd=ROOT,check=True)
