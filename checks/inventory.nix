{
  pkgs,
  lib,
  inventoryFile ? ../docs/inventory/services.md,
  readiness ? false,
  expectedErrors ? [ ],
}:
let
  inventory = builtins.fromJSON (builtins.readFile inventoryFile);
  isNonEmptyString = value: builtins.isString value && value != "";
  isObservedPositive =
    value:
    builtins.isAttrs value
    && value.status or null == "observed"
    && builtins.isInt (value.bytes or null)
    && value.bytes > 0
    && isNonEmptyString (value.evidence or null);
  isBlocker =
    value:
    builtins.isAttrs value
    && value.status or null == "blocked"
    && isNonEmptyString (value.reason or null)
    && isNonEmptyString (value.collectionCommand or null);
  evidenceReady =
    value:
    builtins.isAttrs value
    && value.status or null == "observed"
    && isNonEmptyString (value.id or null)
    && isNonEmptyString (value.observedAt or null)
    && isNonEmptyString (value.evidence or null);
  validFact = value: isObservedPositive value || isBlocker value;
  targets = inventory.targets or [ ];
  services = lib.filter (service: service.disposition or null == "retain") (
    inventory.services or [ ]
  );
  datasets = inventory.datasets or [ ];
  targetNames = map (target: target.name or null) targets;
  datasetIds = map (dataset: dataset.id or null) datasets;
  duplicates =
    values:
    lib.unique (
      lib.filter (value: builtins.length (lib.filter (other: other == value) values) > 1) values
    );
  targetFor = name: lib.findFirst (target: target.name or null == name) null targets;
  digestValid =
    image: builtins.isString image && builtins.match ".+@sha256:[0-9a-f]{64}" image != null;
  serviceSchemaErrors = lib.concatMap (
    service:
    let
      name = service.name or "<unnamed>";
      requiredLists = [
        "architectures"
        "datasetIds"
        "endpoints"
      ];
      requiredStrings = [
        "targetHost"
        "image"
      ];
      missing = lib.filter (field: !(builtins.hasAttr field service)) (
        requiredLists
        ++ requiredStrings
        ++ [
          "database"
          "backupEvidence"
          "restoreEvidence"
        ]
      );
      badLists = lib.filter (
        field: builtins.hasAttr field service && !builtins.isList service.${field}
      ) requiredLists;
      badStrings = lib.filter (
        field: builtins.hasAttr field service && !isNonEmptyString service.${field}
      ) requiredStrings;
      database = service.database or { };
      databaseValid =
        builtins.isAttrs database
        && builtins.elem (database.kind or null) [
          "none"
          "external"
          "embedded"
        ]
        && ((database.kind or null) == "none" || isNonEmptyString (database.engine or null))
        && (
          (database.kind or null) == "none"
          || isNonEmptyString (database.version or null)
          || isBlocker (database.versionFact or { })
        );
    in
    (map (field: "schema:${name}:missing-${field}") missing)
    ++ (map (field: "schema:${name}:invalid-${field}") badLists)
    ++ (map (field: "schema:${name}:invalid-${field}") badStrings)
    ++ lib.optional (!(digestValid (service.image or null))) "schema:${name}:invalid-image-digest"
    ++ lib.optional (!databaseValid) "schema:${name}:invalid-database"
    ++ lib.optional (
      !(isBlocker (service.backupEvidence or { }) || evidenceReady (service.backupEvidence or { }))
    ) "schema:${name}:invalid-backup-evidence"
    ++ lib.optional (
      !(isBlocker (service.restoreEvidence or { }) || evidenceReady (service.restoreEvidence or { }))
    ) "schema:${name}:invalid-restore-evidence"
  ) services;
  datasetSchemaErrors = lib.concatMap (
    dataset:
    let
      name = dataset.id or "<unnamed>";
    in
    lib.optional (!isNonEmptyString (dataset.id or null)) "schema:${name}:invalid-dataset-id"
    ++ lib.optional (
      !(builtins.elem (dataset.placement or null) [
        "local-copy"
        "shared-retained"
      ])
    ) "schema:${name}:invalid-placement"
    ++ lib.optional (!(validFact (dataset.size or { }))) "schema:${name}:invalid-size"
    ++ lib.optional (
      !(builtins.isList (dataset.sourcePaths or null)) || dataset.sourcePaths == [ ]
    ) "schema:${name}:invalid-source-paths"
    ++ lib.optional (
      (dataset.placement or null) == "local-copy" && !isNonEmptyString (dataset.targetHost or null)
    ) "schema:${name}:missing-target"
  ) datasets;
  targetSchemaErrors = lib.concatMap (
    target:
    let
      name = target.name or "<unnamed>";
    in
    lib.optional (!isNonEmptyString (target.name or null)) "schema:${name}:invalid-target-name"
    ++ lib.optional (!isNonEmptyString (target.address or null)) "schema:${name}:invalid-target-address"
    ++ lib.optional (
      !(builtins.elem (target.architecture or null) [
        "x86_64-linux"
        "aarch64-linux"
      ])
    ) "schema:${name}:invalid-target-architecture"
    ++ lib.optional (!(validFact (target.measuredFreeBytes or { }))) "schema:${name}:invalid-free-bytes"
  ) targets;
  referenceErrors =
    (map (name: "schema:duplicate-target:${name}") (duplicates targetNames))
    ++ (map (id: "schema:duplicate-dataset:${id}") (duplicates datasetIds))
    ++ lib.concatMap (
      service:
      let
        name = service.name or "<unnamed>";
      in
      lib.optional (
        !(builtins.elem (service.targetHost or null) targetNames)
      ) "schema:${name}:unknown-target"
      ++ map (id: "schema:${name}:unknown-dataset:${id}") (
        lib.filter (id: !(builtins.elem id datasetIds)) (service.datasetIds or [ ])
      )
    ) services
    ++ lib.concatMap (
      dataset:
      lib.optional (
        (dataset.placement or null) == "local-copy"
        && !(builtins.elem (dataset.targetHost or null) targetNames)
      ) "schema:${dataset.id or "<unnamed>"}:unknown-target"
    ) datasets;
  readinessErrors =
    lib.concatMap (
      target:
      lib.optional (isBlocker (
        target.measuredFreeBytes or { }
      )) "readiness:${target.name}:free-bytes-blocked"
      ++ map (field: "readiness:${target.name}:${field}-blocked") (
        lib.filter (field: isBlocker (target.hardware.${field} or { })) [
          "installDisk"
          "nic"
          "gpu"
        ]
      )
    ) targets
    ++ lib.concatMap (
      dataset: lib.optional (isBlocker (dataset.size or { })) "readiness:${dataset.id}:size-blocked"
    ) datasets
    ++ lib.concatMap (
      service:
      let
        target = targetFor (service.targetHost or null);
        backup = service.backupEvidence or { };
        restore = service.restoreEvidence or { };
      in
      lib.optional (isBlocker backup) "readiness:${service.name}:backup-blocked"
      ++ lib.optional (isBlocker restore) "readiness:${service.name}:restore-blocked"
      ++ lib.optional (isBlocker (
        service.database.versionFact or { }
      )) "readiness:${service.name}:database-version-blocked"
      ++ lib.optional (
        target != null
        && target.architecture == "aarch64-linux"
        && !(builtins.elem "linux/arm64" (service.architectures or [ ]))
      ) "readiness:${service.name}:missing-linux-arm64"
    ) services
    ++ lib.concatMap (
      target:
      let
        local = lib.filter (
          dataset: dataset.placement or null == "local-copy" && dataset.targetHost or null == target.name
        ) datasets;
        known = lib.all (dataset: isObservedPositive dataset.size) local;
        required = lib.foldl' (sum: dataset: sum + dataset.size.bytes) 0 (
          lib.filter (dataset: isObservedPositive dataset.size) local
        );
      in
      lib.optional (
        known
        && isObservedPositive (target.measuredFreeBytes or { })
        && required * 5 > target.measuredFreeBytes.bytes * 4
      ) "readiness:${target.name}:insufficient-measured-free-space"
    ) targets;
  schemaErrors = serviceSchemaErrors ++ datasetSchemaErrors ++ targetSchemaErrors ++ referenceErrors;
  errors = schemaErrors ++ lib.optionals readiness readinessErrors;
  expected = lib.sort builtins.lessThan expectedErrors;
  actual = lib.sort builtins.lessThan errors;
in
assert lib.assertMsg (
  if expectedErrors != [ ] then actual == expected else errors == [ ]
) "Inventory validation failed:\n${lib.concatStringsSep "\n" errors}";
pkgs.runCommand (if readiness then "inventory-readiness" else "inventory-check") { } ''
  touch $out
''
