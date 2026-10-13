import hashlib
import importlib.util
import json
import copy
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

MODULE = Path(__file__).parents[1] / "build" / "package.py"


class PackageTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.base = Path(self.work.name)
        self.root = self.base / "kit"
        self.assets = self.base / "assets"
        self.root.mkdir()
        self.assets.mkdir()
        spec = importlib.util.spec_from_file_location("kit_package", MODULE)
        self.package = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = self.package
        spec.loader.exec_module(self.package)
        files = {
            "Install.cmd": "@echo off\n",
            "Install.ps1": "Write-Host 'Install'\n",
            "README.md": "Installation instructions.\n",
            "modules/Test.psm1": "function Test-Kit {}\n",
            "guest/bootstrap.py": "print('bootstrap')\n",
            "vendor/pmsservice/NOTICES.md": "Wrapper attribution and upstream source location.\n",
            "vendor/pmsservice/licenses/LICENSE.md": "Upstream MIT notice fixture.\n",
            "vendor/pmsservice/licenses/msiext-license.txt": "Bundled EPL notice fixture.\n",
            "vendor/pmsservice/licenses/Newtonsoft.Json-license.txt": "JSON notice fixture.\n",
            "vendor/pmsservice/licenses/mahapps-license.txt": "UI notice fixture.\n",
            "vendor/pmsservice/licenses/ookiidialogs-license.txt": "Dialog notice fixture.\n",
            "vendor/pmsservice/licenses/FontAwesome-WPF.txt": "Font notice fixture.\n",
        }
        for name, contents in files.items():
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(contents)
        artifacts = {}
        for key, name, data in (
            ("plex", "PlexMediaServer.exe", b"MZnative-installer-fixture"),
            ("wrapper", "PmsServiceInstaller.msi", b"wrapper-fixture"),
            ("appliance", "media-kit.vhdx", b"vhdxfilefixture"),
        ):
            (self.assets / name).write_bytes(data)
            artifacts[key] = {
                "filename": name,
                "sha256": hashlib.sha256(data).hexdigest(),
                "architecture": "amd64",
            }
        artifacts["plex"]["url"] = "https://downloads.plex.tv/fixture.exe"
        artifacts["plex"]["publisher"] = "Plex, Inc."
        artifacts["wrapper"]["architecture"] = "x86"
        self.manifest = {
            "schemaVersion": 1,
            "releaseId": "0.1.0-candidate.1",
            "minimumWindowsBuild": 22631,
            "artifacts": artifacts,
            "images": {name: "fixture/" + name + "@sha256:" + "a" * 64 for name in (
                "sonarr", "radarr", "prowlarr", "seerr", "qbittorrent", "sabnzbd", "configarr"
            )},
            "templateRevisions": {"trash": "b" * 40, "recyclarr": "c" * 40},
            "files": list(files),
        }
        self.save_manifest()

    def save_manifest(self):
        (self.root / "release.json").write_text(json.dumps(self.manifest))

    def build(self, include_appliance=False):
        output = self.base / "kit.zip"
        self.package.build_package(self.root, self.assets, output, include_appliance)
        return output

    def test_bundle_contains_only_allowlisted_source_and_verified_assets(self):
        (self.root / ".env").write_text("PRIVATE_TOKEN=fixture-private-value")
        archive = self.build(include_appliance=True)
        with zipfile.ZipFile(archive) as zf:
            self.assertEqual(set(zf.namelist()), {
                "Install.cmd", "Install.ps1", "README.md", "modules/Test.psm1",
                "guest/bootstrap.py", "release.json", "SHA256SUMS",
                "PlexMediaServer.exe", "PmsServiceInstaller.msi", "media-kit.vhdx",
                "vendor/pmsservice/NOTICES.md", "vendor/pmsservice/licenses/LICENSE.md",
                "vendor/pmsservice/licenses/msiext-license.txt", "vendor/pmsservice/licenses/Newtonsoft.Json-license.txt",
                "vendor/pmsservice/licenses/mahapps-license.txt", "vendor/pmsservice/licenses/ookiidialogs-license.txt",
                "vendor/pmsservice/licenses/FontAwesome-WPF.txt",
            })
            self.assertNotIn(b"fixture-private-value", b"".join(zf.read(n) for n in zf.namelist()))
        result = self.package.verify_archive(archive)
        self.assertEqual(result["releaseId"], "0.1.0-candidate.1")
        self.assertTrue(result["applianceIncluded"])

    def test_companion_image_can_be_separate_but_native_installers_are_bundled(self):
        archive = self.build()
        with zipfile.ZipFile(archive) as zf:
            self.assertNotIn("media-kit.vhdx", zf.namelist())
            self.assertIn("PmsServiceInstaller.msi", zf.namelist())
        self.assertFalse(self.package.verify_archive(archive)["applianceIncluded"])

    def test_build_rejects_corrupt_or_missing_native_installer(self):
        (self.assets / "PlexMediaServer.exe").write_bytes(b"altered")
        with self.assertRaisesRegex(ValueError, "checksum"):
            self.build()
        (self.assets / "PlexMediaServer.exe").unlink()
        with self.assertRaisesRegex(ValueError, "missing"):
            self.build()

    def test_build_rejects_private_files_and_windows_path_escape_in_allowlist(self):
        baseline = list(self.manifest["files"])
        for name in ("../secret.txt", "/etc/passwd", "C:/secret", "data:private", ".env", "state/keys.pem"):
            self.manifest["files"] = baseline + [name]
            self.save_manifest()
            with self.assertRaisesRegex(ValueError, "unsafe|private", msg=name):
                self.build()

    def test_real_windows_alias_and_device_sources_cannot_enter_a_verified_bundle(self):
        baseline = list(self.manifest["files"])
        for name in ("Install.ps1.", "Install.ps1 ", "credentials.key.", "CON", "folder/AUX.txt", "COM1.txt", "COM¹.txt", "name?.txt", "name<bad>.txt", "control\x01.txt"):
            with self.subTest(name=name):
                path = self.root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("private or conflicting source")
                self.manifest["files"] = baseline + [name]
                self.save_manifest()
                with self.assertRaisesRegex(ValueError, "unsafe|Windows"):
                    self.build()

    def test_archive_verification_rejects_symlink_fifo_and_directory_metadata(self):
        original = self.build()
        for mode, dos in ((0o120777, 0), (0o010600, 0), (0o040755, 0), (0o100644, 16)):
            with self.subTest(mode=oct(mode), dos=dos):
                modified = self.base / "nonregular.zip"
                with zipfile.ZipFile(original) as src, zipfile.ZipFile(modified, "w") as dst:
                    for info in src.infolist():
                        data = src.read(info.filename)
                        if info.filename == "Install.ps1":
                            info.create_system = 3
                            info.external_attr = (mode << 16) | dos
                        dst.writestr(info, data)
                with self.assertRaisesRegex(ValueError, "nonregular|symlink"):
                    self.package.verify_archive(modified)

    def test_unbuilt_hash_produces_an_actionable_cli_failure_without_an_archive(self):
        self.manifest["artifacts"]["wrapper"]["sha256"] = None
        self.save_manifest()
        output = self.base / "must-not-exist.zip"
        result = subprocess.run([sys.executable, str(MODULE), "build", "--root", str(self.root), "--assets", str(self.assets), "--output", str(output)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("incomplete wrapper artifact checksum", result.stderr)
        self.assertNotIn("Traceback", result.stderr)
        self.assertFalse(output.exists())

    def test_complete_contract_and_notices_are_required_before_packaging(self):
        baseline = copy.deepcopy(self.manifest)
        mutations = [
            ("minimum Windows build", lambda m: m.pop("minimumWindowsBuild")),
            ("minimum Windows build", lambda m: m.update(minimumWindowsBuild=22000)),
            ("release", lambda m: m.update(releaseId="")),
            ("architecture", lambda m: m["artifacts"]["wrapper"].update(architecture="arm64")),
            ("publisher", lambda m: m["artifacts"]["plex"].update(publisher="Unexpected Publisher")),
            ("official", lambda m: m["artifacts"]["plex"].update(url="https://downloads.plex.tv.evil.invalid/file.exe")),
            ("official", lambda m: m["artifacts"]["plex"].update(url="https://user:password@downloads.plex.tv/file.exe")),
            ("official", lambda m: m["artifacts"]["plex"].update(url=None)),
            ("images", lambda m: m["images"].pop("sonarr")),
            ("pinned", lambda m: m["images"].update(sonarr="fixture/sonarr:latest")),
            ("template", lambda m: m["templateRevisions"].update(trash="short")),
            ("notices", lambda m: m["files"].remove("vendor/pmsservice/licenses/msiext-license.txt")),
        ]
        for message, mutate in mutations:
            with self.subTest(message=message):
                self.manifest = copy.deepcopy(baseline)
                mutate(self.manifest)
                self.save_manifest()
                with self.assertRaisesRegex(ValueError, message):
                    self.build()

    def test_symlink_cannot_escape_source_root(self):
        (self.root / "README.md").unlink()
        (self.root / "README.md").symlink_to(self.base / "outside")
        (self.base / "outside").write_text("private")
        with self.assertRaisesRegex(ValueError, "symlink"):
            self.build()

    def test_two_builds_have_identical_archive_bytes(self):
        archive = self.build(include_appliance=True)
        before = archive.read_bytes()
        self.build(include_appliance=True)
        self.assertEqual(archive.read_bytes(), before)

    def test_archive_verification_rejects_injected_files(self):
        archive = self.build()
        with zipfile.ZipFile(archive, "a") as zf:
            zf.writestr(".env", "secret")
        with self.assertRaises(ValueError):
            self.package.verify_archive(archive)

    def test_archive_verification_rejects_altered_content(self):
        original = self.build()
        modified = self.base / "modified.zip"
        with zipfile.ZipFile(original) as src, zipfile.ZipFile(modified, "w") as dst:
            for name in src.namelist():
                dst.writestr(name, b"changed" if name == "Install.ps1" else src.read(name))
        with self.assertRaisesRegex(ValueError, "checksum"):
            self.package.verify_archive(modified)

    def test_case_collisions_are_rejected_for_windows_extraction(self):
        self.manifest["files"].append("readme.md")
        (self.root / "readme.md").write_text("collision")
        self.save_manifest()
        with self.assertRaisesRegex(ValueError, "collision"):
            self.build()


if __name__ == "__main__":
    unittest.main()
