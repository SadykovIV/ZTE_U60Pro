#!/usr/bin/env python3
"""Generate ephemeral certificates, compile production Swift, run without networking."""
from pathlib import Path
import hashlib
import json
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "MacIMEI/.build/esim-regression-1.22.1/logs"
OUT.mkdir(parents=True, exist_ok=True)
sources = [ROOT / "MacIMEI/Sources" / name for name in
           ("EsimTypes.swift", "EsimHTTPSRelay.swift")]
test = Path(__file__).with_name("MacEsimRegressionTests.swift")
def run(argv):
    subprocess.run([str(x) for x in argv], check=True, capture_output=True, text=True)
with tempfile.TemporaryDirectory(prefix="zte-esim-tls-tests-") as temp:
    d = Path(temp)
    for label in ("root-a", "root-b"):
        config = d/(label+".cnf")
        config.write_text("[req]\ndistinguished_name=dn\nx509_extensions=ca_ext\nprompt=no\n[dn]\nCN=Synthetic " + label + "\n[ca_ext]\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\nsubjectKeyIdentifier=hash\n")
        run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "30",
             "-sha256", "-config", config, "-keyout", d/(label+".key"), "-out", d/(label+".pem")])
    run(["openssl", "req", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=fixture.example",
         "-keyout", d/"leaf.key", "-out", d/"leaf.csr"])
    (d/"extensions.cnf").write_text("basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:fixture.example\n")
    run(["openssl", "x509", "-req", "-in", d/"leaf.csr", "-CA", d/"root-a.pem", "-CAkey", d/"root-a.key",
         "-CAcreateserial", "-days", "1", "-sha256", "-extfile", d/"extensions.cnf", "-out", d/"leaf.pem"])
    for label in ("root-a", "root-b", "leaf"):
        run(["openssl", "x509", "-in", d/(label+".pem"), "-outform", "DER", "-out", d/(label+".der")])
    (d/"roots.pem").write_bytes((d/"root-a.pem").read_bytes()+(d/"root-b.pem").read_bytes())
    binary = d/"MacEsimRegressionTests"
    compile_result = subprocess.run(["/usr/bin/swiftc", "-module-cache-path", str(ROOT/"MacIMEI/.build/module-cache"),
        "-swift-version", "5", "-parse-as-library", *map(str,sources), str(test), "-o", str(binary)], capture_output=True, text=True)
    (OUT/"network-regression-compile.log").write_text(compile_result.stdout+compile_result.stderr)
    if compile_result.returncode: raise SystemExit(compile_result.returncode)
    result = subprocess.run([str(binary),str(d)],capture_output=True,text=True)
    (OUT/"network-regression-tests.log").write_text(result.stdout+result.stderr)
    (OUT/"network-regression-proof.json").write_text(json.dumps({"network":False,"device":False,"exit":result.returncode,
        "ephemeral_private_keys_removed_on_exit":True,"inputs":{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [*sources,test,Path(__file__)]}},indent=2)+"\n")
    print(result.stdout, end="")
    if result.returncode: print(result.stderr)
    raise SystemExit(result.returncode)
