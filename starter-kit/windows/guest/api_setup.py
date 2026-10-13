"""Bounded authenticated app adapters; manage named kit resources only."""
import copy
import http.cookiejar
import json
import re
from pathlib import Path
import time
import urllib.parse
import urllib.error
import urllib.request

PORTS={'sonarr':8989,'radarr':7878,'prowlarr':9696,'seerr':5055,'qbittorrent':8080,'sabnzbd':8080}
PENDING=['Plex claim and Movies/TV libraries','Seerr Plex sign-in and library selection','Indexer/provider credentials']

def response_summary(value,depth=0):
    if isinstance(value,dict) and depth<3:
        safe={'config','categories','misc','status','error','version','category','name','dir','savePath'}
        description='object['+','.join(key+':'+response_summary(item,depth+1) for key,item in value.items() if key in safe)+']'
        errors={'API Key Required','API Key Incorrect','API Key missing','API Key incorrect','Not implemented','Access denied','Configuration locked'}
        if value.get('error') in errors: description+=' '+value['error']
        return description
    if isinstance(value,list): return 'list('+str(len(value))+')'
    return type(value).__name__

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,*args,**kwargs): raise ValueError('unexpected app redirect')

class HTTPTransport:
    def __init__(self,secrets,in_container=False):
        self.secrets=secrets
        self.in_container=in_container
        self.opener=urllib.request.build_opener(NoRedirect,urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
    def request(self,app,method,path,payload=None,form=None):
        if app not in PORTS or not path.startswith('/') or path.startswith('//'): raise ValueError('invalid app request')
        base='http://'+(app if self.in_container else '127.0.0.1')+':'+str(PORTS[app]); headers={'Referer':base,'Accept':'application/json'}
        if app in ['sonarr','radarr','prowlarr','seerr']: headers['X-Api-Key']=self.secrets[app]['apiKey']
        body=None
        if app=='sabnzbd': form=dict(form or {},apikey=self.secrets[app]['apiKey'],output='json')
        if form is not None: body=urllib.parse.urlencode(form).encode(); headers['Content-Type']='application/x-www-form-urlencoded'
        elif payload is not None: body=json.dumps(payload).encode(); headers['Content-Type']='application/json'
        try:
            request=urllib.request.Request(base+path,data=body,method=method,headers=headers)
            with self.opener.open(request,timeout=10) as response:
                raw=response.read(4*1024*1024).decode()
                if not raw: return None
                try: return json.loads(raw)
                except ValueError: return raw
        except urllib.error.HTTPError as error: raise ValueError('authenticated '+app+' '+method+' '+path+' HTTP '+str(error.code)+' failed') from None
        except Exception: raise ValueError('authenticated '+app+' '+method+' '+path+' request failed') from None

def ready(t,app,attempts=12):
    last='request unavailable'
    for attempt in range(attempts):
        try:
            if app=='qbittorrent':
                result=t.request(app,'POST','/api/v2/auth/login',form={'username':t.secrets[app]['username'],'password':t.secrets[app]['password']})
                # qBit 5.2.4 returns empty HTTP200; older APIs return Ok.
                # Always prove the cookie/session on an authenticated read.
                if result not in ['Ok.',None,'']: raise ValueError('login rejected')
                version=t.request(app,'GET','/api/v2/app/version')
                if not isinstance(version,str) or not re.fullmatch(r'v?[0-9]+(?:\.[0-9]+){1,3}[A-Za-z0-9._-]*',version): raise ValueError('login rejected')
            elif app=='sabnzbd':
                result=t.request(app,'POST','/api',form={'mode':'version'})
                if not isinstance(result,dict) or not result.get('version'): raise ValueError()
            else: t.request(app,'GET','/api/'+('v1' if app=='prowlarr' else 'v3')+'/system/status')
            return
        except Exception as error:
            message=str(error)
            if message=='login rejected': last=message
            elif re.fullmatch(r'authenticated [a-z]+ (GET|POST|PUT) /api/[A-Za-z0-9/_-]+ HTTP [0-9]{3} failed',message): last=message
            if attempt+1<attempts: time.sleep(min(2,attempt+1))
    raise ValueError('service readiness failed '+app+' '+last) from None

def schema_payload(schemas,implementation,fields):
    matches=[s for s in schemas if s.get('implementation')==implementation]
    if len(matches)!=1: raise ValueError('unsupported application schema')
    result=copy.deepcopy(matches[0]); result.pop('id',None)
    known={f['name']:f for f in result.get('fields',[])}
    if not set(fields)<=set(known): raise ValueError('required schema fields missing')
    for name,value in fields.items(): known[name]['value']=value
    return result

def test_provider(t,app,path,desired):
    tested=dict(desired)
    if not tested.get('id'):
        records=t.request(app,'GET',path.removesuffix('/test'))
        if not isinstance(records,list): raise ValueError('invalid managed-resource response')
        matches=[r for r in records if r.get('name')==tested['name']]
        if len(matches)>1: raise ValueError('ambiguous managed resource')
        # Connection tests also enforce name uniqueness. A saved provider must
        # carry its existing ID so the validator excludes that same record.
        if matches: tested['id']=matches[0]['id']
    result=t.request(app,'POST',path,payload=tested)
    # Arr ProviderControllerBase returns the literal string "{}" on HTTP200.
    # Depending on content negotiation, transport decodes an empty object or
    # a JSON string containing that object. HTTP400 validation remains fatal.
    if result not in [None,{},[],'{}','']: raise ValueError(app+' connection test failed '+response_summary(result))

def reconcile(t,app,path,desired,key='name'):
    records=t.request(app,'GET',path)
    if not isinstance(records,list): raise ValueError('invalid managed-resource response')
    matches=[r for r in records if r.get(key)==desired[key]]
    if len(matches)>1: raise ValueError('ambiguous managed resource')
    if matches:
        existing=matches[0]
        merged=dict(existing,**desired,id=existing['id'])
        if all(existing.get(k)==v for k,v in desired.items()): return existing
        return t.request(app,'PUT',path+'/'+str(existing['id']),payload=merged)
    return t.request(app,'POST',path,payload=desired)

def protect_arr(t,app):
    prefix='/api/'+('v1' if app=='prowlarr' else 'v3')
    cfg=t.request(app,'GET',prefix+'/config/host')
    cfg.update({'authenticationMethod':'forms','authenticationRequired':'enabled','username':t.secrets[app]['username'],'password':t.secrets[app]['password'],'passwordConfirmation':t.secrets[app]['password'],'analyticsEnabled':False})
    t.request(app,'PUT',prefix+'/config/host/'+str(cfg['id']),payload=cfg)

def categories(t,downloader):
    if downloader=='qbittorrent':
        current=t.request(downloader,'GET','/api/v2/torrents/categories')
        if not isinstance(current,dict): raise ValueError('invalid qBittorrent categories response')
        for name in ['tv','movies']:
            path='/data/downloads/'+name
            if current.get(name,{}).get('savePath')!=path:
                t.request(downloader,'POST','/api/v2/torrents/'+('editCategory' if name in current else 'createCategory'),form={'category':name,'savePath':path})
    else:
        # SAB initializes its default category registry lazily. get_config alone
        # returns an empty config for a clean INI until get_cats initializes it.
        t.request(downloader,'POST','/api',form={'mode':'get_cats'})
        response=t.request(downloader,'POST','/api',form={'mode':'get_config','section':'categories'})
        if not isinstance(response.get('config',{}).get('categories'),list): raise ValueError('invalid SAB configuration response '+response_summary(response))
        for name in ['tv','movies']:
            t.request(downloader,'POST','/api',form={'mode':'set_config','section':'categories','name':name,'dir':'/data/downloads/'+name,'pp':'3','script':'Default','priority':'0'})

def configure_apps(config,transport,attempts=12):
    t=transport; downloader=config['downloader']
    for app in ['sonarr','radarr','prowlarr',downloader]: ready(t,app,attempts)
    for app in ['sonarr','radarr','prowlarr']: protect_arr(t,app)
    categories(t,downloader)
    for app,category,root in [('sonarr','tv','/data/media/tv'),('radarr','movies','/data/media/movies')]:
        prefix='/api/v3'
        reconcile(t,app,prefix+'/rootfolder',{'path':root},key='path')
        schema=t.request(app,'GET',prefix+'/downloadclient/schema')
        implementation='QBittorrent' if downloader=='qbittorrent' else 'Sabnzbd'
        field_names={f['name'] for s in schema if s.get('implementation')==implementation for f in s['fields']}
        fields={'host':downloader,'port':8080,'useSsl':False,'urlBase':'','username':t.secrets[downloader]['username'],'password':t.secrets[downloader]['password']}
        category_field='tvCategory' if app=='sonarr' else 'movieCategory'
        if category_field not in field_names and 'category' in field_names: category_field='category'
        fields[category_field]=category
        if downloader=='sabnzbd': fields['apiKey']=t.secrets[downloader]['apiKey']
        desired=schema_payload(schema,implementation,fields)
        desired.update({'name':'MediaKit '+downloader,'enable':True,'priority':1,'removeCompletedDownloads':True,'removeFailedDownloads':True})
        test_provider(t,app,prefix+'/downloadclient/test',desired)
        reconcile(t,app,prefix+'/downloadclient',desired)
    schema=t.request('prowlarr','GET','/api/v1/applications/schema')
    for app in ['sonarr','radarr']:
        desired=schema_payload(schema,app.capitalize(),{'prowlarrUrl':'http://prowlarr:9696','baseUrl':'http://'+app+':'+str(PORTS[app]),'apiKey':t.secrets[app]['apiKey'],'syncCategories':[5000] if app=='sonarr' else [2000]})
        desired.update({'name':'MediaKit '+app,'syncLevel':'fullSync'})
        test_provider(t,'prowlarr','/api/v1/applications/test',desired)
        reconcile(t,'prowlarr','/api/v1/applications',desired)
    return {'checks':{'connections':True},'pendingSteps':list(PENDING)}

def set_hardlinks(t,app,enabled):
    cfg=t.request(app,'GET','/api/v3/config/mediamanagement')
    cfg['copyUsingHardlinks']=bool(enabled)
    t.request(app,'PUT','/api/v3/config/mediamanagement/'+str(cfg['id']),payload=cfg)
    return {'hardlinks':enabled,'guidance':None if enabled else 'SMB hardlinks unavailable; copy imports use extra disk space while torrents seed'}

def verify_preferences(t):
    for app,profile_name in [('sonarr','WEB-1080p'),('radarr','HD Bluray + WEB')]:
        profiles=t.request(app,'GET','/api/v3/qualityprofile')
        matches=[p for p in profiles if p.get('name')==profile_name]
        if len(matches)!=1 or not matches[0].get('upgradeAllowed'): raise ValueError('expected quality profile not verified')
        p=matches[0]
        candidates={item.get('id',item.get('quality',{}).get('id')) for item in p['items'] if item.get('name',item.get('quality',{}).get('name'))=='WEB 1080p'}
        if p.get('cutoff') not in candidates: raise ValueError('WEB 1080p cutoff not verified')
        naming=t.request(app,'GET','/api/v3/config/naming')
        if not naming.get('renameEpisodes' if app=='sonarr' else 'renameMovies'): raise ValueError('media naming not verified')
    return True

def reconcile_seerr(t):
    public=t.request('seerr','GET','/api/v1/settings/public')
    if not public.get('initialized'): return ['Seerr Plex sign-in and library selection']
    libraries=t.request('seerr','GET','/api/v1/settings/plex/library')
    pending=[]
    if not {x.get('type') for x in libraries if x.get('enabled')} >= {'movie','show'}: pending.append('Seerr Movies/TV library selection')
    for app,root,profile_name in [('sonarr','/data/media/tv','WEB-1080p'),('radarr','/data/media/movies','HD Bluray + WEB')]:
        profiles=t.request(app,'GET','/api/v3/qualityprofile'); match=next((p for p in profiles if p.get('name')==profile_name),None)
        if not match: raise ValueError('request service quality profile missing')
        record={'name':'MediaKit '+app,'hostname':app,'port':PORTS[app],'apiKey':t.secrets[app]['apiKey'],'useSsl':False,'baseUrl':'','activeProfileId':match['id'],'activeProfileName':profile_name,'activeDirectory':root,'is4k':False,'isDefault':True,'externalUrl':'','tags':[],'syncEnabled':True,'preventSearch':False,'tagRequests':False,'overrideRule':[]}
        if app=='sonarr': record.update({'enableSeasonFolders':True,'seriesType':'standard','animeSeriesType':'anime','activeAnimeProfileId':match['id'],'activeAnimeProfileName':profile_name,'activeAnimeDirectory':root,'animeTags':[],'monitorNewItems':'all'})
        else: record['minimumAvailability']='released'
        t.request('seerr','POST','/api/v1/settings/'+app+'/test',payload=record)
        reconcile(t,'seerr','/api/v1/settings/'+app,record)
    return pending

def verify_apps(config,transport):
    checks={}; pending=[]
    for app in ['sonarr','radarr','prowlarr',config['downloader']]:
        try: ready(transport,app,attempts=1); checks[app]=True
        except Exception: checks[app]=False
    try:
        downloader=config['downloader']
        if downloader=='qbittorrent': current=transport.request(downloader,'GET','/api/v2/torrents/categories'); paths={name:category.get('savePath') for name,category in current.items()}
        else:
            current=transport.request(downloader,'POST','/api',form={'mode':'get_config','section':'categories'})
            paths={category['name']:category.get('dir') for category in current['config']['categories']}
        checks['downloadCategories']=all(paths.get(name)=='/data/downloads/'+name for name in ['tv','movies'])
    except Exception: checks['downloadCategories']=False
    try:
        for app,root in [('sonarr','/data/media/tv'),('radarr','/data/media/movies')]:
            roots=transport.request(app,'GET','/api/v3/rootfolder')
            if not any(r.get('path')==root for r in roots): raise ValueError()
            clients=transport.request(app,'GET','/api/v3/downloadclient')
            match=[r for r in clients if r.get('name')=='MediaKit '+config['downloader'] and r.get('enable')]
            if len(match)!=1: raise ValueError()
            test_provider(transport,app,'/api/v3/downloadclient/test',match[0])
        applications=transport.request('prowlarr','GET','/api/v1/applications')
        for app in ['sonarr','radarr']:
            match=[r for r in applications if r.get('name')=='MediaKit '+app]
            if len(match)!=1: raise ValueError()
            test_provider(transport,'prowlarr','/api/v1/applications/test',match[0])
        checks['connections']=True
    except Exception: checks['connections']=False
    try:
        indexers=transport.request('prowlarr','GET','/api/v1/indexer')
        if not any(i.get('enable') for i in indexers): pending.append('Indexer/provider credentials')
    except Exception: pending.append('Indexer/provider credentials')
    try:
        public=transport.request('seerr','GET','/api/v1/settings/public')
        if not isinstance(public,dict) or 'initialized' not in public: raise ValueError('invalid requests service response')
        checks['seerr']=True
        if not public.get('initialized'): pending.extend(PENDING[:2])
        else:
            libraries=transport.request('seerr','GET','/api/v1/settings/plex/library')
            if not {x.get('type') for x in libraries if x.get('enabled')} >= {'movie','show'}: pending.append('Seerr Movies/TV library selection')
            for app in ['sonarr','radarr']:
                servers=transport.request('seerr','GET','/api/v1/settings/'+app)
                if not any(s.get('name')=='MediaKit '+app for s in servers): pending.append('Seerr '+app+' connection')
    except Exception: checks['seerr']=False; pending.extend(PENDING[:2])
    return {'checks':checks,'pendingSteps':pending}
