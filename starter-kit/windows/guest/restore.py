#!/usr/bin/env python3
"""Validate every archive entry before stop; staged replacement with rollback."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import tarfile
import tempfile
import backup
import bootstrap
import storage

def allowed(name):
    p=PurePosixPath(name)
    if p.is_absolute() or '..' in p.parts or '\\' in name or p.as_posix()!=name: return False
    return (len(p.parts)>=3 and p.parts[0]=='state' and p.parts[1] in backup.APPS) or (len(p.parts)==2 and p.parts[0]=='etc' and p.parts[1] in backup.ETC_FILES)

def validate_archive(config,archive):
    members=archive.getmembers()
    if len(members)>100000 or sum(m.size for m in members)>8*1024**3: raise ValueError('backup exceeds restore limits')
    names=[m.name for m in members]
    if len(names)!=len(set(names)) or names.count('manifest.json')!=1: raise ValueError('ambiguous archive entries')
    for m in members:
        if not m.isfile() or m.size<0 or (m.name!='manifest.json' and not allowed(m.name)): raise ValueError('unsafe archive member')
    info=archive.getmember('manifest.json')
    if info.size>16*1024*1024: raise ValueError('backup metadata too large')
    metadata=json.load(archive.extractfile(info))
    if metadata.get('schemaVersion')!=1 or any(metadata.get(k)!=config[k] for k in ['installationId','releaseId','downloader']): raise ValueError('backup installation or release mismatch')
    if set(metadata.get('files',{}))!=set(names)-{'manifest.json'}: raise ValueError('backup allowlist mismatch')
    for name,record in metadata['files'].items():
        member=archive.getmember(name)
        if member.size!=record.get('size') or type(record.get('mode')) is not int or record['mode'] & ~0o777 or record['mode'] & 0o002:
            raise ValueError('backup member size or mode invalid')
        if name.startswith('etc/') and record['mode'] & 0o077: raise ValueError('backup secrets must remain private')
        sha=hashlib.sha256()
        with archive.extractfile(member) as f:
            for chunk in iter(lambda:f.read(1024*1024),b''): sha.update(chunk)
        if sha.hexdigest()!=record.get('sha256'): raise ValueError('backup checksum mismatch')
    return metadata

def restore_backup(config,source,state=bootstrap.STATE,etc=bootstrap.BASE,service_control=backup.control):
    state=Path(state); etc=Path(etc)
    if Path(source).is_symlink() or not Path(source).is_file(): raise ValueError('regular backup required')
    with tarfile.open(source,'r') as archive:
        metadata=validate_archive(config,archive)
        with tempfile.TemporaryDirectory(prefix='.restore-',dir=state) as temp:
            temp=Path(temp); staged=temp/'stage'; old=temp/'rollback'; staged.mkdir(); old.mkdir()
            for name,record in metadata['files'].items():
                path=staged/name; path.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
                with archive.extractfile(name) as src,path.open('xb') as dst: shutil.copyfileobj(src,dst,1024*1024); dst.flush(); os.fsync(dst.fileno())
                path.chmod(record['mode'])
                if os.geteuid()==0: os.chown(path,record['uid'],record['gid'])
            targets=[(staged/'state'/app,state/app,'state/'+app) for app in sorted(backup.APPS) if (staged/'state'/app).exists()]
            targets.extend((staged/'etc'/name,etc/name,'etc/'+name) for name in sorted(backup.ETC_FILES) if (staged/'etc'/name).exists())
            replaced=[]
            try:
                service_control('stop')
                for new,target,key in targets:
                    if target.is_symlink(): raise ValueError('restore target symlink forbidden')
                    previous=old/key; previous.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
                    existed=target.exists()
                    if existed: os.replace(target,previous)
                    replaced.append((target,previous,existed))
                    os.replace(new,target)
                    if target.is_dir() and os.geteuid()==0:
                        for path in [target,*[p for p in target.rglob('*') if p.is_dir()]]: os.chown(path,1000,1000)
            except Exception:
                for target,previous,existed in reversed(replaced):
                    if target.is_dir(): shutil.rmtree(target)
                    else: target.unlink(missing_ok=True)
                    if existed: os.replace(previous,target)
                raise
            finally: service_control('start')
    return {'installationId':config['installationId'],'releaseId':config['releaseId'],'phase':'restored','files':len(metadata['files'])}

def main():
    parser=argparse.ArgumentParser(); parser.add_argument('--config',default=str(bootstrap.BASE/'config.json')); parser.add_argument('--input',required=True); args=parser.parse_args()
    try:
        c=bootstrap.validate(json.loads(Path(args.config).read_text()))
        if os.geteuid()!=0: raise ValueError()
        storage.verify(c); result=restore_backup(c,args.input); storage.verify(c); print(json.dumps(result)); return 0
    except Exception: print(json.dumps({'phase':'restore-failed','reason':'backup identity, integrity, or stopped-state restore failed'})); return 1

if __name__=='__main__': raise SystemExit(main())
