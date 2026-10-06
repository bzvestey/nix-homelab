{
  lib,
  pkgs,
  targetHost,
  telemetryIdentity ? null,
  deviceGuard ? null,
  mkfsExt4 ? null,
}:
let
  guard =
    if deviceGuard == null then
      pkgs.replaceVars ./destructive-device-guard.sh {
        bash = "${pkgs.bash}/bin/bash";
        devRoot = "/dev";
        sysDevBlock = "/sys/dev/block";
        readlink = "${pkgs.coreutils}/bin/readlink";
        stat = "${pkgs.coreutils}/bin/stat";
        tr = "${pkgs.coreutils}/bin/tr";
        lsblk = "${pkgs.util-linux}/bin/lsblk";
        logGuard = ":";
      }
    else
      deviceGuard;
  mkfs = if mkfsExt4 == null then "${pkgs.e2fsprogs}/bin/mkfs.ext4" else mkfsExt4;
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
pkgs.writeShellApplication {
  name = "initialize-telemetry-ssd";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.e2fsprogs
    pkgs.gnused
    pkgs.systemd
    pkgs.util-linux
  ];
  text = ''
    set -euo pipefail
    read -r -p "Type ${targetHost} to authorize telemetry SSD initialization: " typed_host
    token=$(${pkgs.bash}/bin/bash ${guard} ${
      lib.escapeShellArgs [
        targetHost
        identity.byId
        identity.model
        identity.serial
        (toString identity.sectors)
      ]
    } "$typed_host")
    device=''${token#*|}
    device=''${device%%|*}
    echo "About to create an ext4 filesystem on verified device $device" >&2
    read -r -p "Type INITIALIZE TELEMETRY SSD: " confirmation
    [ "$confirmation" = "INITIALIZE TELEMETRY SSD" ] || { echo "confirmation mismatch" >&2; exit 1; }
    udevadm settle
    exec {device_fd}<"$device"
    flock -x "$device_fd"
    boundary_token=$(${pkgs.bash}/bin/bash ${guard} ${
      lib.escapeShellArgs [
        targetHost
        identity.byId
        identity.model
        identity.serial
        (toString identity.sectors)
      ]
    } "$typed_host")
    [ "$boundary_token" = "$token" ] || { echo "device identity changed at format boundary" >&2; exit 1; }
    ${mkfs} -F -O project,quota -L telemetry "$device"
  '';
}
