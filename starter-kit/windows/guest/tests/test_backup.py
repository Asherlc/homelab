import io
import json
import os
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from test_core import CONTRACT

class BackupTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(); self.root=Path(self.tmp.name)
        self.state=self.root/'state'; self.etc=self.root/'etc'; self.state.mkdir(); self.etc.mkdir()
        (self.state/'sonarr').mkdir(); (self.state/'sonarr/database.db').write_bytes(b'original-db')
        (self.state/'sonarr/database.db').chmod(0o664)
        (self.state/'docker').mkdir(); (self.state/'docker/not-backed-up').write_text('cache')
        (self.etc/'app-secrets.json').write_text('original-secret'); (self.etc/'app-secrets.json').chmod(0o600)
        self.events=[]
        self.archive=self.root/'backup.tar'
    def tearDown(self): self.tmp.cleanup()
    def test_real_backup_mutate_restore_identity_checksums_and_restart(self):
        import backup, restore
        backup.create_backup(CONTRACT,self.archive,self.state,self.etc,lambda action:self.events.append(action))
        self.assertEqual(self.events,['stop','start']); self.assertEqual(self.archive.stat().st_mode & 0o777,0o600)
        with tarfile.open(self.archive) as f: self.assertFalse(any('docker/' in m.name for m in f.getmembers()))
        (self.state/'sonarr/database.db').write_bytes(b'changed'); (self.etc/'app-secrets.json').write_text('changed')
        restore.restore_backup(CONTRACT,self.archive,self.state,self.etc,lambda action:self.events.append(action))
        self.assertEqual((self.state/'sonarr/database.db').read_bytes(),b'original-db')
        self.assertEqual((self.etc/'app-secrets.json').read_text(),'original-secret'); self.assertEqual(self.events,['stop','start','stop','start'])
    def test_mismatched_identity_release_or_corruption_no_stop(self):
        import backup,restore
        backup.create_backup(CONTRACT,self.archive,self.state,self.etc,lambda action:None)
        for key in ['installationId','releaseId']:
            wrong=dict(CONTRACT); wrong[key]='other'
            with self.assertRaises(ValueError): restore.restore_backup(wrong,self.archive,self.state,self.etc,lambda action:self.events.append(action))
        self.assertEqual(self.events,[])
        damaged=self.root/'corrupt.tar'
        with tarfile.open(self.archive) as src,tarfile.open(damaged,'w') as dest:
            for member in src.getmembers():
                raw=src.extractfile(member).read()
                if member.name=='state/sonarr/database.db': raw=b'corrupt-db'
                member.size=len(raw); dest.addfile(member,io.BytesIO(raw))
        with self.assertRaises(ValueError): restore.restore_backup(CONTRACT,damaged,self.state,self.etc,lambda action:self.events.append(action))
        self.assertEqual(self.events,[])
    def test_reject_traversal_symlink_duplicate_and_unlisted_before_stop(self):
        import restore
        for name,kind in [('../escape',tarfile.REGTYPE),('/absolute',tarfile.REGTYPE),('state/link',tarfile.SYMTYPE),('unlisted',tarfile.REGTYPE)]:
            with tarfile.open(self.archive,'w') as f:
                member=tarfile.TarInfo(name); member.type=kind; member.size=0; member.linkname='/etc/passwd'; f.addfile(member,io.BytesIO())
            with self.assertRaises(ValueError): restore.restore_backup(CONTRACT,self.archive,self.state,self.etc,lambda action:self.events.append(action))
        self.assertEqual(self.events,[])
    def test_backup_failure_always_restarts_no_partial_archive(self):
        import backup
        (self.state/'sonarr/unsafe').symlink_to('/etc/passwd')
        with self.assertRaises(ValueError): backup.create_backup(CONTRACT,self.archive,self.state,self.etc,lambda action:self.events.append(action))
        self.assertEqual(self.events,['stop','start']); self.assertFalse(self.archive.exists())
    def test_partial_stop_failure_still_restarts_backup_and_restore(self):
        import backup,restore
        def broken_stop(action):
            self.events.append(action)
            if action=='stop': raise RuntimeError('some containers stopped before timeout')
        with self.assertRaises(RuntimeError): backup.create_backup(CONTRACT,self.archive,self.state,self.etc,broken_stop)
        self.assertEqual(self.events,['stop','start']); self.assertFalse(self.archive.exists())
        backup.create_backup(CONTRACT,self.archive,self.state,self.etc,lambda action:None)
        self.events=[]
        with self.assertRaises(RuntimeError): restore.restore_backup(CONTRACT,self.archive,self.state,self.etc,broken_stop)
        self.assertEqual(self.events,['stop','start'])
    def test_restart_reconciles_restored_pinned_image_definitions(self):
        import backup
        from unittest.mock import patch
        commands=[]
        with patch.object(backup.bootstrap,'docker',lambda *args:commands.append(args)): backup.control('start')
        self.assertEqual(commands,[('up','-d')])

if __name__=='__main__': unittest.main()
