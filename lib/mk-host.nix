{ nixpkgs }:
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
        system.stateVersion = "25.05";
      }
    )
  ]
  ++ modules;
}
