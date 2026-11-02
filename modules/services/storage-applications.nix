{ config, lib, ... }:
{
  imports = [
    ./storage-shared.nix
    ./audiobookshelf
    ./jellyfin
    ./kavita
    ./vikunja
  ];
  config = lib.mkIf config.services.fleet.storageApplications.enable {
    services.fleet = lib.genAttrs [ "audiobookshelf" "jellyfin" "kavita" "vikunja" ] (_: {
      enable = lib.mkDefault true;
    });
  };
}
