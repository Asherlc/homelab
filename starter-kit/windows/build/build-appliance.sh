#!/usr/bin/env bash
set -euo pipefail

build_dir="$(cd "$(dirname "$0")" && pwd)"
kit_dir="$(cd "$build_dir/.." && pwd)"
output_dir=""
manifest_path="$kit_dir/release.json"
accelerator="tcg"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) output_dir="$2"; shift 2 ;;
    --manifest) manifest_path="$2"; shift 2 ;;
    --accelerator) accelerator="$2"; shift 2 ;;
    *) echo "Unknown image build option: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$output_dir" ]] || { echo 'Usage: build-appliance.sh --output DIR [--manifest FILE] [--accelerator kvm|tcg]' >&2; exit 2; }
[[ "$accelerator" == kvm || "$accelerator" == tcg ]] || { echo 'Invalid QEMU accelerator' >&2; exit 2; }
for dependency in packer qemu-img qemu-system-x86_64 ssh-keygen python3 xorriso curl gpg; do
  command -v "$dependency" >/dev/null || { echo "Missing build dependency: $dependency" >&2; exit 1; }
done
[[ -f "$manifest_path" ]] || { echo 'Release input manifest is missing' >&2; exit 1; }
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
manifest_path="$(python3 -c 'import pathlib,sys;print(pathlib.Path(sys.argv[1]).resolve())' "$manifest_path")"
build_temp="$(mktemp -d)"
chmod 0700 "$build_temp"
trap 'rm -rf "$build_temp"' EXIT
ssh-keygen -q -t ed25519 -N '' -f "$build_temp/builder-key"
mkdir "$build_temp/seed"
python3 - "$build_dir" "$build_temp" <<'PY'
from pathlib import Path
import sys
source, scratch = map(Path, sys.argv[1:])
key = (scratch/'builder-key.pub').read_text().strip()
template = (source/'autoinstall/user-data').read_text()
(scratch/'seed/user-data').write_text(template.replace('BUILD_SSH_PUBLIC_KEY', key))
(scratch/'seed/meta-data').write_text((source/'autoinstall/meta-data').read_text())
PY
python3 - "$kit_dir" "$build_temp" "$manifest_path" <<'PY'
from pathlib import Path
import json, shutil, sys
kit, scratch, manifest = map(Path, sys.argv[1:])
for name in json.loads(manifest.read_text())['files']:
 if name.startswith('guest/'):
  destination = scratch / name
  destination.parent.mkdir(parents=True, exist_ok=True)
  shutil.copyfile(kit / name, destination)
PY

# Check the publisher-signed checksum index before Packer downloads the pinned ISO.
curl -fsSL --proto '=https' --tlsv1.2 https://releases.ubuntu.com/24.04/SHA256SUMS -o "$build_temp/SHA256SUMS"
curl -fsSL --proto '=https' --tlsv1.2 https://releases.ubuntu.com/24.04/SHA256SUMS.gpg -o "$build_temp/SHA256SUMS.gpg"
export GNUPGHOME="$build_temp/gpg"
mkdir -m 0700 "$GNUPGHOME"
gpg --batch --keyserver hkps://keyserver.ubuntu.com --recv-keys 843938DF228D22F7B3742BC0D94AA3F0EFE21092
gpg --batch --verify "$build_temp/SHA256SUMS.gpg" "$build_temp/SHA256SUMS"
python3 - "$build_temp/SHA256SUMS" <<'PY'
from pathlib import Path
import sys
expected='97f3d7ffb032c3eb3b23d2c8be9cc76e60c2c1f2c0146ba5ba9fe01cafae0fd8'
lines=Path(sys.argv[1]).read_text().splitlines()
assert any(line.split()[0]==expected and line.split()[-1].lstrip('*')=='ubuntu-24.04.5-live-server-amd64.iso' for line in lines), 'Pinned Ubuntu ISO differs from signed publisher index'
PY

cd "$build_dir"
packer init appliance.pkr.hcl
args=(-var "output_dir=$build_temp/output" -var "seed_dir=$build_temp/seed" -var "private_key=$build_temp/builder-key" -var "guest_dir=$build_temp/guest/" -var "manifest_path=$manifest_path" -var "accelerator=$accelerator")
packer validate "${args[@]}" appliance.pkr.hcl
packer build -on-error=abort "${args[@]}" appliance.pkr.hcl
qemu-img check "$build_temp/output/media-kit.qcow2"
python3 "$build_dir/smoke-appliance.py" --image "$build_temp/output/media-kit.qcow2" --accelerator "$accelerator" --report "$output_dir/appliance-smoke.json"
qemu-img convert -f qcow2 -O vhdx -o subformat=dynamic "$build_temp/output/media-kit.qcow2" "$output_dir/media-kit.vhdx"
qemu-img info --output=json "$output_dir/media-kit.vhdx" > "$output_dir/appliance-image-info.json"
python3 - "$output_dir" <<'PY'
from pathlib import Path
import hashlib,json,sys
root=Path(sys.argv[1]); image=root/'media-kit.vhdx'
info=json.loads((root/'appliance-image-info.json').read_text())
assert info['format']=='vhdx' and info['virtual-size']==32*1024**3
digest=hashlib.sha256()
with image.open('rb') as stream:
 for block in iter(lambda:stream.read(1024*1024),b''): digest.update(block)
(root/'appliance-build.json').write_text(json.dumps({'filename':image.name,'sha256':digest.hexdigest(),'size':image.stat().st_size,'architecture':'amd64','ubuntu':'24.04.5','smoke':json.loads((root/'appliance-smoke.json').read_text()),'windowsBootValidation':'pending'},indent=2)+'\n')
print('Generalized Hyper-V appliance built and checksummed.')
PY
