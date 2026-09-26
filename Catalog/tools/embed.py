#!/usr/bin/env python3
"""Refresh the signed offline baseline and public resource copies. Never publish."""
import base64, pathlib, re, shutil, subprocess
root=pathlib.Path(__file__).resolve().parents[2]; catalog=root/'Catalog'
subprocess.run(['python3',str(catalog/'tools/catalog.py'),'verify',str(catalog/'verified-apps.json')],check=True)
der=subprocess.check_output(['openssl','pkey','-pubin','-in',str(catalog/'catalog-public-key.pem'),'-outform','DER'])
assert len(der)==91 and der[-65]==4, 'Expected an uncompressed P-256 public key'
key=base64.b64encode(der[-65:]).decode()
payload=base64.b64encode((catalog/'verified-apps.json').read_bytes()).decode()
signature=(catalog/'verified-apps.sig').read_text().strip()
for path,names in [(root/'MacIMEI/Sources/VerifiedCatalog.swift',('publicKeyBase64','baselinePayload','baselineSignature')),(root/'Windows_x64/src/VerifiedCatalog.cs',('PublicKeyBase64','BaselinePayload','BaselineSignature'))]:
    source=path.read_text()
    for name,value in zip(names,[key,payload,signature]):
        source,count=re.subn(r'('+name+r' = ")[^"]*(")',lambda m:m[1]+value+m[2],source)
        assert count==1, f'Missing/unexpected baseline constant {name}'
    path.write_text(source)
for folder in [root/'MacIMEI/Resources/Catalog',root/'Windows_x64/Resources/Catalog']:
    folder.mkdir(parents=True,exist_ok=True)
    for name in ['verified-apps.json','verified-apps.sig','catalog-public-key.pem','verified-apps.schema.json']:
        shutil.copyfile(catalog/name,folder/name)
    (folder/'evidence').mkdir(exist_ok=True)
    for path in (catalog/'evidence').glob('*.md'): shutil.copyfile(path,folder/'evidence'/path.name)
print('Embedded signed catalog and copied public assets; private signing files were not copied.')
