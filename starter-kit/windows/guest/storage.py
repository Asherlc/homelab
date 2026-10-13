"""Fail closed before Docker can touch media or application state."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import uuid
import kit_secrets

MARKER='.starter-kit-installation.json'
STATE_LABEL='MEDIAKIT_STATE'

def run(args,**kwargs):
    return subprocess.run(args,check=True,capture_output=True,text=True,timeout=120,**kwargs).stdout

def inspect_mount(path):
    raw=json.loads(run(['findmnt','--json','--mountpoint',str(path),'--output','TARGET,SOURCE,FSTYPE,OPTIONS,LABEL,UUID']))
    mounts=raw.get('filesystems',[])
    if len(mounts)!=1: raise ValueError('required storage is not mounted')
    return mounts[0]

def write_probe(directory):
    path=Path(directory)/('.write-probe-'+uuid.uuid4().hex)
    try:
        with path.open('xb') as f: f.write(b'mediakit-storage'); f.flush(); os.fsync(f.fileno())
        if path.read_bytes()!=b'mediakit-storage': raise ValueError('storage readback failed')
    finally:
        path.unlink(missing_ok=True)

def verify(config,data=Path('/data'),state=Path('/var/lib/starter-kit'),inspector=inspect_mount,expected_uuid=None):
    data=Path(data); state=Path(state)
    m=inspector(data); s=inspector(state)
    expected='//'+config['hostIP']+'/'+config['smb']['share']
    for mount,path,kind in [(m,data,'cifs'),(s,state,'ext4')]:
        if mount.get('target')!=str(path) or mount.get('fstype')!=kind or 'rw' not in mount.get('options','').split(','):
            raise ValueError('required writable storage mount is invalid')
    if m.get('source')!=expected or s.get('label')!=STATE_LABEL: raise ValueError('storage source mismatch')
    if expected_uuid is None and state==Path('/var/lib/starter-kit'):
        record=json.loads(kit_secrets.read_private('/etc/starter-kit/storage.json'))
        if record['installationId']!=config['installationId']: raise ValueError('appstate identity mismatch')
        expected_uuid=record['values']['uuid']
    if expected_uuid is not None and s.get('uuid')!=expected_uuid: raise ValueError('appstate UUID mismatch')
    marker=json.loads((data/MARKER).read_text())
    if marker!={'schemaVersion':1,'installationId':config['installationId']}: raise ValueError('media ownership marker mismatch')
    state_marker=state/MARKER
    if state_marker.exists() and json.loads(state_marker.read_text())!=marker: raise ValueError('appstate identity mismatch')
    if not state_marker.exists() and any(p.name!='lost+found' for p in state.iterdir()): raise ValueError('unowned populated appstate disk')
    write_probe(data); write_probe(state)
    return True

def select_empty_state_disk(disks):
    disks=[d for d in disks if d.get('type')=='disk' and not d.get('rm',False)]
    if len(disks)!=2: raise ValueError('exactly two dedicated appliance disks required')
    def mounted(d): return any(d.get('mountpoints') or []) or any(mounted(c) for c in d.get('children',[]))
    candidates=[d for d in disks if not mounted(d)]
    if len(candidates)!=1: raise ValueError('dedicated appstate disk is ambiguous')
    disk=candidates[0]
    if disk.get('fstype') or disk.get('pttype') or disk.get('children') or int(disk.get('size',0))!=32*1024**3:
        raise ValueError('appstate disk must be empty installer-created 32 GiB disk')
    name=disk['name']
    if '/' in name or not name.startswith(('sd','vd','nvme')): raise ValueError('unsafe disk identity')
    return '/dev/'+name

def initialize_state():
    disk=Path('/dev/disk/by-label/'+STATE_LABEL)
    if not disk.exists():
        tree=json.loads(run(['lsblk','--json','--bytes','--output','NAME,TYPE,SIZE,RM,MOUNTPOINTS,FSTYPE,PTTYPE']))['blockdevices']
        target=select_empty_state_disk(tree)
        # wipefs only inspects; any signature, including a partial filesystem, blocks formatting.
        signatures=json.loads(run(['wipefs','--json',target])).get('signatures',[])
        if signatures: raise ValueError('appstate disk contains signatures; refusing format')
        run(['mkfs.ext4','-L',STATE_LABEL,target])
    run(['udevadm','settle'])
    actual=run(['blkid','-s','TYPE','-o','value',str(disk)]).strip()
    if actual!='ext4': raise ValueError('appstate label must identify ext4')
    return run(['blkid','-s','UUID','-o','value',str(disk)]).strip()

def probe_hardlinks(runner=run,app='sonarr'):
    # Probe within the exact Arr container's mount namespace and application UID.
    suffix=uuid.uuid4().hex
    source='/data/downloads/.hardlink-'+suffix
    target='/data/media/'+('tv' if app=='sonarr' else 'movies')+'/.hardlink-'+suffix
    script='set -eu; trap \'rm -f "$1" "$2"\' EXIT; printf first > "$1"; ln "$1" "$2"; printf second > "$1"; test "$(cat "$2")" = second; test "$(stat -c %i "$1")" = "$(stat -c %i "$2")"'
    try:
        runner(['docker','compose','-p','starter-kit','-f','/etc/starter-kit/compose.json','exec','-T','--user','1000:1000',app,'sh','-c',script,'probe',source,target])
        return True
    except (subprocess.SubprocessError,OSError): return False

def recover(config,runner=run,verifier=verify):
    try:
        runner(['systemctl','reset-failed','data.mount','var-lib-starter\\x2dkit.mount','docker.service','docker.socket'])
        runner(['systemctl','start','data.mount','var-lib-starter\\x2dkit.mount'])
        verifier(config)
        runner(['systemctl','start','docker.service','starter-kit-apps.service'])
    except Exception:
        try: runner(['systemctl','stop','docker.socket','docker.service'])
        except Exception: pass
        raise

def main():
    parser=argparse.ArgumentParser(); parser.add_argument('action',choices=['verify','probe-hardlinks','retry']); parser.add_argument('--config',default='/etc/starter-kit/config.json')
    args=parser.parse_args()
    try:
        config=json.loads(Path(args.config).read_text())
        if args.action=='retry': recover(config); return 0
        verify(config)
        if args.action=='probe-hardlinks': print(json.dumps({'hardlinks':probe_hardlinks()}))
        return 0
    except Exception:
        if args.action=='retry':
            try: run(['systemctl','stop','docker.socket','docker.service'])
            except Exception: pass
        print(json.dumps({'healthy':False,'reason':'storage unavailable or ownership verification failed'})); return 1

if __name__=='__main__': raise SystemExit(main())
