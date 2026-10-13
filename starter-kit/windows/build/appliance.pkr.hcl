packer {
  required_plugins {
    qemu = {
      version = "= 1.1.7"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

variable "output_dir" { type = string }
variable "seed_dir" { type = string }
variable "private_key" { type = string }
variable "guest_dir" { type = string }
variable "manifest_path" { type = string }
variable "accelerator" {
  type    = string
  default = "tcg"
}
variable "efi_code" {
  type    = string
  default = "/usr/share/OVMF/OVMF_CODE_4M.fd"
}
variable "efi_vars" {
  type    = string
  default = "/usr/share/OVMF/OVMF_VARS_4M.fd"
}

source "qemu" "media_kit" {
  iso_url          = "https://releases.ubuntu.com/24.04/ubuntu-24.04.5-live-server-amd64.iso"
  iso_checksum     = "sha256:97f3d7ffb032c3eb3b23d2c8be9cc76e60c2c1f2c0146ba5ba9fe01cafae0fd8"
  output_directory = var.output_dir
  vm_name          = "media-kit.qcow2"
  disk_size        = "32768M"
  format           = "qcow2"
  disk_interface   = "virtio"
  net_device       = "virtio-net"
  machine_type     = "q35"
  accelerator      = var.accelerator
  cpus             = 2
  memory           = 3072
  headless         = true
  efi_boot         = true
  efi_firmware_code = var.efi_code
  efi_firmware_vars = var.efi_vars
  cd_files         = ["${var.seed_dir}/user-data", "${var.seed_dir}/meta-data"]
  cd_label         = "CIDATA"
  ssh_username     = "mediakit-builder"
  ssh_private_key_file = var.private_key
  ssh_timeout      = "60m"
  boot_wait        = "5s"
  boot_command = [
    "<esc><wait>c<wait>",
    "linux /casper/vmlinuz autoinstall ds=nocloud ---<enter><wait>",
    "initrd /casper/initrd<enter><wait>",
    "boot<enter>"
  ]
  shutdown_command = "sudo /usr/local/sbin/media-kit-generalize"
}

build {
  sources = ["source.qemu.media_kit"]
  provisioner "shell" {
    inline = ["mkdir -p /tmp/kit-guest"]
  }
  provisioner "file" {
    source      = var.guest_dir
    destination = "/tmp/kit-guest"
  }
  provisioner "file" {
    source      = var.manifest_path
    destination = "/tmp/release.json"
  }
  provisioner "shell" {
    script = "${path.root}/provision-appliance.sh"
  }
}
