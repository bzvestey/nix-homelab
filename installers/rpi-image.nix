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
  irrelevantAllwinnerModules = [
    "sun4i-drm"
    "sun8i-mixer"
    "pwm-sun4i"
  ];
  irrelevantRockchipModules = [
    "dw-hdmi"
    "dw-mipi-dsi"
    "rockchipdrm"
    "rockchip-rga"
    "phy-rockchip-pcie"
    "pcie-rockchip-host"
  ];
  telemetryInitializer = import ./telemetry-initializer.nix {
    inherit
      lib
      pkgs
      targetHost
      telemetryIdentity
      ;
  };
in
{
  imports = [ (modulesPath + "/installer/sd-card/sd-image-aarch64.nix") ];
  assertions = [
    {
      assertion = lib.all (
        module: !(builtins.elem module config.boot.initrd.availableKernelModules)
      ) irrelevantAllwinnerModules;
      message = "Pi images must exclude Allwinner-only modules from the Raspberry Pi kernel initrd";
    }
    {
      assertion = lib.all (
        module: !(builtins.elem module config.boot.initrd.availableKernelModules)
      ) irrelevantRockchipModules;
      message = "Pi images must exclude Rockchip-only modules from the Raspberry Pi kernel initrd";
    }
  ];
  image.fileName = lib.mkForce "${targetHost}-bootstrap.img.zst";
  sdImage = {
    compressImage = true;
    firmwareSize = 128;
  };
  # The generic image profile enables all hardware. These contiguous Allwinner-only and
  # Rockchip-only groups are absent from linux-rpi; keep Broadcom and Pi-specific modules enabled.
  boot.initrd.availableKernelModules = {
    sun4i-drm = lib.mkForce false;
    sun8i-mixer = lib.mkForce false;
    pwm-sun4i = lib.mkForce false;
    dw-hdmi = lib.mkForce false;
    dw-mipi-dsi = lib.mkForce false;
    rockchipdrm = lib.mkForce false;
    rockchip-rga = lib.mkForce false;
    phy-rockchip-pcie = lib.mkForce false;
    pcie-rockchip-host = lib.mkForce false;
  };
  environment.systemPackages = lib.optional (targetHost == "observability-pi") telemetryInitializer;
}
