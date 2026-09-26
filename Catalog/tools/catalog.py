#!/usr/bin/env python3
"""Offline ECDSA P-256 catalog signing. Never uploads or publishes anything."""
import argparse, base64, hashlib, json, os, pathlib, subprocess, tempfile
ROOT = pathlib.Path(__file__).resolve().parents[1]
SPKI = bytes.fromhex('3059301306072a8648ce3d020106082a8648ce3d030107034200')

def run(*args):
    return subprocess.run(args, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout

def raw_signature(der):
    def read(data, pos, tag):
        if data[pos] != tag: raise ValueError('Bad DER tag')
        length=data[pos+1]; start=pos+2
        if length & 128: raise ValueError('Unexpected DER length')
        return data[start:start+length], start+length
    sequence, end=read(der,0,0x30)
    if end != len(der): raise ValueError('Trailing signature bytes')
    r, pos=read(sequence,0,0x02); s, end=read(sequence,pos,0x02)
    if end != len(sequence): raise ValueError('Trailing signature integers')
    return int.from_bytes(r,'big').to_bytes(32,'big') + int.from_bytes(s,'big').to_bytes(32,'big')

def der_signature(raw):
    if len(raw)!=64: raise ValueError('Signature must contain 64 bytes')
    def integer(v):
        data=v.lstrip(b'\0') or b'\0'
        if data[0]&128: data=b'\0'+data
        return b'\x02'+bytes([len(data)])+data
    seq=integer(raw[:32])+integer(raw[32:])
    return b'\x30'+bytes([len(seq)])+seq

def validate(path):
    raw=path.read_bytes()
    if len(raw)>131072: raise ValueError('Catalog exceeds 128 KiB')
    doc=json.loads(raw)
    if doc['schemaVersion']!=1 or type(doc['revision'])!=int or doc['revision']<1: raise ValueError('Invalid schema/revision')
    ids=[]
    for app in doc['apps']:
        if app['id'] in ids: raise ValueError('Duplicate app id')
        ids.append(app['id'])
        if app['verification']['result']!='passed' or not app['verification']['evidenceSHA256']: raise ValueError('Missing verification evidence')
        for language in ['ru','en']:
            if not app['description'][language] or not app['verification']['summary'][language]: raise ValueError('Missing translation')
    return doc

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    sub=parser.add_subparsers(dest='command',required=True)
    key=sub.add_parser('keygen'); key.add_argument('--private-key',type=pathlib.Path,default=ROOT/'private/catalog-signing-key.pem'); key.add_argument('--public-key',type=pathlib.Path,default=ROOT/'catalog-public-key.pem')
    for command in ['sign','verify']:
        p=sub.add_parser(command);p.add_argument('manifest',type=pathlib.Path);p.add_argument('--signature',type=pathlib.Path)
        p.add_argument('--key',type=pathlib.Path,default=ROOT/('private/catalog-signing-key.pem' if command=='sign' else 'catalog-public-key.pem'))
    args=parser.parse_args()
    if args.command=='keygen':
        if args.private_key.exists() or args.public_key.exists(): raise SystemExit('Key already exists; no replacement performed')
        args.private_key.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
        old=os.umask(0o077)
        try: args.private_key.write_bytes(run('openssl','ecparam','-name','prime256v1','-genkey','-noout'))
        finally: os.umask(old)
        args.public_key.write_bytes(run('openssl','pkey','-in',str(args.private_key),'-pubout'))
        print('Created private signing key and public verification key. No files were published.')
        return
    doc=validate(args.manifest); sig=args.signature or args.manifest.with_suffix('.sig')
    with tempfile.TemporaryDirectory() as tmp:
        der=pathlib.Path(tmp)/'signature.der'
        if args.command=='sign':
            run('openssl','dgst','-sha256','-sign',str(args.key),'-out',str(der),str(args.manifest))
            sig.write_text(base64.b64encode(raw_signature(der.read_bytes())).decode()+'\n')
        else:
            der.write_bytes(der_signature(base64.b64decode(sig.read_text().strip(),validate=True)))
            run('openssl','dgst','-sha256','-verify',str(args.key),'-signature',str(der),str(args.manifest))
    print(f'{args.command}: revision {doc["revision"]}, {len(doc["apps"])} entries, sha256 {hashlib.sha256(args.manifest.read_bytes()).hexdigest()}')
if __name__=='__main__': main()
