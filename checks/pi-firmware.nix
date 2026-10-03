{
  lib,
  piImageConfigurations,
  nixosConfigurations,
  pkgs,
}:
let
  piHosts = [
    "observability-pi"
    "services-pi"
  ];
  bootFiles =
    hostName:
    builtins.attrNames (
      builtins.readDir "${
        nixosConfigurations.${hostName}.config.hardware.raspberry-pi.firmware.package
      }/share/raspberrypi/boot"
    );
  hasExternalFirmware = fileName: builtins.match "(start.*\\.elf|fixup.*\\.dat)" fileName != null;
  requiredBootInputsPresent =
    hostName:
    let
      files = bootFiles hostName;
    in
    builtins.elem "bootcode.bin" files
    && lib.any (fileName: lib.hasSuffix ".dtb" fileName) files
    && builtins.pathExists "${
      nixosConfigurations.${hostName}.config.hardware.raspberry-pi.firmware.package
    }/share/raspberrypi/boot/overlays";
  cleanup =
    hostName:
    nixosConfigurations.${hostName}.config.system.activationScripts.raspberry-pi-firmware-cleanup;
  cleanupCommand = "rm -f -- /boot/firmware/start*.elf /boot/firmware/start*.elf.tmp /boot/firmware/fixup*.dat /boot/firmware/fixup*.dat.tmp";
  firmwareContentsValid = lib.all (
    hostName:
    lib.all (fileName: !hasExternalFirmware fileName) (bootFiles hostName)
    && requiredBootInputsPresent hostName
  ) piHosts;
in
assert pkgs.stdenv.hostPlatform.system != "aarch64-linux" || firmwareContentsValid;
assert lib.all (
  hostName:
  builtins.elem "raspberry-pi-firmware-cleanup"
    nixosConfigurations.${hostName}.config.system.activationScripts.raspberry-pi-firmware.deps
) piHosts;
assert lib.all (
  hostName:
  cleanup hostName == {
    deps = [ "specialfs" ];
    supportsDryActivation = false;
    text = ''
      if mountpoint -q /boot/firmware; then
        ${cleanupCommand}
      else
        echo "rpi-firmware-cleanup: /boot/firmware is not a mounted partition, skipping stale firmware cleanup" >&2
      fi
    '';
  }
) piHosts;
assert lib.all (
  hostName: piImageConfigurations.${hostName}.config.sdImage.firmwareSize == 128
) piHosts;
pkgs.runCommand "pi-firmware" { } "touch $out"
