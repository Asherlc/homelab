#!/usr/bin/env python3
"""CI production-container check on a private network, no published HTTP ports.

Uses only unique media-kit-test-* resources. Requires Docker and sufficient disk
space for release-pinned images. No provider downloads or existing stack touched.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import bootstrap
import kit_secrets
from test_core import CONTRACT,GUEST

def invoke(args):
    result=subprocess.run(args,capture_output=True,text=True,timeout=600)
    if result.returncode: raise RuntimeError('isolated container command failed')
    return result.stdout

def compose(path,*args): return invoke(['docker','compose','-p',path.name,'-f',str(path/'compose.json'),*args])

def driver(path,release,action):
    return invoke(['docker','run','--rm','--name',path.name+'-driver','--platform','linux/amd64','--network',path.name+'-media','--user','0:0','--entrypoint','python3','--volume',str(GUEST)+':/source:ro','--volume',str(path)+':/fixture',release['images']['sabnzbd'],'/source/tests/container_probe.py',action])

def run(downloader):
    path=Path(tempfile.mkdtemp(prefix='media-kit-test-')); path.chmod(0o700)
    config=dict(CONTRACT,downloader=downloader); release=json.loads((GUEST.parent/'release.json').read_text())
    bootstrap.validate_release(release,config)
    secrets={app:{'username':'mediaadmin','password':kit_secrets.token(),'apiKey':os.urandom(16).hex()} for app in bootstrap.PORTS}
    for name,value in [('secrets.json',secrets),('config.json',config),('release.json',release)]: kit_secrets.atomic_write(path/name,json.dumps(value))
    doc=bootstrap.compose(config,release,'127.0.0.1')
    for app,service in doc['services'].items():
        service.pop('ports',None); service['platform']='linux/amd64'; service['restart']='no'
        service['volumes']=[v.replace(str(bootstrap.STATE),str(path/'state')).replace('/data:/data',str(path/'data')+':/data') for v in service['volumes']]
    doc['networks']['media']={'external':True,'name':path.name+'-media'}
    kit_secrets.atomic_write(path/'compose.json',json.dumps(doc))
    invoke(['docker','network','create','--label','media-kit-test-owner='+path.name,path.name+'-media'])
    try:
        driver(path,release,'seed'); compose(path,'up','-d')
        print(driver(path,release,'configure').strip())
        compose(path,'--profile','configure','run','--rm','configarr')
        print(driver(path,release,'verify').strip())
        for app in ['sonarr','radarr']:
            target='/data/media/'+('tv' if app=='sonarr' else 'movies')+'/.probe-ci'
            script='set -eu; trap \'rm -f "$1" "$2"\' EXIT; printf first > "$1"; ln "$1" "$2"; printf changed > "$1"; test "$(cat "$2")" = changed'
            compose(path,'exec','-T','--user','1000:1000',app,'sh','-c',script,'probe','/data/downloads/.probe-ci',target)
        print(json.dumps({'downloader':downloader,'phase':'integration-passed','hardlinksInActualArrContainers':True}))
    except Exception:
        # App logs may contain credentials. Redact before diagnostics.
        try:
            logs=compose(path,'logs','--tail','60')
            for record in secrets.values():
                for value in record.values(): logs=logs.replace(value,'[REDACTED]')
            print(logs,file=sys.stderr)
        except Exception: pass
        raise
    finally:
        try: compose(path,'down','--volumes','--remove-orphans')
        finally:
            try: driver(path,release,'cleanup')
            except Exception: pass
            invoke(['docker','network','rm',path.name+'-media'])
            shutil.rmtree(path,ignore_errors=True)

if __name__=='__main__':
    p=argparse.ArgumentParser(); p.add_argument('--downloader',choices=['qbittorrent','sabnzbd'],required=True); a=p.parse_args(); run(a.downloader)
