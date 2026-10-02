{
  pkgs,
  lib,
  inventoryFile ? ../docs/inventory/services.md,
}:
let
  inventory = builtins.fromJSON (builtins.readFile inventoryFile);
  required = [
    "targetHost"
    "image"
    "architectures"
    "database"
    "sourcePaths"
    "targetPaths"
    "actualBytes"
    "endpoints"
    "backupMethod"
    "restoreCheck"
  ];
  retained = lib.filter (service: service.disposition == "retain") inventory.services;
  missingFor =
    service:
    lib.filter (
      field:
      !(builtins.hasAttr field service)
      || service.${field} == null
      || service.${field} == [ ]
      || service.${field} == ""
    ) required;
  missing = lib.filter (entry: entry.fields != [ ]) (
    map (service: {
      inherit (service) name;
      fields = missingFor service;
    }) retained
  );
  targetFor = name: lib.findFirst (target: target.name == name) null inventory.targets;
  complete = lib.filter (service: missingFor service == [ ]) retained;
  imageWithoutDigest = lib.filter (
    service: builtins.match ".+@sha256:[0-9a-f]{64}" service.image == null
  ) complete;
  oversized = lib.filter (
    target:
    let
      targetBytes = lib.foldl' (total: service: total + service.actualBytes) 0 (
        lib.filter (service: service.targetHost == target.name) complete
      );
    in
    targetBytes * 5 > target.freeBytes * 4
  ) inventory.targets;
  unsupportedArm64 = lib.filter (
    service:
    let
      target = targetFor service.targetHost;
    in
    target != null
    && target.architecture == "aarch64-linux"
    && !(builtins.elem "linux/arm64" service.architectures)
  ) complete;
  errors =
    (map (entry: "${entry.name}: missing ${lib.concatStringsSep ", " entry.fields}") missing)
    ++ (map (service: "${service.name}: image is not pinned to a sha256 digest") imageWithoutDigest)
    ++ (map (
      target: "${target.name}: aggregate actualBytes plus 25% headroom exceeds free capacity"
    ) oversized)
    ++ (map (
      service: "${service.name}: image lacks linux/arm64 for ${service.targetHost}"
    ) unsupportedArm64);
in
assert lib.assertMsg (
  errors == [ ]
) "Inventory validation failed:\n${lib.concatStringsSep "\n" errors}";
pkgs.runCommand "inventory-check" { } ''
  touch $out
''
