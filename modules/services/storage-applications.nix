{ config, lib, ... }:
{
  imports = [
    ./storage-shared.nix
    ./jellyfin
    ./kavita
    ./vikunja
  ];
  config = lib.mkIf config.services.fleet.storageApplications.enable {
    services.fleet = lib.genAttrs [ "jellyfin" "kavita" "vikunja" ] (_: {
      enable = lib.mkDefault true;
    });
  };
}
