#!/usr/bin/env python3
"""Root guest entry point. Stdlib only, public JSON output never includes secrets."""
import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import subprocess
import stat
import time
import uuid
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError
import xml.etree.ElementTree as ET
import kit_secrets
import storage

BASE=Path('/etc/starter-kit')
STATE=Path('/var/lib/starter-kit')
SOURCE=Path(__file__).resolve().parent
PORTS={'sonarr':8989,'radarr':7878,'prowlarr':9696,'seerr':5055,'qbittorrent':8080,'sabnzbd':8080}
FIELDS={'schemaVersion','installationId','releaseId','hostname','timezone','downloader','hostIP','guestIP','prefixLength','network','smb'}

def validate(c):
    if not isinstance(c,dict) or set(c)!=FIELDS or type(c['schemaVersion']) is not int or c['schemaVersion']!=1: raise ValueError('unsupported guest configuration')
    try: uuid.UUID(c['installationId'])
    except (ValueError,TypeError,AttributeError): raise ValueError('invalid installation identity') from None
    for key in ['releaseId','hostname']:
        if not isinstance(c[key],str) or not re.fullmatch(r'[a-z0-9][a-z0-9.-]{0,62}',c[key]): raise ValueError('invalid public identity')
    if c['downloader'] not in ['qbittorrent','sabnzbd']: raise ValueError('choose exactly one downloader')
    if not isinstance(c['timezone'],str) or '..' in c['timezone'] or c['timezone'].startswith('/'): raise ValueError('invalid timezone')
    try: ZoneInfo(c['timezone'])
    except (ZoneInfoNotFoundError,ValueError): raise ValueError('invalid timezone') from None
    if type(c['prefixLength']) is not int or not 16<=c['prefixLength']<=30: raise ValueError('invalid prefix')
    try:
        host=ipaddress.IPv4Address(c['hostIP']); guest=ipaddress.IPv4Address(c['guestIP']); net=ipaddress.IPv4Network(str(host)+'/'+str(c['prefixLength']),strict=False)
        private=[ipaddress.IPv4Network(n) for n in ['10.0.0.0/8','172.16.0.0/12','192.168.0.0/16']]
        if host==guest or guest not in net or any(x in [net.network_address,net.broadcast_address] or not any(x in n for n in private) for x in [host,guest]): raise ValueError()
    except (ValueError,TypeError): raise ValueError('invalid private host/guest subnet') from None
    if not isinstance(c['network'],dict) or set(c['network'])!={'internalMac','externalMac'}: raise ValueError('invalid network projection')
    macs=list(c['network'].values())
    if any(not isinstance(x,str) or not re.fullmatch('[0-9A-Fa-f]{12}',x) or int(x[:2],16)&1 for x in macs) or macs[0].lower()==macs[1].lower(): raise ValueError('invalid distinct unicast MAC addresses')
    smb=c['smb']
    if not isinstance(smb,dict) or set(smb)!={'account','domain','share','credentialsRef'}: raise ValueError('invalid SMB projection')
    if smb['credentialsRef']!='/run/starter-kit-secrets/smb.credentials': raise ValueError('invalid credential reference')
    for key in ['account','domain','share']:
        if not isinstance(smb[key],str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,79}',smb[key]): raise ValueError('unsafe SMB identifier')
    return c

def validate_release(release,c):
    if release.get('schemaVersion')!=1 or release.get('releaseId')!=c['releaseId']: raise ValueError('release identity mismatch')
    keys=set(PORTS)|{'configarr'}
    if set(release.get('images',{}))!=keys: raise ValueError('incomplete pinned images')
    for value in release['images'].values():
        if not isinstance(value,str) or not re.fullmatch(r'[A-Za-z0-9./:_-]+@sha256:[0-9a-f]{64}',value): raise ValueError('image digest required')
    if set(release.get('templateRevisions',{}))!={'trash','recyclarr'} or any(not re.fullmatch('[0-9a-f]{40}',str(x)) for x in release['templateRevisions'].values()): raise ValueError('template commit required')

def compose(c,release,bind):
    validate(c); validate_release(release,c)
    ipaddress.IPv4Address(bind)
    services={}
    for app in ['sonarr','radarr','prowlarr','seerr',c['downloader']]:
        volumes=[str(STATE/app)+':'+('/app/config' if app=='seerr' else '/config')]
        if app in ['sonarr','radarr',c['downloader']]: volumes.append('/data:/data')
        environment={'TZ':c['timezone'],'PUID':'1000','PGID':'1000'}
        if app=='qbittorrent': environment['WEBUI_PORT']='8080'
        services[app]={'image':release['images'][app],'restart':'unless-stopped','volumes':volumes,'environment':environment,'ports':[bind+':'+str(PORTS[app])+':'+str(PORTS[app])],'networks':['media']}
    services['configarr']={'image':release['images']['configarr'],'profiles':['configure'],'volumes':[str(STATE/'configarr')+':/app/config',str(STATE/'configarr/repos')+':/app/repos'],'environment':{'TZ':c['timezone']},'networks':['media']}
    return {'services':services,'networks':{'media':{}}}

def app_credentials(c):
    return kit_secrets.create_once(BASE/'app-secrets.json',c['installationId'],{app:{'apiKey':os.urandom(16).hex(),'username':'mediaadmin','password':kit_secrets.token()} for app in PORTS})

def write_initial_configs(c,secrets,state=STATE):
    for app in ['sonarr','radarr','prowlarr','seerr',c['downloader'],'configarr']:
        folder=Path(state)/app; folder.mkdir(mode=0o700,parents=True,exist_ok=True)
        os.chown(folder,1000,1000)
        if app in ['sonarr','radarr','prowlarr']:
            path=folder/'config.xml'
            if not path.exists():
                node=ET.Element('Config')
                values={'BindAddress':'*','Port':str(PORTS[app]),'SslPort':str(PORTS[app]+1),'EnableSsl':'False','ApiKey':secrets[app]['apiKey'],'AuthenticationMethod':'Forms','AuthenticationRequired':'Enabled','Username':secrets[app]['username'],'Password':secrets[app]['password'],'LaunchBrowser':'False','LogLevel':'warn'}
                for key,value in values.items(): ET.SubElement(node,key).text=value
                kit_secrets.atomic_write(path,ET.tostring(node,encoding='unicode'))
                os.chown(path,1000,1000)
        if app==c['downloader']:
            if app=='qbittorrent':
                path=folder/'qBittorrent/qBittorrent.conf'
                salt=os.urandom(16); digest=hashlib.pbkdf2_hmac('sha512',secrets[app]['password'].encode(),salt,100000,64)
                import base64
                password='@ByteArray('+base64.b64encode(salt).decode()+':'+base64.b64encode(digest).decode()+')'
                content=(SOURCE/'templates/qbittorrent.conf').read_text().replace('{{username}}',secrets[app]['username']).replace('{{password_hash}}',password)
            else:
                path=folder/'sabnzbd.ini'
                content=(SOURCE/'templates/sabnzbd.ini').read_text().replace('{{username}}',secrets[app]['username']).replace('{{password}}',secrets[app]['password']).replace('{{api_key}}',secrets[app]['apiKey'])
            if not path.exists(): kit_secrets.atomic_write(path,content); os.chown(path.parent,1000,1000); os.chown(path,1000,1000)

def adopt_seerr_credentials(c,secrets,state=STATE,secret_path=BASE/'app-secrets.json',attempts=30):
    path=Path(state)/'seerr/settings.json'
    live_key=None
    for attempt in range(attempts):
        try:
            parent=path.parent.lstat()
            if not stat.S_ISDIR(parent.st_mode) or parent.st_uid not in [os.geteuid(),1000] or parent.st_mode & 0o077: raise ValueError('requests settings folder must be private')
            fd=os.open(path,os.O_RDONLY|getattr(os,'O_NOFOLLOW',0))
            with os.fdopen(fd,'r') as f:
                info=os.fstat(f.fileno())
                if not stat.S_ISREG(info.st_mode) or info.st_uid not in [parent.st_uid,os.geteuid()] or info.st_mode & 0o002: raise ValueError('unsafe requests settings file')
                record=json.load(f)
            live_key=record.get('main',{}).get('apiKey')
            if not isinstance(live_key,str) or not re.fullmatch(r'[A-Za-z0-9+/=_-]{16,256}',live_key): raise ValueError('requests key not initialized')
            break
        except (OSError,ValueError):
            if attempt+1>=attempts: raise ValueError('requests native key readiness failed') from None
            time.sleep(2)
    if secrets['seerr'].get('keySource')=='application':
        if secrets['seerr']['apiKey']!=live_key: raise ValueError('requests native key changed; review protected credentials')
        return secrets
    secrets['seerr']['apiKey']=live_key; secrets['seerr']['keySource']='application'
    kit_secrets.atomic_write(secret_path,json.dumps({'installationId':c['installationId'],'values':secrets},sort_keys=True))
    return secrets

def interface_name(mac):
    expected=':'.join(mac[i:i+2] for i in range(0,12,2)).lower()
    matches=[p.parent.name for p in Path('/sys/class/net').glob('*/address') if p.read_text().strip().lower()==expected]
    if len(matches)!=1: raise ValueError('assigned MAC interface not found')
    return matches[0]

def install_system(c,state_uuid):
    data=Path('/data'); data.mkdir(mode=0o700,exist_ok=True); data.chmod(0o700)
    STATE.mkdir(mode=0o700,parents=True,exist_ok=True); STATE.chmod(0o700)
    internal=interface_name(c['network']['internalMac']); external=interface_name(c['network']['externalMac'])
    net={'network':{'version':2,'ethernets':{internal:{'match':{'macaddress':':'.join(c['network']['internalMac'][i:i+2] for i in range(0,12,2))},'addresses':[c['guestIP']+'/'+str(c['prefixLength'])],'dhcp4':False,'dhcp6':False,'link-local':[]},external:{'match':{'macaddress':':'.join(c['network']['externalMac'][i:i+2] for i in range(0,12,2))},'dhcp4':True}}}}
    kit_secrets.atomic_write('/etc/netplan/90-starter-kit.yaml',json.dumps(net))
    kit_secrets.atomic_write('/etc/avahi/avahi-daemon.conf','[server]\nhost-name='+c['hostname']+'\nallow-interfaces='+external+'\nuse-ipv6=no\n[publish]\npublish-addresses=yes\npublish-workstation=no\n[reflector]\nenable-reflector=no\n',0o644)
    for template in (SOURCE/'systemd').rglob('*'):
        if not template.is_file(): continue
        relative=template.relative_to(SOURCE/'systemd')
        if str(relative)=='starter-kit-state.mount': relative=Path('var-lib-starter\\x2dkit.mount')
        text=template.read_text().replace('{{hostIP}}',c['hostIP']).replace('{{share}}',c['smb']['share']).replace('{{stateUUID}}',state_uuid)
        kit_secrets.atomic_write(Path('/etc/systemd/system')/relative,text,0o644)
    kit_secrets.atomic_write('/etc/docker/daemon.json',json.dumps({'data-root':str(STATE/'docker'),'log-driver':'local'}),0o600)
    storage.run(['netplan','apply']); storage.run(['hostnamectl','set-hostname',c['hostname']]); storage.run(['timedatectl','set-timezone',c['timezone']]); storage.run(['systemctl','daemon-reload'])
    storage.run(['systemctl','start','data.mount','var-lib-starter\\x2dkit.mount'])
    storage.verify(c)
    kit_secrets.atomic_write(STATE/storage.MARKER,json.dumps({'schemaVersion':1,'installationId':c['installationId']}))
    storage.run(['systemctl','enable','starter-kit-apps.service'])
    storage.run(['systemctl','enable','--now','storage-retry.timer','avahi-daemon.service'])

def docker(*args): return storage.run(['docker','compose','-p','starter-kit','-f',str(BASE/'compose.json'),*args])

def cleanup_seed(cloud=Path('/var/lib/cloud'),disable_path=Path('/etc/cloud/cloud-init.disabled')):
    # Keep instance ID and semaphores: cloud-init clean would reset SSH identity on reboot.
    cloud=Path(cloud)
    kit_secrets.atomic_write(disable_path,'Provisioning completed; persistent guest bootstrap owns configuration.\n',0o644)
    for instance in (cloud/'instances').glob('*'):
        if instance.is_dir() and not instance.is_symlink():
            for name in ['user-data.txt','user-data.txt.i','vendor-data.txt','vendor-data.txt.i','vendor-data2.txt','vendor-data2.txt.i','obj.pkl','cloud-config.txt','instance-data-sensitive.json']:
                (instance/name).unlink(missing_ok=True)
    for name in ['nocloud','nocloud-net']:
        seed=cloud/'seed'/name
        for file in ['user-data','vendor-data']: (seed/file).unlink(missing_ok=True)
    for log in ['/var/log/cloud-init.log','/var/log/cloud-init-output.log']:
        if cloud==Path('/var/lib/cloud'): Path(log).unlink(missing_ok=True)
    if cloud==Path('/var/lib/cloud'):
        Path('/run/cloud-init/instance-data-sensitive.json').unlink(missing_ok=True)

@contextmanager
def exclusive_apply_lock(path=Path('/run/starter-kit-apply.lock'),timeout=120):
    fd=os.open(path,os.O_CREAT|os.O_RDWR|getattr(os,'O_NOFOLLOW',0),0o600)
    try:
        info=os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid!=os.geteuid() or info.st_mode & 0o077: raise ValueError('unsafe provisioning lock')
        deadline=time.monotonic()+timeout
        while True:
            try: fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB); break
            except BlockingIOError:
                if time.monotonic()>=deadline: raise ValueError('guest apply is already running; retry after provisioning completes') from None
                time.sleep(min(0.1,max(0,deadline-time.monotonic())))
        yield
    finally:
        fcntl.flock(fd,fcntl.LOCK_UN); os.close(fd)

def apply(c,release):
    validate(c); validate_release(release,c)
    if os.geteuid()!=0: raise ValueError('guest apply requires root')
    with exclusive_apply_lock(): return _apply_locked(c,release)

def _apply_locked(c,release):
    validate(c); validate_release(release,c)
    if os.geteuid()!=0: raise ValueError('guest apply requires root')
    BASE.mkdir(mode=0o700,parents=True,exist_ok=True); BASE.chmod(0o700)
    if (BASE/'config.json').exists():
        old=json.loads((BASE/'config.json').read_text())
        for field in ['installationId','hostname','hostIP','guestIP','network','smb','downloader']:
            if old[field]!=c[field]: raise ValueError('resume configuration ownership mismatch')
    credpath=BASE/'smb.credentials'
    if not credpath.exists():
        creds=kit_secrets.read_credentials(c['smb']['credentialsRef'])
        if creds['username']!=c['smb']['account'] or creds['domain']!=c['smb']['domain']: raise ValueError('SMB credential account mismatch')
        kit_secrets.atomic_write(credpath,'\n'.join(k+'='+v for k,v in creds.items())+'\n')
    kit_secrets.read_credentials(credpath)
    kit_secrets.atomic_write(BASE/'config.json',json.dumps(c,sort_keys=True))
    kit_secrets.atomic_write(BASE/'setup-state.json',json.dumps({'installationId':c['installationId'],'releaseId':c['releaseId'],'phase':'applying','pendingSteps':['Guest configuration and verification']}))
    state_uuid=storage.initialize_state()
    storage_identity=kit_secrets.create_once(BASE/'storage.json',c['installationId'],{'uuid':state_uuid})
    if storage_identity['uuid']!=state_uuid: raise ValueError('appstate UUID changed')
    install_system(c,state_uuid)
    secrets=app_credentials(c); write_initial_configs(c,secrets)
    for name in ['downloads/tv','downloads/movies','downloads/incomplete','media/tv','media/movies']: (Path('/data')/name).mkdir(parents=True,exist_ok=True)
    kit_secrets.atomic_write(BASE/'compose.json',json.dumps(compose(c,release,'127.0.0.1')))
    storage.run(['systemctl','start','docker.service']); docker('up','-d')
    secrets=adopt_seerr_credentials(c,secrets)
    import api_setup
    transport=api_setup.HTTPTransport(secrets)
    result=api_setup.configure_apps(c,transport)
    configarr=(SOURCE/'templates/configarr.yml').read_text().replace('{{trashRevision}}',release['templateRevisions']['trash']).replace('{{recyclarrRevision}}',release['templateRevisions']['recyclarr'])
    kit_secrets.atomic_write(STATE/'configarr/config.yml',configarr)
    kit_secrets.atomic_write(STATE/'configarr/secrets.yml','SONARR_API_KEY: '+secrets['sonarr']['apiKey']+'\nRADARR_API_KEY: '+secrets['radarr']['apiKey']+'\n')
    docker('--profile','configure','run','--rm','configarr')
    api_setup.verify_preferences(transport)
    storage_guidance=[]
    for app in ['sonarr','radarr']:
        link_result=api_setup.set_hardlinks(transport,app,storage.probe_hardlinks(app=app))
        if link_result['guidance'] and link_result['guidance'] not in storage_guidance: storage_guidance.append(link_result['guidance'])
    try: api_setup.reconcile_seerr(transport)
    except Exception: pass  # Account/token/library choices remain an explicit handoff.
    health=api_setup.verify_apps(c,transport)
    if not all(health['checks'].values()): raise ValueError('application integration verification failed')
    # Authenticated web services may now be published; Seerr itself gates first-use account setup.
    kit_secrets.atomic_write(BASE/'compose.json',json.dumps(compose(c,release,'0.0.0.0')))
    docker('up','-d')
    kit_secrets.atomic_write(BASE/'setup-state.json',json.dumps({'installationId':c['installationId'],'releaseId':c['releaseId'],'phase':'account-handoff','pendingSteps':health['pendingSteps'],'storageGuidance':storage_guidance}))
    seed=Path(c['smb']['credentialsRef'])
    seed.unlink(missing_ok=True)
    cleanup_seed()
    return status(c)

def status(c):
    validate(c); checks={}; pending=['Plex claim and Movies/TV libraries','Seerr Plex sign-in and library selection','Indexer/provider credentials']
    try: storage.verify(c); checks['storage']=True
    except Exception: checks['storage']=False
    try:
        import api_setup
        secrets=json.loads(kit_secrets.read_private(BASE/'app-secrets.json'))
        if secrets['installationId']!=c['installationId']: raise ValueError()
        health=api_setup.verify_apps(c,api_setup.HTTPTransport(secrets['values']))
        checks.update(health['checks']); pending=health['pendingSteps']
    except Exception: checks['applications']=False
    addresses=[]
    try:
        iface=interface_name(c['network']['externalMac'])
        addresses=[a['local'] for item in json.loads(storage.run(['ip','-json','address','show','dev',iface])) for a in item['addr_info'] if a['family']=='inet']
    except Exception: pass
    guidance=[]
    checks['bootstrap']=False
    try:
        prior=json.loads((BASE/'setup-state.json').read_text())
        if prior['installationId']==c['installationId']: guidance=prior.get('storageGuidance',[])
        checks['bootstrap']=prior.get('installationId')==c['installationId'] and prior.get('releaseId')==c['releaseId'] and prior.get('phase')=='account-handoff'
    except Exception: pass
    return {'installationId':c['installationId'],'releaseId':c['releaseId'],'phase':'account-handoff' if all(checks.values()) else 'blocked','downloader':c['downloader'],'checks':checks,'pendingSteps':pending,'hostname':c['hostname']+'.local','lanAddresses':addresses,'storageGuidance':guidance}

def main():
    parser=argparse.ArgumentParser(); parser.add_argument('action',choices=['validate','apply','status']); parser.add_argument('--config',default=str(BASE/'config.json'))
    args=parser.parse_args(); c={}
    try:
        c=validate(json.loads(Path(args.config).read_text()))
        if args.action=='validate': result={'installationId':c['installationId'],'releaseId':c['releaseId'],'phase':'validated','downloader':c['downloader'],'checks':{'configuration':True},'pendingSteps':[]}
        elif args.action=='apply': result=apply(c,json.loads(Path('/opt/starter-kit/release.json').read_text()))
        else: result=status(c)
        print(json.dumps(result)); return 0 if result['phase']!='blocked' else 1
    except Exception:
        print(json.dumps({'installationId':c.get('installationId'),'releaseId':c.get('releaseId'),'downloader':c.get('downloader'),'phase':'blocked','checks':{'configurationOrApply':False},'pendingSteps':['Review guest configuration, storage, and authenticated service readiness']})); return 1

if __name__=='__main__': raise SystemExit(main())
