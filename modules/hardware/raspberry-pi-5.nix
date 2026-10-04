{
  config,
  lib,
  pkgs,
  ...
}:
let
  pi5Firmware = pkgs.runCommand "raspberrypi-firmware-pi5" { } ''
    mkdir -p "$out"
    cp -a ${pkgs.raspberrypifw}/share "$out/"
    chmod -R u+w "$out/share/raspberrypi/boot"
    rm -f -- "$out"/share/raspberrypi/boot/start*.elf "$out"/share/raspberrypi/boot/fixup*.dat
  '';
in
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
    package = pi5Firmware;
    uboot.enable = true;
  };
  system.activationScripts = {
    raspberry-pi-firmware-cleanup = {
      deps = [ "specialfs" ];
      text = ''
        if mountpoint -q /boot/firmware; then
          rm -f -- /boot/firmware/start*.elf /boot/firmware/start*.elf.tmp /boot/firmware/fixup*.dat /boot/firmware/fixup*.dat.tmp
        else
          echo "rpi-firmware-cleanup: /boot/firmware is not a mounted partition, skipping stale firmware cleanup" >&2
        fi
      '';
    };
    raspberry-pi-firmware.deps = lib.mkAfter [ "raspberry-pi-firmware-cleanup" ];
  };
  fileSystems."/boot/firmware" = {
    device = "/dev/disk/by-label/FIRMWARE";
    fsType = "vfat";
    options = lib.mkForce [ "nofail" ];
  };
  fileSystems."/" = {
    device = "/dev/disk/by-label/NIXOS_SD";
    fsType = "ext4";
  };
}
