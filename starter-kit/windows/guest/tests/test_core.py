import copy
import importlib.util
import json
import os
from pathlib import Path
import sys
import subprocess
import tempfile
import unittest

GUEST = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(GUEST))
CONTRACT = json.loads((GUEST/'tests/fixtures/bootstrap.json').read_text())

class CoreTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
    def tearDown(self):
        self.tmp.cleanup()
    def test_strict_config_before_mutation(self):
        import bootstrap
        bootstrap.validate(CONTRACT)
        for field, value in [('hostIP',CONTRACT['guestIP']),('prefixLength',True),('timezone','../UTC'),('downloader','both'),('extra',1)]:
            c=copy.deepcopy(CONTRACT); c[field]=value
            with self.assertRaises(ValueError): bootstrap.validate(c)
        for host,guest in [('127.0.0.1','127.0.0.2'),('0.0.0.1','0.0.0.2'),('169.254.0.1','169.254.0.2')]:
            c=copy.deepcopy(CONTRACT); c.update(hostIP=host,guestIP=guest)
            with self.assertRaises(ValueError): bootstrap.validate(c)
        for part, key, value in [('network','internalMac','xxxx'),('smb','credentialsRef','/tmp/pass'),('smb','share','bad/name')]:
            c=copy.deepcopy(CONTRACT); c[part][key]=value
            with self.assertRaises(ValueError): bootstrap.validate(c)
    def test_secret_create_once_stable_private_identity(self):
        import kit_secrets
        p=self.root/'secret.json'
        a=kit_secrets.create_once(p,CONTRACT['installationId'],{'key':'first'})
        b=kit_secrets.create_once(p,CONTRACT['installationId'],{'key':'second'})
        self.assertEqual(a,b); self.assertEqual(p.stat().st_mode & 0o777,0o600)
        with self.assertRaises(ValueError): kit_secrets.create_once(p,'other',{})
        p.chmod(0o644)
        with self.assertRaises(ValueError): kit_secrets.read_private(p)
    def test_credentials_reject_symlink_and_public_file(self):
        import kit_secrets
        p=self.root/'credentials'; p.write_text('username=u\npassword=p\ndomain=d\n'); p.chmod(0o600)
        self.assertEqual(kit_secrets.read_credentials(p)['username'],'u')
        link=self.root/'link'; link.symlink_to(p)
        with self.assertRaises(ValueError): kit_secrets.read_credentials(link)
        p.chmod(0o644)
        with self.assertRaises(ValueError): kit_secrets.read_credentials(p)
    def test_mount_source_marker_and_real_write_probe(self):
        import storage
        data=self.root/'data'; data.mkdir(); state=self.root/'state'; state.mkdir()
        (data/storage.MARKER).write_text(json.dumps({'schemaVersion':1,'installationId':CONTRACT['installationId']}))
        good={'target':str(data),'fstype':'cifs','source':'//172.29.240.1/MediaKit-05dd38dd','options':'rw'}
        sm={'target':str(state),'fstype':'ext4','source':'/dev/sdb','options':'rw','label':'MEDIAKIT_STATE'}
        self.assertTrue(storage.verify(CONTRACT,data,state,lambda p:good if p==data else sm))
        for attr,value in [('source','//wrong/share'),('fstype','ext4'),('options','ro')]:
            bad=dict(good); bad[attr]=value
            with self.assertRaises(ValueError): storage.verify(CONTRACT,data,state,lambda p:bad if p==data else sm)
        (data/storage.MARKER).write_text('{}')
        with self.assertRaises(ValueError): storage.verify(CONTRACT,data,state,lambda p:good if p==data else sm)
        self.assertEqual(list(data.glob('.write-probe-*')),[])
    def test_state_uuid_and_unowned_populated_appstate_rejected(self):
        import storage
        data=self.root/'data'; data.mkdir(); state=self.root/'state'; state.mkdir()
        (data/storage.MARKER).write_text(json.dumps({'schemaVersion':1,'installationId':CONTRACT['installationId']}))
        good={'target':str(data),'fstype':'cifs','source':'//172.29.240.1/MediaKit-05dd38dd','options':'rw'}
        sm={'target':str(state),'fstype':'ext4','source':'/dev/sdb','options':'rw','label':'MEDIAKIT_STATE','uuid':'wrong'}
        with self.assertRaises(ValueError): storage.verify(CONTRACT,data,state,lambda p:good if p==data else sm,expected_uuid='right')
        (state/'unowned-db').write_text('foreign')
        with self.assertRaises(ValueError): storage.verify(CONTRACT,data,state,lambda p:good if p==data else sm)
    def test_disk_format_only_explicit_empty_second_disk(self):
        import storage
        disks=[{'name':'sda','type':'disk','size':34359738368,'mountpoints':[None],'children':[{'mountpoints':['/']}]},{'name':'sdb','type':'disk','size':34359738368,'mountpoints':[None],'fstype':None,'pttype':None,'children':[]}]
        self.assertEqual(storage.select_empty_state_disk(disks),'/dev/sdb')
        for key,value in [('fstype','ntfs'),('children',[{}]),('size',100),('pttype','gpt')]:
            bad=copy.deepcopy(disks); bad[1][key]=value
            with self.assertRaises(ValueError): storage.select_empty_state_disk(bad)
    def test_compose_one_downloader_no_public_bind_before_setup(self):
        import bootstrap
        images={k:'example/'+k+':1@sha256:'+'a'*64 for k in ['sonarr','radarr','prowlarr','seerr','qbittorrent','sabnzbd','configarr']}
        release={'schemaVersion':1,'releaseId':CONTRACT['releaseId'],'images':images,'templateRevisions':{'trash':'b'*40,'recyclarr':'c'*40}}
        for downloader in ['qbittorrent','sabnzbd']:
            c=dict(CONTRACT,downloader=downloader)
            services=bootstrap.compose(c,release,'127.0.0.1')['services']
            self.assertIn(downloader,services); self.assertNotIn('sabnzbd' if downloader=='qbittorrent' else 'qbittorrent',services)
            for app in ['sonarr','radarr',downloader]: self.assertIn('/data:/data',services[app]['volumes'])
            self.assertTrue(services['sonarr']['ports'][0].startswith('127.0.0.1:'))
        release['images']['sonarr']='latest'
        with self.assertRaises(ValueError): bootstrap.compose(CONTRACT,release,'127.0.0.1')
    def test_network_retires_cloud_seed_after_validated_replacement(self):
        import bootstrap
        directory=self.root/'netplan'; directory.mkdir()
        seed=directory/'50-cloud-init.yaml'; seed.write_text('network: {version: 2}')
        unrelated=directory/'20-unrelated.yaml'; unrelated.write_text('preserve me')
        calls=[]
        def generate(args):
            self.assertFalse(seed.exists())
            current=json.loads((directory/'90-starter-kit.yaml').read_text())
            interfaces=current['network']['ethernets']
            self.assertEqual(set(interfaces),{'kit-private','kit-lan'})
            self.assertEqual(interfaces['kit-lan']['set-name'],'kit-lan')
            self.assertEqual(interfaces['kit-private']['addresses'],[CONTRACT['guestIP']+'/'+str(CONTRACT['prefixLength'])])
            calls.append(args)
        bootstrap.install_network(CONTRACT,'kit-private','kit-lan',directory,generate)
        self.assertEqual(calls,[['netplan','generate']]); self.assertFalse(seed.exists())
        self.assertEqual(unrelated.read_text(),'preserve me')
        self.assertEqual((directory/'90-starter-kit.yaml').stat().st_mode & 0o777,0o600)
    def test_invalid_network_replacement_restores_previous_files(self):
        import bootstrap
        directory=self.root/'netplan'; directory.mkdir()
        seed=directory/'50-cloud-init.yaml'; seed.write_text('seed network'); seed.chmod(0o600)
        owned=directory/'90-starter-kit.yaml'; owned.write_text('previous network'); owned.chmod(0o600)
        def invalid(args): raise ValueError('netplan generation rejected replacement')
        with self.assertRaises(ValueError): bootstrap.install_network(CONTRACT,'kit-private','kit-lan',directory,invalid)
        self.assertEqual(seed.read_text(),'seed network'); self.assertEqual(owned.read_text(),'previous network')
    def test_retry_mounts_then_verify_then_starts_and_stops_on_failure(self):
        import storage
        events=[]
        storage.recover(CONTRACT,lambda args:events.append(args),lambda c:events.append(['verify']))
        verify_index=events.index(['verify'])
        self.assertTrue(any('data.mount' in e and 'start' in e for e in events[:verify_index]))
        self.assertTrue(any('docker.service' in e and 'start' in e for e in events[verify_index+1:]))
        events=[]
        def fail(c): raise ValueError('wrong mount')
        with self.assertRaises(ValueError): storage.recover(CONTRACT,lambda args:events.append(args),fail)
        self.assertTrue(any('stop' in e and 'docker.service' in e for e in events))
    def test_fresh_seerr_initializes_own_settings_and_existing_settings_preserved(self):
        import bootstrap
        from unittest.mock import patch
        secret={app:{'username':'user','password':'unique','apiKey':'unique-'+app} for app in bootstrap.PORTS}
        with patch.object(os,'chown',lambda *a:None): bootstrap.write_initial_configs(CONTRACT,secret,self.root)
        p=self.root/'seerr/settings.json'; self.assertFalse(p.exists())
        p.write_text('{"existing":true}')
        with patch.object(os,'chown',lambda *a:None): bootstrap.write_initial_configs(CONTRACT,secret,self.root)
        self.assertEqual(json.loads(p.read_text()),{'existing':True})
    def test_native_seerr_key_is_adopted_once_and_changed_key_rejected(self):
        import bootstrap,kit_secrets
        state=self.root/'state'; settings=state/'seerr/settings.json'; settings.parent.mkdir(mode=0o700,parents=True)
        settings.write_text(json.dumps({'main':{'apiKey':'native-unique-application-key','mediaServerType':4},'public':{'initialized':False}})); settings.chmod(0o644)
        path=self.root/'app-secrets.json'; secrets={'seerr':{'apiKey':'unused-initial-placeholder','username':'user','password':'private'}}
        kit_secrets.create_once(path,CONTRACT['installationId'],secrets)
        adopted=bootstrap.adopt_seerr_credentials(CONTRACT,secrets,state,path,attempts=1)
        self.assertEqual(adopted['seerr']['apiKey'],'native-unique-application-key')
        self.assertEqual(json.loads(kit_secrets.read_private(path))['values'],adopted)
        self.assertEqual(bootstrap.adopt_seerr_credentials(CONTRACT,adopted,state,path,attempts=1),adopted)
        settings.write_text(json.dumps({'main':{'apiKey':'different-application-key'}}))
        with self.assertRaises(ValueError): bootstrap.adopt_seerr_credentials(CONTRACT,adopted,state,path,attempts=1)
    def test_cleanup_seed_preserves_cloud_identity_and_ssh(self):
        import bootstrap
        cloud=self.root/'cloud'; instance=cloud/'instances/iid-once'; instance.mkdir(parents=True)
        for name in ['user-data.txt','user-data.txt.i','vendor-data.txt','obj.pkl','cloud-config.txt','meta-data.json','boot-finished']: (instance/name).write_text('fixture')
        (cloud/'instance').symlink_to(instance)
        seed=cloud/'seed/nocloud'; seed.mkdir(parents=True); (seed/'user-data').write_text('secret'); (seed/'meta-data').write_text('identity')
        bootstrap.cleanup_seed(cloud,self.root/'cloud-init.disabled')
        self.assertFalse((instance/'user-data.txt').exists()); self.assertFalse((seed/'user-data').exists())
        self.assertTrue((instance/'meta-data.json').exists()); self.assertTrue((instance/'boot-finished').exists()); self.assertTrue((cloud/'instance').is_symlink()); self.assertTrue((seed/'meta-data').exists())
        self.assertFalse((instance/'obj.pkl').exists()); self.assertFalse((instance/'cloud-config.txt').exists()); self.assertTrue((self.root/'cloud-init.disabled').exists())
    def test_status_retains_copy_import_storage_guidance(self):
        import bootstrap, kit_secrets, api_setup
        from unittest.mock import patch
        kit_secrets.create_once(self.root/'app-secrets.json',CONTRACT['installationId'],{})
        (self.root/'setup-state.json').write_text(json.dumps({'installationId':CONTRACT['installationId'],'storageGuidance':['Copy imports use extra disk space while seeding']}))
        with patch.object(bootstrap,'BASE',self.root),patch.object(bootstrap.storage,'verify',lambda c:True),patch.object(api_setup,'verify_apps',lambda c,t:{'checks':{'connections':True},'pendingSteps':[]}),patch.object(bootstrap,'interface_name',side_effect=ValueError()):
            status=bootstrap.status(CONTRACT)
        self.assertEqual(status['storageGuidance'],['Copy imports use extra disk space while seeding'])
    def test_running_apps_do_not_mark_incomplete_apply_successful(self):
        import bootstrap,kit_secrets,api_setup
        from unittest.mock import patch
        kit_secrets.create_once(self.root/'app-secrets.json',CONTRACT['installationId'],{})
        with patch.object(bootstrap,'BASE',self.root),patch.object(bootstrap.storage,'verify',lambda c:True),patch.object(api_setup,'verify_apps',lambda c,t:{'checks':{'connections':True},'pendingSteps':[]}),patch.object(bootstrap,'interface_name',side_effect=ValueError()):
            self.assertEqual(bootstrap.status(CONTRACT)['phase'],'blocked')
    def test_apply_lock_serializes_processes_times_out_and_releases(self):
        import bootstrap
        lock=self.root/'apply.lock'; bootstrap.exclusive_apply_lock
        script='import sys; sys.path.insert(0,sys.argv[1]); import bootstrap;\nwith bootstrap.exclusive_apply_lock(sys.argv[2],1):\n print("locked",flush=True); input()\n'
        child=subprocess.Popen([sys.executable,'-c',script,str(GUEST),str(lock)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        try:
            self.assertEqual(child.stdout.readline().strip(),'locked')
            with self.assertRaisesRegex(ValueError,'already running'):
                with bootstrap.exclusive_apply_lock(lock,0.05): self.fail('overlapping apply entered')
            child.communicate('\n',timeout=5); self.assertEqual(child.returncode,0)
            with self.assertRaises(RuntimeError):
                with bootstrap.exclusive_apply_lock(lock,1): raise RuntimeError('interrupted apply')
            with bootstrap.exclusive_apply_lock(lock,1): self.assertEqual(lock.stat().st_mode & 0o777,0o600)
        finally:
            if child.poll() is None: child.kill(); child.communicate()

if __name__=='__main__': unittest.main()
