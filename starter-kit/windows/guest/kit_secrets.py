"""Private, create-once installation credentials. Never print returned values."""
import json
import os
from pathlib import Path
import stat
import tempfile
import base64

def read_private(path):
    fd=os.open(path,os.O_RDONLY | getattr(os,'O_NOFOLLOW',0))
    try:
        st=os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_mode & 0o077 or st.st_uid != os.geteuid():
            raise ValueError('credential file must be private and owned by the provisioning user')
        with os.fdopen(fd,'r',encoding='utf-8') as f:
            fd=None
            return f.read()
    except OSError:
        raise ValueError('credential file cannot be read safely') from None
    finally:
        if fd is not None: os.close(fd)

def atomic_write(path,value,mode=0o600):
    path=Path(path); path.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
    fd,name=tempfile.mkstemp(prefix='.new-',dir=path.parent)
    try:
        os.fchmod(fd,mode)
        with os.fdopen(fd,'w',encoding='utf-8') as f:
            f.write(value); f.flush(); os.fsync(f.fileno())
        os.replace(name,path)
    finally:
        if os.path.exists(name): os.unlink(name)

def create_once(path,installation_id,value):
    path=Path(path)
    if path.exists() or path.is_symlink():
        old=json.loads(read_private(path))
        if old.get('installationId') != installation_id: raise ValueError('credential identity mismatch')
        return old['values']
    path.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
    payload=json.dumps({'installationId':installation_id,'values':value},sort_keys=True)
    fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
    with os.fdopen(fd,'w') as f: f.write(payload); f.flush(); os.fsync(f.fileno())
    return value

def token(): return base64.urlsafe_b64encode(os.urandom(32)).decode().rstrip('=')

def read_credentials(path):
    try:
        raw=read_private(path)
        result=dict(line.split('=',1) for line in raw.splitlines() if line)
        if set(result) != {'username','password','domain'} or not all(result.values()): raise ValueError()
        if any('\x00' in v or '\r' in v for v in result.values()): raise ValueError()
        return result
    except (OSError,ValueError): raise ValueError('invalid protected SMB credentials') from None
