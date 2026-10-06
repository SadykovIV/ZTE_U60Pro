#!/usr/bin/env python3
"""Local HTTP test of the host agent; never starts a service on a modem."""
from pathlib import Path
import argparse, json, os, socket, subprocess, sys, tempfile, time, urllib.request, urllib.error

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--agent',type=Path,required=True);args=ap.parse_args()
    with tempfile.TemporaryDirectory(prefix='zte-passive-http-') as tmp:
        root=Path(tmp);tools=root/'bin';tools.mkdir();marker=root/'unexpected-vendor-command'
        for name in ['ubus','uci','ip','pidof','logger','sh','iw','bridge','ethtool']:
            p=tools/name
            p.write_text('#!'+sys.executable+'\nimport json,sys\nfrom pathlib import Path\nwith Path('+repr(str(marker))+').open("a") as f:f.write(json.dumps([Path(sys.argv[0]).name,*sys.argv[1:]])+"\\n")\nsys.exit(99)\n')
            p.chmod(0o700)
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
                    if path=='/api/capabilities':
                        capabilities=body['data']
                        assert capabilities['hardware_read_only'] and not capabilities['device_functions_assessed']
                        assert not capabilities['read_only'] and capabilities['software_controls']==['system/restart-agent']
                assert not marker.exists(),'Vendor commands executed during passive startup/system reads'
                remaining=['dashboard','device','device/battery-info','device/battery/detail','device/charger',
                    'device/charge-control','network/clients','wifi/status','sim/info','sim/imei',
                    'router/dns','router/lan','router/apn/mode','router/apn/profiles','usb/status']
                for relative in remaining:
                    path='/api/'+relative
                    status,_=call('GET',path);assert status==401,(path,status)
                    status,body=call('GET',path,token=token)
                    assert status in (200,503),(path,status,body)
                    assert body.get('code')!='CAPABILITY_NOT_ASSESSED',(path,body)
                    if relative in ['wifi/status','sim/info','sim/imei','router/dns','router/apn/mode','router/apn/profiles','device/charger']:
                        assert status==503 and body['ok'] is False,(path,status,body)
                    read_statuses[path]=status
                assert set(capabilities['safe_reads'])=={p.removeprefix('/api/') for p in read_statuses}
                commands=[json.loads(line) for line in marker.read_text().splitlines()]
                safe_ubus={('zwrt_bsp.charger','list'),('zwrt_bsp.battery','list'),('zwrt_bsp.thermal','get_cpu_temp'),
                    ('network.interface.zte_wan','status'),('network.interface.zte_wan6','status'),
                    ('zte_nwinfo_api','nwinfo_get_netinfo'),('zwrt_data','get_wwandst'),('zwrt_data','get_wwandst_clearday'),
                    ('zwrt_wlan','report'),('zwrt_zte_mdm.api','get_sim_info'),('zwrt_zte_mdm.api','get_imei'),
                    ('zwrt_router.api','router_get_dns_para'),('zwrt_apn_object','get_apn_mode'),
                    ('zwrt_apn_object','get_manu_apn_list'),('zwrt_bsp.usb','list'),('luci-rpc','getDHCPLeases')}
                for command in commands:
                    name,*arguments=command
                    safe=(name=='ubus' and len(arguments)==4 and arguments[0]=='call' and tuple(arguments[1:3]) in safe_ubus)
                    safe|=name=='uci' and len(arguments)==2 and arguments[0] in ['get','show']
                    safe|=name=='iw' and len(arguments)>=2 and arguments[0] in ['wlan0','wlan2'] and arguments[1:] in [['info'],['station','dump']]
                    safe|=name=='bridge' and arguments==['fdb','show','br','br-lan']
                    assert safe,('Unexpected command in status reads',command)
                before=marker.read_bytes()
                denied=[('POST','/api/router/lan/confirm'),('POST','/api/device/reboot'),('PUT','/api/device/charge-control'),
                    ('POST','/api/esim/enable'),('GET','/api/esim/profiles'),('GET','/api/vpn/status'),('POST','/api/usb/mode')]
                for method,path in denied:
                    status,body=call(method,path,{},token)
                    assert status==403 and body['code']=='CAPABILITY_NOT_ASSESSED',(path,status,body)
                status,_=call('POST','/api/system/restart-agent',{});assert status==401
                status,body=call('POST','/api/system/restart-agent',{},token)
                assert status==409 and body['ok'] is False,('Uninstalled fixture must not restart',status,body)
                assert child.poll() is None and marker.read_bytes()==before,'Denied operation executed a command'
                print(json.dumps({'result':'PASS','binding':'loopback','safe_read_requests':read_statuses,
                    'denied_routes':len(denied),'authentication_verified':True,'read_vendor_commands':len(commands),
                    'hardware_commands':0,'uninstalled_restart_refused':True,'hardware_tested':False}))
            finally:
                child.terminate()
                try:child.wait(timeout=3)
                except subprocess.TimeoutExpired:child.kill();child.wait()
if __name__=='__main__':main()
