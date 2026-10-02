{
  lib,
  modulesPath,
  pkgs,
  targetHost,
  telemetryIdentity ? null,
  ...
}:
let
  guard = pkgs.replaceVars ./destructive-device-guard.sh {
    bash = "${pkgs.bash}/bin/bash";
    devRoot = "/dev";
    sysDevBlock = "/sys/dev/block";
    readlink = "${pkgs.coreutils}/bin/readlink";
    stat = "${pkgs.coreutils}/bin/stat";
  };
  telemetryInitializer = pkgs.writeShellApplication {
    name = "initialize-telemetry-ssd";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.e2fsprogs
      pkgs.gnused
      pkgs.systemd
      pkgs.util-linux
    ];
    text =
      let
        identity =
          if telemetryIdentity == null then
            {
              byId = "UNRESOLVED";
              model = "UNRESOLVED";
              serial = "UNRESOLVED";
              sectors = 0;
            }
          else
            telemetryIdentity;
      in
      ''
        set -euo pipefail
        read -r -p "Type ${targetHost} to authorize telemetry SSD initialization: " typed_host
        token=$(${guard} ${
          lib.escapeShellArgs [
            targetHost
            identity.byId
            identity.model
            identity.serial
            (toString identity.sectors)
          ]
        } "$typed_host")
        IFS='|' read -r stable_id device major_minor model serial sectors <<<"$token"
        echo "About to create an ext4 filesystem on verified device $device" >&2
        read -r -p "Type INITIALIZE TELEMETRY SSD: " confirmation
        [ "$confirmation" = "INITIALIZE TELEMETRY SSD" ] || { echo "confirmation mismatch" >&2; exit 1; }
        udevadm settle
        exec {device_fd}<"$device"
        flock -x "$device_fd"
        boundary_token=$(${guard} ${
          lib.escapeShellArgs [
            targetHost
            identity.byId
            identity.model
            identity.serial
            (toString identity.sectors)
          ]
        } "$typed_host")
        [ "$boundary_token" = "$token" ] || { echo "device identity changed at format boundary" >&2; exit 1; }
        mkfs.ext4 -F -L telemetry "$device"
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
