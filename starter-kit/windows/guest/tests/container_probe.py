"""Private network integration driver inside the release-pinned SAB Python image."""
import json
import os
from pathlib import Path
import shutil
import sys
sys.path.insert(0,'/source')
import api_setup
import bootstrap
import kit_secrets

path=Path('/fixture'); action=sys.argv[1]
if action=='cleanup':
    for name in ['state','data']: shutil.rmtree(path/name,ignore_errors=True)
    raise SystemExit(0)
config=json.loads((path/'config.json').read_text()); secrets=json.loads((path/'secrets.json').read_text()); release=json.loads((path/'release.json').read_text())
if action=='seed':
    bootstrap.write_initial_configs(config,secrets,path/'state')
    for name in ['downloads','downloads/tv','downloads/movies','downloads/incomplete','media/tv','media/movies']:
        folder=path/'data'/name; folder.mkdir(parents=True,exist_ok=True); os.chown(folder,1000,1000); folder.chmod(0o775)
    rendered=(bootstrap.SOURCE/'templates/configarr.yml').read_text()
    for key in ['trash','recyclarr']: rendered=rendered.replace('{{'+key+'Revision}}',release['templateRevisions'][key])
    kit_secrets.atomic_write(path/'state/configarr/config.yml',rendered)
    kit_secrets.atomic_write(path/'state/configarr/secrets.yml','SONARR_API_KEY: '+secrets['sonarr']['apiKey']+'\nRADARR_API_KEY: '+secrets['radarr']['apiKey']+'\n')
elif action=='configure':
    secrets=bootstrap.adopt_seerr_credentials(config,secrets,path/'state',path/'app-secrets.json')
    t=api_setup.HTTPTransport(secrets,in_container=True)
    api_setup.configure_apps(config,t,attempts=30)
    first={app:t.request(app,'GET','/api/v3/downloadclient')[0]['id'] for app in ['sonarr','radarr']}
    api_setup.configure_apps(config,t,attempts=1)
    for app in ['sonarr','radarr']:
        clients=t.request(app,'GET','/api/v3/downloadclient')
        if len(clients)!=1 or clients[0]['id']!=first[app]: raise ValueError('managed downloader identity changed on resume')
    print(json.dumps({'downloader':config['downloader'],'authenticatedSetupAndResume':True}))
elif action=='verify':
    secrets=json.loads(kit_secrets.read_private(path/'app-secrets.json'))['values']
    t=api_setup.HTTPTransport(secrets,in_container=True); api_setup.verify_preferences(t); health=api_setup.verify_apps(config,t)
    if not all(health['checks'].values()): raise ValueError('integration health failed')
    print(json.dumps({'downloader':config['downloader'],'profileNamingAndCutoffReadback':True,'checks':health['checks'],'pendingSteps':health['pendingSteps']}))
else: raise ValueError('unknown integration action')
