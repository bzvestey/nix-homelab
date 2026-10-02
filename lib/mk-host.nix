{ nixpkgs, revision }:
{
  system,
  hostname,
  modules,
}:
nixpkgs.lib.nixosSystem {
  inherit system;
  modules = [
    (
      { lib, ... }:
      {
        boot.loader.grub.devices = [ "nodev" ];
        fileSystems."/" = lib.mkDefault {
          device = "none";
          fsType = "tmpfs";
        };
        networking.hostName = hostname;
        fleet.telemetry.revision = lib.mkDefault revision;
        system.stateVersion = "25.05";
      }
    )
  ]
  ++ modules;
}
