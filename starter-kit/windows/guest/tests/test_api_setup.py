import copy
import json
from pathlib import Path
import sys
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from test_core import CONTRACT

class FixtureTransport:
    def __init__(self,downloader):
        self.secrets={app:{'username':'unique-user','password':'SECRET-PASSWORD','apiKey':'SECRET-'+app} for app in ['sonarr','radarr','prowlarr','seerr','qbittorrent','sabnzbd']}
        self.calls=[]; self.resources={}; self.downloader=downloader
        self.responses=json.loads((Path(__file__).parent/'fixtures/downloader-responses.json').read_text())
    def request(self,app,method,path,payload=None,form=None):
        self.calls.append((app,method,path,copy.deepcopy(payload or form)))
        if path.endswith('/schema'):
            impl='Sonarr' if app=='prowlarr' else ('QBittorrent' if self.downloader=='qbittorrent' else 'Sabnzbd')
            choices=[impl,'Radarr'] if app=='prowlarr' else [impl]
            names=['prowlarrUrl','baseUrl','apiKey','syncCategories'] if app=='prowlarr' else ['host','port','useSsl','urlBase','username','password','apiKey','tvCategory','movieCategory','category','tvDirectory','movieDirectory','recentTvPriority','olderTvPriority','recentMoviePriority','olderMoviePriority']
            return [{'implementation':i,'configContract':i+'Settings','fields':[{'name':n,'value':None} for n in names]} for i in choices]
        if path.endswith('/config/host'):
            if method=='PUT': raise ValueError('HTTP405: documented host config PUT requires resource ID')
            return {'id':1,'apiKey':self.secrets[app]['apiKey']}
        if '/config/host/' in path and method=='PUT': return dict(payload)
        if path.endswith('/system/status'): return {'version':'fixture-1'}
        if path.endswith('/auth/login'): return self.responses['qbittorrent']['login']
        if path.endswith('/api/v2/app/version'): return 'v5.2.4'
        if path.endswith('/torrents/categories'): return copy.deepcopy(self.resources.setdefault((app,'categories'),self.responses['qbittorrent']['categories']))
        if path.endswith(('createCategory','editCategory')):
            self.resources[(app,'categories')][form['category']]={'name':form['category'],'savePath':form['savePath']}; return ''
        if path=='/api' and form:
            mode=form['mode']
            if mode=='version': return copy.deepcopy(self.responses['sabnzbd']['version'])
            if mode=='get_cats':
                config=self.resources.setdefault((app,'config'),copy.deepcopy(self.responses['sabnzbd']['categoryConfig']))
                if not config['config'].get('categories'): self.resources[(app,'config')]=copy.deepcopy(self.responses['sabnzbd']['categoryConfig'])
                return {'categories':[c['name'] for c in self.resources[(app,'config')]['config']['categories']]}
            if mode=='get_config': return copy.deepcopy(self.resources.setdefault((app,'config'),self.responses['sabnzbd']['categoryConfig']))
            if mode=='set_config':
                categories=self.resources[(app,'config')]['config']['categories']; match=next((c for c in categories if c['name']==form['name']),None)
                if not match: match={'name':form['name'],'order':len(categories),'newzbin':''}; categories.append(match)
                match.update({k:form[k] for k in ['dir','pp','script','priority']})
            return {'status':True}
        if path.endswith('/test'): return []
        if path.endswith('/config/mediamanagement'): return {'id':1,'copyUsingHardlinks':True}
        if '/config/mediamanagement/' in path and method=='PUT': return dict(payload)
        if app=='seerr' and path.endswith('/settings/public'): return {'initialized':False}
        if app=='seerr': raise ValueError('SECRET TOKEN must not leak')
        key=(app,path.rsplit('/',1)[0] if method=='PUT' else path)
        values=self.resources.setdefault(key,[{'id':90,'name':'unrelated','path':'/unrelated'}])
        if method=='GET': return copy.deepcopy(values)
        if method=='POST':
            record=dict(payload,id=len(values)+1); values.append(record); return copy.deepcopy(record)
        if method=='PUT':
            record=dict(payload); values[:]=[record if v['id']==record['id'] else v for v in values]; return record
        raise AssertionError((app,method,path))

class APITests(unittest.TestCase):
    def test_managed_setup_both_downloaders_schema_payloads_and_resume(self):
        import api_setup
        for downloader in ['qbittorrent','sabnzbd']:
            with self.subTest(downloader=downloader):
                c=dict(CONTRACT,downloader=downloader); t=FixtureTransport(downloader)
                first=api_setup.configure_apps(c,t); snapshot=copy.deepcopy(t.resources)
                second=api_setup.configure_apps(c,t)
                self.assertEqual(first,second); self.assertEqual(t.resources,snapshot)
                for app,path in [('sonarr','/data/media/tv'),('radarr','/data/media/movies')]:
                    roots=t.resources[(app,'/api/v3/rootfolder')]; self.assertIn(path,[v.get('path') for v in roots]); self.assertIn('/unrelated',[v.get('path') for v in roots])
                    clients=t.resources[(app,'/api/v3/downloadclient')]; self.assertEqual(len(clients),2)
                    managed=clients[-1]; fields={f['name']:f.get('value') for f in managed['fields']}
                    self.assertEqual(fields['host'],downloader)
                    self.assertEqual(fields['tvCategory' if app=='sonarr' else 'movieCategory'],'tv' if app=='sonarr' else 'movies')
                applications=t.resources[('prowlarr','/api/v1/applications')]
                self.assertEqual(len(applications),3)
                self.assertEqual({a.get('implementation') for a in applications[1:]},{'Sonarr','Radarr'})
                self.assertTrue(first['pendingSteps']); self.assertNotIn('SECRET',json.dumps(first))
                self.assertTrue(any(call[2].endswith('/test') for call in t.calls))
                if downloader=='qbittorrent': self.assertEqual(t.resources[(downloader,'categories')]['existing']['savePath'],'/data/downloads/existing')
                else: self.assertEqual(next(c for c in t.resources[(downloader,'config')]['config']['categories'] if c['name']=='existing')['dir'],'/data/downloads/existing')
    def test_failed_transport_sanitized_and_credentials_preserved(self):
        import api_setup
        t=FixtureTransport('qbittorrent'); before=copy.deepcopy(t.secrets)
        def fail(*args,**kwargs): raise RuntimeError('SECRET-PASSWORD http://key')
        t.request=fail
        with self.assertRaisesRegex(ValueError,'service readiness failed') as cm: api_setup.configure_apps(CONTRACT,t,attempts=1)
        self.assertNotIn('SECRET',str(cm.exception)); self.assertEqual(t.secrets,before)
    def test_schema_missing_required_field_fails_before_resource_create(self):
        import api_setup
        with self.assertRaises(ValueError): api_setup.schema_payload([{'implementation':'QBittorrent','fields':[]}],'QBittorrent',{'host':'qbittorrent'})
    def test_preference_readback_demands_web_cutoff_and_naming(self):
        import api_setup
        class T:
            def request(self,app,method,path,**kw):
                if path.endswith('naming'): return {'renameEpisodes':True} if app=='sonarr' else {'renameMovies':True}
                return [{'name':'WEB-1080p' if app=='sonarr' else 'HD Bluray + WEB','cutoff':2,'upgradeAllowed':True,'items':[{'quality':{'id':2,'name':'WEB 1080p'}}]}]
        api_setup.verify_preferences(T())
        class Bad(T):
            def request(self,*a,**kw):
                value=super().request(*a,**kw)
                if isinstance(value,list): value[0]['cutoff']=99
                return value
        with self.assertRaises(ValueError): api_setup.verify_preferences(Bad())
    def test_status_never_mutates_and_checks_managed_connections(self):
        import api_setup
        t=FixtureTransport('qbittorrent'); api_setup.configure_apps(CONTRACT,t); t.calls=[]
        health=api_setup.verify_apps(CONTRACT,t)
        self.assertTrue(health['checks']['connections'])
        self.assertFalse(any(method in ['PUT','DELETE'] or (method=='POST' and not path.endswith(('/test','/auth/login'))) for app,method,path,payload in t.calls))
    def test_failed_hardlinks_configure_copy_and_report_guidance(self):
        import api_setup
        t=FixtureTransport('qbittorrent')
        report=api_setup.set_hardlinks(t,'sonarr',False)
        self.assertFalse(report['hardlinks']); self.assertIn('extra disk',report['guidance'])
        self.assertFalse(t.calls[-1][3]['copyUsingHardlinks'])
    def test_category_path_drift_blocks_healthy_status(self):
        import api_setup
        for downloader in ['qbittorrent','sabnzbd']:
            t=FixtureTransport(downloader); c=dict(CONTRACT,downloader=downloader); api_setup.configure_apps(c,t)
            if downloader=='qbittorrent': t.resources[(downloader,'categories')]['tv']['savePath']='/unsafe'
            else: next(category for category in t.resources[(downloader,'config')]['config']['categories'] if category['name']=='tv')['dir']='/unsafe'
            health=api_setup.verify_apps(c,t)
            self.assertFalse(health['checks']['downloadCategories'])
    def test_seerr_must_respond_while_account_setup_stays_pending(self):
        import api_setup
        t=FixtureTransport('qbittorrent'); api_setup.configure_apps(CONTRACT,t)
        health=api_setup.verify_apps(CONTRACT,t)
        self.assertTrue(health['checks']['seerr']); self.assertTrue(health['pendingSteps'])
        original=t.request
        def unavailable(app,*args,**kwargs):
            if app=='seerr': raise ValueError('unavailable')
            return original(app,*args,**kwargs)
        t.request=unavailable
        self.assertFalse(api_setup.verify_apps(CONTRACT,t)['checks']['seerr'])
    def test_safe_api_diagnostics_show_structure_and_login_rejection(self):
        import api_setup
        summary=api_setup.response_summary({'error':'API Key Incorrect','apiKey':'SECRET-TOKEN','config':{'categories':None}})
        self.assertIn('categories',summary); self.assertIn('API Key Incorrect',summary); self.assertNotIn('SECRET',summary)
        t=FixtureTransport('qbittorrent'); t.responses['qbittorrent']['login']='Fails.'
        with self.assertRaisesRegex(ValueError,'qbittorrent.*login rejected'): api_setup.ready(t,'qbittorrent',attempts=1)
    def test_sab_lazy_default_categories_initialized_through_supported_api(self):
        import api_setup
        t=FixtureTransport('sabnzbd'); t.resources[('sabnzbd','config')]={'config':{}}
        api_setup.categories(t,'sabnzbd')
        values=t.resources[('sabnzbd','config')]['config']['categories']
        self.assertEqual(next(c for c in values if c['name']=='tv')['dir'],'/data/downloads/tv')
        self.assertIn('*',[c['name'] for c in values])
    def test_qbit_524_empty_success_requires_authenticated_version_readback(self):
        import api_setup
        t=FixtureTransport('qbittorrent'); t.responses['qbittorrent']['login']=None
        api_setup.ready(t,'qbittorrent',attempts=1)
        self.assertTrue(any(path=='/api/v2/app/version' and method=='GET' for app,method,path,payload in t.calls))
        original=t.request
        def denied(app,method,path,**kwargs):
            if path=='/api/v2/app/version': raise ValueError('authenticated qbittorrent GET /api/v2/app/version HTTP 401 failed')
            return original(app,method,path,**kwargs)
        t.request=denied
        with self.assertRaises(ValueError): api_setup.ready(t,'qbittorrent',attempts=1)

if __name__=='__main__': unittest.main()
