{
  config,
  lib,
  modulesPath,
  pkgs,
  targetHost,
  telemetryIdentity ? null,
  ...
}:
let
  irrelevantRockchipModules = [
    "dw-hdmi"
    "dw-mipi-dsi"
    "rockchipdrm"
    "rockchip-rga"
    "phy-rockchip-pcie"
    "pcie-rockchip-host"
  ];
  guard = pkgs.replaceVars ./destructive-device-guard.sh {
    bash = "${pkgs.bash}/bin/bash";
    devRoot = "/dev";
    sysDevBlock = "/sys/dev/block";
    readlink = "${pkgs.coreutils}/bin/readlink";
    stat = "${pkgs.coreutils}/bin/stat";
    logGuard = ":";
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
        device=''${token#*|}
        device=''${device%%|*}
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
  assertions = [
    {
      assertion = lib.all (
        module: !(builtins.elem module config.boot.initrd.availableKernelModules)
      ) irrelevantRockchipModules;
      message = "Pi images must exclude Rockchip-only modules from the Raspberry Pi kernel initrd";
    }
  ];
  image.fileName = lib.mkForce "${targetHost}-bootstrap.img.zst";
  sdImage.compressImage = true;
  # The generic image profile enables all hardware. These Rockchip-only modules are absent from
  # linux-rpi; disable only that contiguous platform-specific group as recommended by Nixpkgs.
  boot.initrd.availableKernelModules = {
    dw-hdmi = lib.mkForce false;
    dw-mipi-dsi = lib.mkForce false;
    rockchipdrm = lib.mkForce false;
    rockchip-rga = lib.mkForce false;
    phy-rockchip-pcie = lib.mkForce false;
    pcie-rockchip-host = lib.mkForce false;
  };
  boot.loader = {
    grub.enable = lib.mkForce false;
    generic-extlinux-compatible.enable = true;
  };
  environment.systemPackages = lib.optional (targetHost == "observability-pi") telemetryInitializer;
}
