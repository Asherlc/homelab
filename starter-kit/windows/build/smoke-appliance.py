#!/usr/bin/env python3
"""Boot the generalized disk with fresh firmware and per-instance NoCloud data."""

import argparse
import json
import shutil
import socket
import subprocess
import tempfile
import time
from pathlib import Path


def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)


def smoke(image, accelerator, report):
    with tempfile.TemporaryDirectory(prefix="media-kit-smoke-") as work:
        scratch = Path(work)
        scratch.chmod(0o700)
        run("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(scratch / "client"))
        run("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(scratch / "host"))
        seed = scratch / "seed"
        seed.mkdir(mode=0o700)
        client_key = (scratch / "client.pub").read_text().strip()
        host_key = (scratch / "host.pub").read_text().strip()
        private_key = (scratch / "host").read_text()
        (seed / "user-data").write_text(
            "#cloud-config\nhostname: media-kit-smoke\nmanage_etc_hosts: true\n"
            "users:\n  - name: mediakit-smoke\n    lock_passwd: true\n"
            "    shell: /bin/bash\n    sudo: ALL=(ALL) NOPASSWD:ALL\n"
            f"    ssh_authorized_keys:\n      - {client_key}\n"
            "ssh_pwauth: false\nssh_keys:\n  ed25519_private: |\n"
            + "".join(f"    {line}\n" for line in private_key.splitlines())
            + f"  ed25519_public: {host_key}\n"
            "runcmd:\n  - [touch, /run/media-kit-smoke-ready]\n"
        )
        (seed / "meta-data").write_text("instance-id: media-kit-fresh-firmware-smoke\nlocal-hostname: media-kit-smoke\n")
        (seed / "network-config").write_text(
            'version: 2\nethernets:\n  kit-lan:\n    match:\n      macaddress: "52:54:00:7f:11:01"\n'
            "    set-name: lan0\n    dhcp4: true\n"
        )
        run("xorriso", "-as", "mkisofs", "-quiet", "-V", "CIDATA", "-J", "-r", "-o", str(scratch / "seed.iso"), str(seed))
        run("qemu-img", "create", "-f", "qcow2", "-F", "qcow2", "-b", str(image.resolve()), str(scratch / "overlay.qcow2"))
        shutil.copyfile("/usr/share/OVMF/OVMF_VARS_4M.fd", scratch / "vars.fd")
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            port = probe.getsockname()[1]
        (scratch / "known_hosts").write_text(f"[127.0.0.1]:{port} {host_key}\n")
        ssh = ["ssh", "-p", str(port), "-i", str(scratch / "client"), "-o", "BatchMode=yes",
               "-o", "ConnectTimeout=5", "-o", "StrictHostKeyChecking=yes", "-o",
               f"UserKnownHostsFile={scratch / 'known_hosts'}", "mediakit-smoke@127.0.0.1"]
        command = ["qemu-system-x86_64", "-machine", f"q35,accel={accelerator}", "-m", "3072", "-smp", "2",
                   "-display", "none", "-monitor", "none", "-serial", f"file:{scratch / 'serial.log'}",
                   "-drive", "if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd",
                   "-drive", f"if=pflash,format=raw,file={scratch / 'vars.fd'}",
                   "-drive", f"if=virtio,format=qcow2,file={scratch / 'overlay.qcow2'}",
                   "-drive", f"media=cdrom,readonly=on,file={scratch / 'seed.iso'}",
                   "-netdev", f"user,id=lan,hostfwd=tcp:127.0.0.1:{port}-:22",
                   "-device", "virtio-net-pci,netdev=lan,mac=52:54:00:7f:11:01", "-no-reboot"]
        process = subprocess.Popen(command)
        try:
            deadline = time.monotonic() + 900
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    raise RuntimeError("Fresh-firmware smoke VM exited before SSH readiness")
                result = subprocess.run(ssh + ["test -e /run/media-kit-smoke-ready"], text=True, capture_output=True, timeout=15)
                if result.returncode == 0:
                    break
                time.sleep(5)
            else:
                raise RuntimeError("Fresh-firmware smoke VM did not apply its per-instance seed within 15 minutes")
            # These assertions execute in a real first boot, without factory NVRAM.
            checks = """set -eu
sudo cloud-init status --wait
test "$(uname -m)" = x86_64
test "$(hostname)" = media-kit-smoke
ip link show lan0 >/dev/null
test -s /etc/machine-id
test -s /etc/ssh/ssh_host_ed25519_key
test ! -e /etc/cloud/cloud-init.disabled
! getent passwd mediakit-builder
test ! -e /home/mediakit-builder
test ! -e /etc/sudoers.d/90-mediakit-builder
test "$(systemctl is-enabled docker.service || true)" = disabled
test "$(systemctl is-enabled docker.socket || true)" = disabled
! systemctl is-active --quiet docker.service
test "$(stat -c %a /data)" = 700
sudo test -s /boot/efi/EFI/BOOT/BOOTX64.EFI
sudo sbverify --list /boot/efi/EFI/BOOT/BOOTX64.EFI
sudo python3 -m compileall -q /opt/starter-kit
"""
            run(*ssh, "bash -s", input=checks, timeout=300)
            Path(report).write_text(json.dumps({"freshFirmwareBoot": "passed", "perInstanceCloudInit": "passed",
                "macMatchedNetwork": "passed", "pinnedSshIdentity": "passed", "factoryIdentityRemoved": "passed",
                "dockerDisabledUntilProvisioned": "passed", "signedFallbackPresent": "passed"}, indent=2) + "\n")
            print("Fresh firmware, per-instance cloud-init, trusted SSH and factory cleanup passed.")
        except Exception:
            serial = scratch / "serial.log"
            if serial.exists():
                # The serial console contains no seeded private key or production credentials.
                print(serial.read_text(errors="replace")[-8000:])
            raise
        finally:
            process.terminate()
            try:
                process.wait(timeout=20)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=10)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", type=Path, required=True)
    parser.add_argument("--accelerator", choices=("kvm", "tcg"), default="tcg")
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    smoke(args.image, args.accelerator, args.report)
