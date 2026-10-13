#!/usr/bin/env python3
"""Consistent private guest backup; excludes media and replaceable Docker cache."""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import stat
import tarfile
import tempfile
import bootstrap
import storage

APPS={'sonarr','radarr','prowlarr','seerr','qbittorrent','sabnzbd','configarr'}
ETC_FILES={'app-secrets.json','smb.credentials','config.json','setup-state.json','compose.json','storage.json'}

def digest_file(path):
    result=hashlib.sha256()
    with open(path,'rb') as f:
        for chunk in iter(lambda:f.read(1024*1024),b''): result.update(chunk)
    return result.hexdigest()

def control(action): bootstrap.docker('stop' if action=='stop' else 'start')

def create_backup(config,destination,state=bootstrap.STATE,etc=bootstrap.BASE,service_control=control):
    destination=Path(destination); state=Path(state); etc=Path(etc)
    if destination.exists() or destination.is_symlink(): raise ValueError('backup destination already exists')
    destination.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
    fd,temp=tempfile.mkstemp(prefix='.backup-',dir=destination.parent); os.close(fd); os.chmod(temp,0o600)
    try:
        service_control('stop')
        entries=[]
        for folder in sorted(APPS):
            root=state/folder
            if root.is_symlink(): raise ValueError('backup source symlink forbidden')
            if root.exists():
                for path in sorted(root.rglob('*')):
                    if path.is_symlink() or not (path.is_file() or path.is_dir()): raise ValueError('unsafe backup source')
                    if path.is_file(): entries.append(('state/'+path.relative_to(state).as_posix(),path))
        for name in sorted(ETC_FILES):
            path=etc/name
            if path.is_symlink(): raise ValueError('backup credential symlink forbidden')
            if path.exists():
                if not path.is_file(): raise ValueError('unsafe backup credential source')
                entries.append(('etc/'+name,path))
        metadata={'schemaVersion':1,'installationId':config['installationId'],'releaseId':config['releaseId'],'downloader':config['downloader'],'files':{}}
        with tarfile.open(temp,'w') as archive:
            for name,path in entries:
                record={'sha256':digest_file(path),'size':path.stat().st_size,'mode':path.stat().st_mode & 0o777,'uid':path.stat().st_uid,'gid':path.stat().st_gid}
                metadata['files'][name]=record
                info=tarfile.TarInfo(name); info.size=record['size']; info.mode=0o600; info.mtime=0
                with path.open('rb') as f: archive.addfile(info,f)
            raw=json.dumps(metadata,sort_keys=True).encode(); info=tarfile.TarInfo('manifest.json'); info.size=len(raw); info.mode=0o600; archive.addfile(info,io.BytesIO(raw))
        with open(temp,'rb') as f: os.fsync(f.fileno())
        os.replace(temp,destination)
        return {'installationId':config['installationId'],'releaseId':config['releaseId'],'phase':'backed-up','sha256':digest_file(destination),'files':len(entries)}
    finally:
        if os.path.exists(temp): os.unlink(temp)
        service_control('start')

def main():
    parser=argparse.ArgumentParser(); parser.add_argument('--config',default=str(bootstrap.BASE/'config.json')); parser.add_argument('--output',required=True); args=parser.parse_args()
    try:
        c=bootstrap.validate(json.loads(Path(args.config).read_text()))
        if os.geteuid()!=0: raise ValueError()
        storage.verify(c); print(json.dumps(create_backup(c,args.output))); return 0
    except Exception: print(json.dumps({'phase':'backup-failed','reason':'backup validation or stopped-state archive failed'})); return 1

if __name__=='__main__': raise SystemExit(main())
