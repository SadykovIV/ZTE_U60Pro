"""Local-only UI fixture. All profile operations affect synthetic memory only."""
import copy, json, re
from http.server import ThreadingHTTPServer
from mock_agent import Handler as BaseHandler

def profile(n, enabled=False):
    return {'iccid': '8900000000000000'+str(n).zfill(2), 'isdp_aid': None,
            'state': 'enabled' if enabled else 'disabled', 'enabled': enabled,
            'nickname': None, 'name': 'Demo active' if enabled else 'Demo travel', 'service_provider': 'Example operator'}
SNAPSHOT = {'ok': True, 'eid': '9'*32, 'profiles': [profile(1, True), profile(2)]}
JOBS = {}
class Handler(BaseHandler):
    def do_GET(self):
        if self.path == '/api/esim/capabilities':
            return self._send({'ok':True,'data':{'protocol':1,'version':'2.7.0-esim.2','operations':['list','download','enable','delete'],'web_download_requires_modem_internet':True}})
        if self.path.startswith('/api/esim/jobs/'):
            value=JOBS.get(self.path.rsplit('/',1)[-1])
            return self._send({'ok':bool(value),'data':value},200 if value else 404)
        return super().do_GET()
    def do_POST(self):
        if self.path != '/api/esim/jobs':return super().do_POST()
        body=self._body();ident=body.get('request_id','');r=body.get('request',{});op=r.get('operation')
        if not re.fullmatch('[a-f0-9]{32}',ident):return self._send({'ok':False},400)
        if ident not in JOBS:
            if op != 'list' and r.get('expected_snapshot') != SNAPSHOT:return self._send({'ok':False,'error':'stale_snapshot'},409)
            if op == 'download':SNAPSHOT['profiles'].append(profile(len(SNAPSHOT['profiles'])+1))
            elif op == 'enable':
                for p in SNAPSHOT['profiles']:p['enabled']=p['iccid']==r.get('iccid');p['state']='enabled' if p['enabled'] else 'disabled'
            elif op == 'delete':
                target=next((p for p in SNAPSHOT['profiles'] if p['iccid']==r.get('iccid')),None)
                if not target or target['enabled'] or r.get('confirm_delete') is not True:return self._send({'ok':False},400)
                SNAPSHOT['profiles'].remove(target)
            elif op != 'list':return self._send({'ok':False},400)
            JOBS[ident]={'job_id':ident,'state':'complete','stage':'cleanup','logs':[{'type':'progress','stage':'checking_card','detail':{'event':'stage','elapsed_ms':0,'log_seq':1,'apdu_count':0,'http_count':0}},{'type':'progress','stage':'cleanup','detail':{'event':'cleanup_end','elapsed_ms':600,'log_seq':2,'apdu_count':6,'http_count':0,'outcome':'ok'}}],'result':{'type':'result','ok':True,'snapshot':copy.deepcopy(SNAPSHOT),'changed':op!='list','notifications_pending':False}}
        return self._send({'ok':True,'data':{'job_id':ident,'state':'running'}},202)

if __name__ == '__main__':ThreadingHTTPServer(('127.0.0.1',9090),Handler).serve_forever()
