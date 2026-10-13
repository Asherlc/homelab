#!/usr/bin/env bash
set -euo pipefail

sudo install -d -m 0755 /opt/starter-kit
sudo cp -a /tmp/kit-guest/. /opt/starter-kit/
sudo install -m 0644 /tmp/release.json /opt/starter-kit/release.json
sudo chown -R root:root /opt/starter-kit
sudo find /opt/starter-kit -type f -name '*.py' -exec chmod 0755 {} +
sudo systemctl disable --now docker.service docker.socket avahi-daemon.service
sudo install -d -m 0700 /data /etc/starter-kit
# A cloned Generation 2 disk has no firmware boot entry on its new host.
# Use Ubuntu's signed shim at the portable UEFI fallback path.
sudo install -d /boot/efi/EFI/BOOT
sudo cp -a /boot/efi/EFI/ubuntu/. /boot/efi/EFI/BOOT/
sudo cp /boot/efi/EFI/ubuntu/shimx64.efi /boot/efi/EFI/BOOT/BOOTX64.EFI
sudo test -s /boot/efi/EFI/BOOT/grubx64.efi
sudo sbverify --list /boot/efi/EFI/BOOT/BOOTX64.EFI
# The image is built on QEMU and boots from Hyper-V's synthetic SCSI controller.
printf '%s\n' hv_vmbus hv_storvsc hv_netvsc | sudo tee -a /etc/initramfs-tools/modules >/dev/null
sudo update-initramfs -u -k all
sudo rm -f /etc/cloud/cloud.cfg.d/subiquity-disable-cloudinit-networking.cfg /etc/cloud/cloud.cfg.d/99-installer.cfg
sudo tee /etc/cloud/cloud.cfg.d/99-media-kit.cfg >/dev/null <<'CLOUD'
datasource_list: [NoCloud, None]
CLOUD

# Remove only factory identity/state. Real credentials arrive in per-install CIDATA.
sudo tee /usr/local/sbin/media-kit-generalize >/dev/null <<'CLEANUP'
#!/usr/bin/env bash
set -euo pipefail
systemctl stop docker.service docker.socket || true
cloud-init clean --logs --machine-id --seed
rm -f /etc/ssh/ssh_host_*
rm -f /etc/netplan/*.yaml
rm -rf /var/lib/docker/* /tmp/kit-guest /tmp/release.json
rm -f /root/.bash_history
userdel --force --remove mediakit-builder
rm -f /etc/sudoers.d/90-cloud-init-users
rm -f /etc/sudoers.d/90-mediakit-builder
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/packer-shell*
find /var/log -type f -exec truncate -s 0 {} +
sync
fstrim -v /
shutdown -P now
CLEANUP
sudo chmod 0755 /usr/local/sbin/media-kit-generalize
sudo python3 -m compileall -q /opt/starter-kit
