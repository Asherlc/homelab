import importlib.util
from pathlib import Path
import subprocess
from unittest.mock import patch
import unittest

class DiagnosticTests(unittest.TestCase):
    def test_failed_command_keeps_safe_api_evidence_and_redacts_secret(self):
        spec=importlib.util.spec_from_file_location('integration',Path(__file__).parent/'integration.py'); module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        failed=subprocess.CompletedProcess(['docker'],1,stdout='',stderr='HTTP sonarr /api/v3/config/host status400 secret-fixture-token')
        with patch.object(module.subprocess,'run',return_value=failed),patch.object(module,'SECRET_VALUES',['secret-fixture-token']):
            with self.assertRaises(RuntimeError) as cm: module.invoke(['docker'])
        self.assertIn('status400',str(cm.exception)); self.assertIn('/api/v3/config/host',str(cm.exception)); self.assertNotIn('secret-fixture-token',str(cm.exception))
