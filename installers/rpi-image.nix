{
  lib,
  modulesPath,
  pkgs,
  targetHost,
  telemetryIdentity ? null,
  ...
}:
let
  guard = pkgs.writeShellScript "destructive-device-guard" (
    builtins.readFile ./destructive-device-guard.sh
  );
  telemetryInitializer = pkgs.writeShellApplication {
    name = "initialize-telemetry-ssd";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.e2fsprogs
      pkgs.gnused
    ];
    text =
      let
        identity =
          if telemetryIdentity == null then
            {
              model = "UNRESOLVED";
              serial = "UNRESOLVED";
              capacityBytes = 0;
            }
          else
            telemetryIdentity;
      in
      ''
        set -euo pipefail
        read -r -p "Type ${targetHost} to authorize telemetry SSD initialization: " typed_host
        device=$(${guard} ${
          lib.escapeShellArgs [
            targetHost
            identity.model
            identity.serial
            (toString identity.capacityBytes)
          ]
        } "$typed_host")
        echo "About to create an ext4 filesystem on verified device $device" >&2
        read -r -p "Type INITIALIZE TELEMETRY SSD: " confirmation
        [ "$confirmation" = "INITIALIZE TELEMETRY SSD" ] || { echo "confirmation mismatch" >&2; exit 1; }
        exec mkfs.ext4 -F -L telemetry "$device"
      '';
  };
in
{
  imports = [ (modulesPath + "/installer/sd-card/sd-image-aarch64.nix") ];
  image.fileName = lib.mkForce "${targetHost}-bootstrap.img.zst";
  sdImage.compressImage = true;
  boot.loader = {
    grub.enable = lib.mkForce false;
    generic-extlinux-compatible.enable = true;
  };
  environment.systemPackages = lib.optional (targetHost == "observability-pi") telemetryInitializer;
}
