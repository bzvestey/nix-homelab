{ config, lib, ... }:
let
  cfg = config.services.fleet.lightweightApplications;
  names = [
    "commafeed"
    "donetick"
    "homarr"
    "mailrise"
    "pocket-id"
    "wallos"
  ];
in
{
  imports = [ ./lightweight-shared.nix ] ++ map (name: ./. + "/${name}") names;
  config = lib.mkIf cfg.enable {
    services.fleet = lib.genAttrs names (name: {
      enable = lib.mkIf (lib.elem name cfg.applications) (lib.mkDefault true);
    });
    fleet.telemetry.enable = true;
  };
}
