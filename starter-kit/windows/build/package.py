#!/usr/bin/env python3
"""Build and verify the Windows kit's explicit, deterministic ZIP allowlist."""

import argparse
import hashlib
import json
import re
import shutil
import stat
import sys
import zipfile
from pathlib import Path, PurePosixPath
from urllib.parse import urlsplit

ARTIFACTS = {"plex": "PlexMediaServer.exe", "wrapper": "PmsServiceInstaller.msi", "appliance": "media-kit.vhdx"}
PRIVATE_SUFFIXES = {".db", ".sqlite", ".sqlite3", ".log", ".pem", ".key", ".pfx", ".env"}
IMAGE_NAMES = {"sonarr", "radarr", "prowlarr", "seerr", "qbittorrent", "sabnzbd", "configarr"}
REQUIRED_NOTICES = {"vendor/pmsservice/NOTICES.md", *(
    "vendor/pmsservice/licenses/" + name for name in (
        "LICENSE.md", "msiext-license.txt", "Newtonsoft.Json-license.txt",
        "mahapps-license.txt", "ookiidialogs-license.txt", "FontAwesome-WPF.txt"
    )
)}


def digest_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def safe_name(name):
    if not isinstance(name, str) or not name or "\\" in name or ":" in name:
        raise ValueError("unsafe package path")
    parts = PurePosixPath(name).parts
    if name.startswith("/") or any(p in {".", ".."} for p in parts) or any(ord(c) < 32 or c in '<>"|?*' for c in name):
        raise ValueError("unsafe package path")
    if str(PurePosixPath(name)) != name or any(p.startswith(".") for p in parts):
        raise ValueError("unsafe package path")
    for part in parts:
        device = part.split(".", 1)[0].upper()
        if part.endswith((".", " ")) or device in {"CON", "PRN", "AUX", "NUL"} or re.fullmatch(r"(?:COM|LPT)[1-9¹²³]", device):
            raise ValueError("unsafe Windows package path")
    if any(PurePosixPath(p).suffix.lower() in PRIVATE_SUFFIXES for p in parts):
        raise ValueError("private file is not a release asset")
    return name


def validate_manifest(manifest):
    if not isinstance(manifest, dict) or type(manifest.get("schemaVersion")) is not int or manifest["schemaVersion"] != 1 or not isinstance(manifest.get("releaseId"), str) or not manifest["releaseId"].strip():
        raise ValueError("unsupported release manifest")
    if type(manifest.get("minimumWindowsBuild")) is not int or manifest["minimumWindowsBuild"] < 22631:
        raise ValueError("unsupported minimum Windows build")
    files = manifest.get("files")
    if not isinstance(files, list) or "Install.cmd" not in files or "Install.ps1" not in files:
        raise ValueError("missing installer allowlist")
    names = [safe_name(n) for n in files]
    if len({n.casefold() for n in names}) != len(names):
        raise ValueError("Windows filename collision")
    if any(n.casefold() in {x.casefold() for x in {"release.json", "SHA256SUMS", *ARTIFACTS.values()}} for n in names):
        raise ValueError("reserved package filename")
    if not REQUIRED_NOTICES.issubset(names):
        raise ValueError("required third-party notices are missing from the allowlist")
    artifacts = manifest.get("artifacts")
    if not isinstance(artifacts, dict) or set(artifacts) != set(ARTIFACTS):
        raise ValueError("incomplete release artifacts")
    for kind, filename in ARTIFACTS.items():
        artifact = artifacts[kind]
        if not isinstance(artifact, dict) or artifact.get("filename") != filename or not isinstance(artifact.get("sha256"), str) or not re.fullmatch(r"[0-9a-f]{64}", artifact["sha256"]):
            raise ValueError(f"incomplete {kind} artifact checksum")
        if artifact.get("architecture") != ("x86" if kind == "wrapper" else "amd64"):
            raise ValueError(f"unsupported {kind} artifact architecture")
        if artifact.get("url") and (not isinstance(artifact["url"], str) or not artifact["url"].startswith("https://")):
            raise ValueError("artifact URL must use HTTPS")
    plex = artifacts["plex"]
    if plex.get("publisher") != "Plex, Inc.":
        raise ValueError("expected native Plex publisher is required")
    url = urlsplit(plex.get("url", ""))
    if url.scheme != "https" or url.hostname != "downloads.plex.tv" or url.username or url.password or url.port not in {None, 443} or not url.path.lower().endswith(".exe"):
        raise ValueError("native Plex must use an official HTTPS installer URL")
    images = manifest.get("images")
    if not isinstance(images, dict) or set(images) != IMAGE_NAMES:
        raise ValueError("incomplete pinned images")
    if any(not isinstance(value, str) or not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9./:_-]*@sha256:[0-9a-f]{64}", value) for value in images.values()):
        raise ValueError("every container image must be pinned by digest")
    revisions = manifest.get("templateRevisions")
    if not isinstance(revisions, dict) or set(revisions) != {"trash", "recyclarr"} or any(not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{40}", value) for value in revisions.values()):
        raise ValueError("complete template commit revisions are required")
    return manifest


def source_file(root, name):
    path = root / safe_name(name)
    cursor = path
    while cursor != root:
        if cursor.is_symlink():
            raise ValueError(f"symlink is not an allowed source: {name}")
        cursor = cursor.parent
    if not path.is_file():
        raise ValueError(f"missing source: {name}")
    return path


def build_package(root, assets, output, include_appliance=False):
    root, assets, output = Path(root).resolve(), Path(assets).resolve(), Path(output)
    manifest = validate_manifest(json.loads((root / "release.json").read_text()))
    entries = {name: source_file(root, name) for name in manifest["files"]}
    for kind, filename in ARTIFACTS.items():
        if kind == "appliance" and not include_appliance:
            continue
        path = assets / filename
        if not path.is_file() or path.is_symlink():
            raise ValueError(f"missing artifact: {filename}")
        if digest_file(path) != manifest["artifacts"][kind]["sha256"]:
            raise ValueError(f"artifact checksum mismatch: {filename}")
        entries[filename] = path
    release_bytes = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode()
    checksums = {name: digest_file(path) for name, path in entries.items()}
    checksums["release.json"] = hashlib.sha256(release_bytes).hexdigest()
    sums = "".join(f"{checksums[name]}  {name}\n" for name in sorted(checksums)).encode()
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix(output.suffix + ".partial")
    try:
        with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6, allowZip64=True) as archive:
            for name in sorted({*entries, "release.json", "SHA256SUMS"}):
                info = zipfile.ZipInfo(name, (1980, 1, 1, 0, 0, 0))
                info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = 0o100644 << 16
                with archive.open(info, "w", force_zip64=True) as dest:
                    if name == "release.json":
                        dest.write(release_bytes)
                    elif name == "SHA256SUMS":
                        dest.write(sums)
                    else:
                        with entries[name].open("rb") as source:
                            shutil.copyfileobj(source, dest, 1024 * 1024)
        verify_archive(temporary)
        temporary.replace(output)
    finally:
        temporary.unlink(missing_ok=True)
    return output


def verify_archive(path):
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        if len({n.casefold() for n in names}) != len(names):
            raise ValueError("duplicate or colliding archive names")
        for info in archive.infolist():
            safe_name(info.filename)
            mode = stat.S_IFMT(info.external_attr >> 16)
            if info.is_dir() or info.external_attr & 16 or mode not in {0, stat.S_IFREG}:
                raise ValueError(f"nonregular archive entry: {info.filename}")
        if "release.json" not in names or "SHA256SUMS" not in names:
            raise ValueError("missing archive manifest")
        manifest = validate_manifest(json.loads(archive.read("release.json")))
        expected = {*manifest["files"], "release.json", "SHA256SUMS", ARTIFACTS["plex"], ARTIFACTS["wrapper"]}
        if ARTIFACTS["appliance"] in names:
            expected.add(ARTIFACTS["appliance"])
        if set(names) != expected:
            raise ValueError("unexpected or missing archive file")
        sums = {}
        for line in archive.read("SHA256SUMS").decode().splitlines():
            if not re.fullmatch(r"[0-9a-f]{64}  .+", line):
                raise ValueError("invalid checksum index")
            digest, name = line.split("  ", 1)
            if name in sums:
                raise ValueError("duplicate checksum entry")
            sums[safe_name(name)] = digest
        if set(sums) != expected - {"SHA256SUMS"}:
            raise ValueError("checksum index does not cover archive")
        for name, expected_digest in sums.items():
            digest = hashlib.sha256()
            with archive.open(name) as stream:
                for block in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(block)
            if digest.hexdigest() != expected_digest:
                raise ValueError(f"archive checksum mismatch: {name}")
        for kind, filename in ARTIFACTS.items():
            if filename in sums and sums[filename] != manifest["artifacts"][kind]["sha256"]:
                raise ValueError(f"manifest artifact checksum mismatch: {filename}")
        return {"releaseId": manifest["releaseId"], "files": len(names), "applianceIncluded": ARTIFACTS["appliance"] in names}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    build = commands.add_parser("build")
    build.add_argument("--root", type=Path, required=True)
    build.add_argument("--assets", type=Path, required=True)
    build.add_argument("--output", type=Path, required=True)
    build.add_argument("--include-appliance", action="store_true")
    verify = commands.add_parser("verify")
    verify.add_argument("--archive", type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.command == "build":
            result = build_package(args.root, args.assets, args.output, args.include_appliance)
            print(json.dumps({"archive": str(result), "sha256": digest_file(result), **verify_archive(result)}))
        else:
            print(json.dumps(verify_archive(args.archive)))
    except (ValueError, OSError, zipfile.BadZipFile, KeyError) as error:
        print(f"Package verification failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
