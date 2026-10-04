{
  images,
  lib,
  nixosConfigurations,
  pkgs,
}:
let
  hostNames = [
    "hl-node-00"
    "hl-node-01"
    "hl-node-02"
    "hl-node-03"
    "hl-node-04"
  ];
  hasAllHosts = builtins.attrNames nixosConfigurations == hostNames;
  hasAllImages = builtins.attrNames images == hostNames;
  hostNamesMatch = lib.all (
    hostName: nixosConfigurations.${hostName}.config.networking.hostName == hostName
  ) hostNames;
  telemetryRevisionsKnown = lib.all (
    hostName: nixosConfigurations.${hostName}.config.fleet.telemetry.revision != "unknown"
  ) hostNames;
in
assert hasAllHosts;
assert hasAllImages;
assert hostNamesMatch;
assert telemetryRevisionsKnown;
pkgs.runCommand "evaluation" { } "touch $out"
