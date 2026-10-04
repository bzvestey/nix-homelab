{
  lib,
  piImageConfigurations,
  nixosConfigurations,
  pkgs,
}:
let
  piHosts = [
    "hl-node-00"
    "hl-node-01"
  ];
  cleanup =
    hostName:
    nixosConfigurations.${hostName}.config.system.activationScripts.raspberry-pi-firmware-cleanup;
  cleanupCommand = "rm -f -- /boot/firmware/start*.elf /boot/firmware/start*.elf.tmp /boot/firmware/fixup*.dat /boot/firmware/fixup*.dat.tmp";
  validateFirmware = ''
    validate_firmware() {
      sourceBoot="$1/share/raspberrypi/boot"
      filteredBoot="$2/share/raspberrypi/boot"
      expected="$TMPDIR/expected-$3"

      cp -a "$sourceBoot" "$expected"
      find "$expected" -type f \( -name 'start*.elf' -o -name 'fixup*.dat' \) -delete
      if find "$filteredBoot" -type f \( -name 'start*.elf' -o -name 'fixup*.dat' \) -print -quit | grep -q .; then
        echo "forbidden external firmware remains below $filteredBoot" >&2
        return 1
      fi
      diff -qr --no-dereference "$expected" "$filteredBoot"
    }
  '';
  nativeFirmwareValidation = lib.optionalString (pkgs.stdenv.hostPlatform.system == "aarch64-linux") (
    lib.concatMapStringsSep "\n" (hostName: ''
      validate_firmware ${pkgs.raspberrypifw} ${
        nixosConfigurations.${hostName}.config.hardware.raspberry-pi.firmware.package
      } ${hostName}
    '') piHosts
  );
in
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
assert lib.all (
  hostName:
  nixosConfigurations.${hostName}.config.fileSystems."/".device == "/dev/disk/by-label/NIXOS_SD"
  && nixosConfigurations.${hostName}.config.fileSystems."/".fsType == "ext4"
) piHosts;
pkgs.runCommand "pi-firmware" { } ''
  ${validateFirmware}

  mkdir -p source/share/raspberrypi/boot/overlays/subdir
  touch source/share/raspberrypi/boot/{bootcode.bin,bcm2712.dtb,start4.elf,fixup4.dat}
  touch source/share/raspberrypi/boot/overlays/{README,vc4.dtbo}
  touch source/share/raspberrypi/boot/overlays/subdir/nested.dtbo
  cp -a source filtered
  rm filtered/share/raspberrypi/boot/{start4.elf,fixup4.dat}
  validate_firmware source filtered synthetic-good

  cp -a filtered missing-overlay
  rm missing-overlay/share/raspberrypi/boot/overlays/vc4.dtbo
  if validate_firmware source missing-overlay synthetic-missing-overlay; then
    echo "validator accepted an incomplete overlay set" >&2
    exit 1
  fi

  cp -a filtered hidden-external-firmware
  touch hidden-external-firmware/share/raspberrypi/boot/overlays/subdir/start_cd.elf
  if validate_firmware source hidden-external-firmware synthetic-hidden-external; then
    echo "validator accepted nested external firmware" >&2
    exit 1
  fi

  ${nativeFirmwareValidation}
  touch "$out"
''
