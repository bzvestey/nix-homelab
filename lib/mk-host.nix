{ nixpkgs }:
{
  system,
  hostname,
  modules,
}:
nixpkgs.lib.nixosSystem {
  inherit system;
  modules = [
    {
      boot.loader.grub.devices = [ "nodev" ];
      fileSystems."/" = {
        device = "none";
        fsType = "tmpfs";
      };
      networking.hostName = hostname;
      system.stateVersion = "25.05";
    }
  ]
  ++ modules;
}
