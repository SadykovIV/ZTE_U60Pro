#!/usr/bin/env python3
"""Host HTTP regression, including startup scripts left by the removed mode.

Run on a development host without /data. Vendor tools are stubs: their calls
are recorded and fail with exit 99. No service is started on a modem.
"""
from pathlib import Path
import argparse, json, os, socket, subprocess, sys, tempfile, time, urllib.request, urllib.error

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--agent',type=Path,required=True);args=ap.parse_args()
    assert not Path('/data').exists(), 'Use a development host without modem state in /data'
    with tempfile.TemporaryDirectory(prefix='zte-agent-http-') as tmp:
        root=Path(tmp);tools=root/'bin';tools.mkdir();marker=root/'unexpected-vendor-command'
        for name in ['ubus','uci','ip','pidof','logger','sh','iw','bridge','ethtool']:
            p=tools/name
            p.write_text('#!'+sys.executable+'\nimport json,sys\nfrom pathlib import Path\nwith Path('+repr(str(marker))+').open("a") as f:f.write(json.dumps([Path(sys.argv[0]).name,*sys.argv[1:]])+"\\n")\nsys.exit(99)\n')
            p.chmod(0o700)
        with socket.socket() as s:s.bind(('127.0.0.1',0));port=s.getsockname()[1]
        env=dict(os.environ,PATH=str(tools)+':/usr/bin:/bin',ZTE_AGENT_MODE='discovery',ZTE_AGENT_BIND=f'127.0.0.1:{port}',ZTE_AGENT_PASSWORD='local-fixture-password')
        def call(method,path,payload=None,token=None,confirmed=False):
            headers={'Content-Type':'application/json'}
            if token:headers['Authorization']='Bearer '+token
            if confirmed:headers['X-Confirm']='true'
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
                for path in ['/api/health','/api/cpu','/api/memory','/api/system/top','/api/device/thermal/all']:
                    status,body=call('GET',path,token=token)
                    unavailable=(path=='/api/memory' and not Path('/proc/meminfo').exists()) or (path=='/api/cpu' and not Path('/proc/stat').exists()) or (path=='/api/system/top' and not Path('/proc').exists())
                    if path=='/api/device/thermal/all': unavailable=not body.get('data',{}).get('available',False)
                    expected=503 if unavailable else 200
                    assert status==expected,(path,status,body)
                    read_statuses[path]=status
                    if path=='/api/health':assert 'mode' not in body['data'],body
                status,body=call('GET','/api/capabilities',token=token)
                assert status==404,(status,body)
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
                    safe|=name=='ubus' and arguments==['listen']
                    safe|=name=='uci' and len(arguments)==2 and arguments[0] in ['get','show']
                    safe|=name=='iw' and len(arguments)>=2 and arguments[0] in ['wlan0','wlan2'] and arguments[1:] in [['info'],['station','dump']]
                    safe|=name=='bridge' and arguments==['fdb','show','br','br-lan']
                    assert safe,('Unexpected command in status reads',command)
                # Invalid input reaches each operation's own validation. A
                # legacy MODE environment variable must not block dispatch.
                validation=[('POST','/api/router/lan/confirm',409),('POST','/api/device/reboot',400),
                    ('PUT','/api/usb/mode',400),('POST','/api/at/send',400),('POST','/api/esim/jobs',400)]
                for method,path,expected in validation:
                    status,body=call(method,path,{},token)
                    assert status==expected and body['ok'] is False,(path,status,body)
                    assert body.get('code')!='CAPABILITY_NOT_ASSESSED',body
                status,body=call('GET','/api/vpn/status',token=token)
                assert status==200 and body['data']['installed'] is False,(status,body)
                status,body=call('POST','/api/vpn/request',{'action':'set_enabled','enabled':False},token)
                assert status==503 and body['code']=='VPN_NOT_INSTALLED',(status,body)
                status,body=call('GET','/api/esim/capabilities',token=token)
                assert status==200 and body['ok'] is True,(status,body)
                # The confirmed command runs only our fake ubus. Its failure
                # must be returned as the specific backend error.
                status,_=call('POST','/api/device/reboot',{},confirmed=True)
                assert status==401
                status,body=call('POST','/api/device/reboot',{},token,confirmed=True)
                assert status==503 and body['ok'] is False,(status,body)
                status,_=call('POST','/api/system/restart-agent',{});assert status==401
                status,body=call('POST','/api/system/restart-agent',{},token)
                assert status==409 and body['ok'] is False,('Uninstalled fixture must not restart',status,body)
                assert child.poll() is None,'Fixture unexpectedly stopped'
                following=[json.loads(line) for line in marker.read_text().splitlines()][len(commands):]
                requested=[c for c in following if c!=['ubus','listen']]
                assert requested==[['ubus','call','system','reboot','{}']],requested
                print(json.dumps({'result':'PASS','binding':'loopback','safe_read_requests':read_statuses,
                    'operation_validation_requests':len(validation),'authentication_verified':True,
                    'legacy_mode_ignored':True,'read_vendor_commands':len(commands),
                    'fake_mutation_commands':len(requested),'hardware_commands':0,
                    'missing_vpn_error':'VPN_NOT_INSTALLED','uninstalled_restart_refused':True,'hardware_tested':False}))
            finally:
                child.terminate()
                try:child.wait(timeout=3)
                except subprocess.TimeoutExpired:child.kill();child.wait()
if __name__=='__main__':main()
