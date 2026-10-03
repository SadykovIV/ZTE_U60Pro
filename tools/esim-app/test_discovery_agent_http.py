#!/usr/bin/env python3
"""Local HTTP test of the host agent; never starts a service on a modem."""
from pathlib import Path
import argparse, json, os, socket, subprocess, tempfile, time, urllib.request, urllib.error

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--agent',type=Path,required=True);args=ap.parse_args()
    with tempfile.TemporaryDirectory(prefix='zte-passive-http-') as tmp:
        root=Path(tmp);tools=root/'bin';tools.mkdir();marker=root/'unexpected-vendor-command'
        for name in ['ubus','uci','ip','pidof','logger','sh']:
            p=tools/name;p.write_text('#!/bin/sh\nprintf unexpected >> "'+str(marker)+'"\nexit 99\n');p.chmod(0o700)
        with socket.socket() as s:s.bind(('127.0.0.1',0));port=s.getsockname()[1]
        env=dict(os.environ,PATH=str(tools)+':/usr/bin:/bin',ZTE_AGENT_MODE='discovery',ZTE_AGENT_BIND=f'127.0.0.1:{port}',ZTE_AGENT_PASSWORD='local-fixture-password')
        def call(method,path,payload=None,token=None):
            headers={'Content-Type':'application/json'}
            if token:headers['Authorization']='Bearer '+token
            req=urllib.request.Request(f'http://127.0.0.1:{port}'+path,data=json.dumps(payload).encode() if payload is not None else None,headers=headers,method=method)
            try:
                with urllib.request.urlopen(req,timeout=2) as r:return r.status,json.loads(r.read())
            except urllib.error.HTTPError as e:return e.code,json.loads(e.read())
        with (root/'server.log').open('wb') as out:
            child=subprocess.Popen([str(args.agent.resolve())],env=env,stdout=out,stderr=out)
            try:
                for attempt in range(40):
                    if child.poll() is not None:raise AssertionError('Agent exited before HTTP ready')
                    try:
                        status,_=call('GET','/api/health')
                        if status==401:break
                    except (OSError,urllib.error.URLError):time.sleep(.05)
                else:raise AssertionError('HTTP not ready')
                status,body=call('POST','/api/auth/login',{'password':'local-fixture-password'})
                assert status==200,(status,body)
                token=body['data']['token']
                read_statuses={}
                for path in ['/api/health','/api/capabilities','/api/cpu','/api/memory','/api/system/top','/api/device/thermal/all']:
                    status,body=call('GET',path,token=token)
                    unavailable=(path=='/api/memory' and not Path('/proc/meminfo').exists()) or (path=='/api/cpu' and not Path('/proc/stat').exists()) or (path=='/api/system/top' and not Path('/proc').exists())
                    expected=503 if unavailable else 200
                    assert status==expected,(path,status,body)
                    read_statuses[path]=status
                    if path=='/api/health':assert body['data']['mode']=='discovery'
                    if path=='/api/capabilities':assert body['data']['read_only'] and not body['data']['device_functions_assessed']
                for method,path in [('POST','/api/router/lan/confirm'),('POST','/api/device/reboot'),('PUT','/api/device/charge-control'),('GET','/api/dashboard'),('POST','/api/esim/enable')]:
                    status,body=call(method,path,{},token);assert status==403 and body['code']=='CAPABILITY_NOT_ASSESSED',(path,status,body)
                assert not marker.exists(),'Vendor commands executed during passive startup/read requests'
                print(json.dumps({'result':'PASS','binding':'loopback','safe_read_requests':read_statuses,'denied_routes':5,'authentication_verified':True,'vendor_commands':0,'hardware_tested':False}))
            finally:
                child.terminate()
                try:child.wait(timeout=3)
                except subprocess.TimeoutExpired:child.kill();child.wait()
if __name__=='__main__':main()
