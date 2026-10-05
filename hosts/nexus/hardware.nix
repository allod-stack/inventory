# Synthetic hypervisor hardware for the public template. A deployment
# replaces this whole file with the machine's own generated
# hardware-configuration.nix; nothing else references its contents.
# `nexus.nixosModules.host` provides systemd-boot, so this supplies only
# kernel modules and the root and EFI filesystems.
{ ... }:
{
  boot.initrd.availableKernelModules = [ "nvme" "xhci_pci" "ahci" "usb_storage" ];
  boot.kernelModules = [ "kvm-intel" ];
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };
  fileSystems."/boot" = {
    device = "/dev/disk/by-label/boot";
    fsType = "vfat";
  };
}
