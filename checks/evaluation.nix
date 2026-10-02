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
  telemetryRevisionsKnown = lib.all (
    hostName: nixosConfigurations.${hostName}.config.fleet.telemetry.revision != "unknown"
  ) hostNames;
in
assert hasAllHosts;
assert hostNamesMatch;
assert telemetryRevisionsKnown;
pkgs.runCommand "evaluation" { } "touch $out"
