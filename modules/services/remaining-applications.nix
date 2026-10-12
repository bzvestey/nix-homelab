{ config, lib, ... }:
let
  cfg = config.services.fleet.remainingApplications;
in
{
  imports = [
    ./remaining-options.nix
    ./forgejo
    ./foundry
    ./tangled-knot
    ./tranquil-pds
  ];
  config = lib.mkIf cfg.enable {
    services.fleet = lib.genAttrs [ "forgejo" "foundry" "tangled-knot" "tranquil-pds" ] (_: {
      enable = lib.mkDefault true;
    });
  };
}
