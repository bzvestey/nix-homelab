{
  lib,
  nixosConfigurations,
  pkgs,
}:
let
  hostNames = [
    "observability-pi"
    "framework-01"
    "framework-02"
    "framework-03"
    "services-pi"
  ];
  hasAllHosts = lib.all (hostName: builtins.hasAttr hostName nixosConfigurations) hostNames;
  hostNamesMatch = lib.all (
    hostName: nixosConfigurations.${hostName}.config.networking.hostName == hostName
  ) hostNames;
in
assert hasAllHosts;
assert hostNamesMatch;
pkgs.runCommand "evaluation" { } "touch $out"
