{ config, lib, ... }:
let
  names = [
    "deluge"
    "prowlarr"
    "publication-manager"
    "radarr"
    "sabnzbd"
    "sonarr"
    "whisparr"
  ];
in
{
  imports = map (name: ./. + "/${name}") names;
  options.services.fleet.mediaAutomation.enable =
    lib.mkEnableOption "source-pinned media automation with fail-closed Deluge VPN";
  config = lib.mkIf config.services.fleet.mediaAutomation.enable {
    services.fleet = lib.genAttrs names (_: {
      enable = lib.mkDefault true;
    });
  };
}
