{ config, lib, ... }:
{
  assertions = [
    {
      assertion = config.hardware.raspberry-pi.firmware.enable;
      message = "Raspberry Pi 5 hosts must keep the firmware partition managed across system updates";
    }
    {
      assertion =
        config.hardware.raspberry-pi.firmware.uboot.enable
        && config.hardware.raspberry-pi.configtxt.settings.all.kernel == "u-boot.bin"
        && config.hardware.raspberry-pi.configtxt.settings.all.arm_64bit;
      message = "Raspberry Pi 5 hosts must chainload 64-bit U-Boot so firmware can find the NixOS kernel";
    }
    {
      assertion =
        config.boot.loader.generic-extlinux-compatible.enable
        && !config.boot.loader.generic-extlinux-compatible.useGenerationDeviceTree;
      message = "Raspberry Pi 5 hosts must use extlinux with the firmware-supplied device tree";
    }
    {
      assertion =
        config.fileSystems."/boot/firmware".device == "/dev/disk/by-label/FIRMWARE"
        && config.fileSystems."/boot/firmware".fsType == "vfat"
        && !(builtins.elem "noauto" config.fileSystems."/boot/firmware".options);
      message = "Raspberry Pi 5 hosts must mount the FIRMWARE partition for boot updates";
    }
    {
      assertion = !(builtins.elem "tpm-crb" config.boot.initrd.availableKernelModules);
      message = "Raspberry Pi 5 hosts must exclude the x86 TPM CRB driver from the initrd";
    }
  ];

  boot.initrd.availableKernelModules.tpm-crb = lib.mkForce false;
  boot.loader = {
    grub.enable = lib.mkForce false;
    generic-extlinux-compatible.enable = true;
  };
  hardware.raspberry-pi.firmware = {
    enable = true;
    uboot.enable = true;
  };
  fileSystems."/boot/firmware" = {
    device = "/dev/disk/by-label/FIRMWARE";
    fsType = "vfat";
    options = lib.mkForce [ "nofail" ];
  };
}
