{
  pkgs,
  lib,
  inventoryFile ? ../docs/inventory/services.md,
  readiness ? false,
  expectedErrors ? [ ],
  fixtureMode ? false,
}:
let
  inventory = builtins.fromJSON (builtins.readFile inventoryFile);
  isNonEmptyString = value: builtins.isString value && value != "";
  isObservationDate =
    value: builtins.isString value && builtins.match "[0-9]{4}-[0-9]{2}-[0-9]{2}" value != null;
  validEvidence =
    value:
    builtins.isAttrs value
    && (
      (
        (value.type or null) == "command-output"
        && (
          (
            builtins.elem (value.command or null) [
              "df-bytes"
              "du-bytes"
              "lsblk-json"
              "network-sysfs"
              "lspci-numeric"
              "database-version-query"
              "database-path-du-bytes"
              "backup-inspection"
              "restore-test"
            ]
            && isNonEmptyString (value.scope or null)
          )
          || builtins.elem (value.reference or null) [
            "du -sb in source workload"
            "du -sb for repository and PostgreSQL filesystems, summed once"
            "du -sb for library and PostgreSQL filesystems, summed once"
            "du -sb for files and PostgreSQL filesystem, summed once"
            "du -sb once for the shared mount used by five services"
            "du -sb on NAS-backed mount"
          ]
        )
      )
      || (
        (value.type or null) == "kubernetes-api"
        && isNonEmptyString (value.resource or null)
        && isNonEmptyString (value.field or null)
      )
      || ((value.type or null) == "api" && value.reference or null == "CNPG image and cluster status")
      || (
        (value.type or null) == "declaration"
        && (
          (isNonEmptyString (value.file or null) && isNonEmptyString (value.attribute or null))
          || value.reference or null == "configuration is declarative; secrets remain in secret manager"
        )
      )
      # Synthetic fixture evidence is deliberately isolated from inventory evidence.
      || (fixtureMode && (value.type or null) == "fixture")
    );
  observedMetadataValid =
    value:
    isNonEmptyString (value.stableId or null)
    && isObservationDate (value.observedAt or null)
    && validEvidence (value.evidence or { });
  isObservedPositive =
    value:
    builtins.isAttrs value
    && value.status or null == "observed"
    && builtins.isInt (value.bytes or null)
    && value.bytes > 0
    && observedMetadataValid value;
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
    && observedMetadataValid value;
  versionReady =
    value:
    builtins.isAttrs value
    && value.status or null == "observed"
    && isNonEmptyString (value.value or null)
    && builtins.match "[0-9]+\\.[0-9]+(\\.[0-9]+)*" value.value != null
    && observedMetadataValid value
    && builtins.elem (value.evidence.type or null) [
      "api"
      "command-output"
      "kubernetes-api"
      "fixture"
    ];
  fixtureEvidence = value: fixtureMode && value.evidence.type or null == "fixture";
  installDiskReady =
    value:
    builtins.isAttrs value
    && value.status or null == "observed"
    && observedMetadataValid value
    && (
      fixtureEvidence value
      || (
        isNonEmptyString (value.model or null)
        && isNonEmptyString (value.serial or null)
        && builtins.isInt (value.capacityBytes or null)
        && value.capacityBytes > 0
        && builtins.match "/dev/disk/by-id/.+" (value.byIdPath or "") != null
        && value.stableId == value.byIdPath
        && value.evidence.type == "command-output"
        && value.evidence.command == "lsblk-json"
      )
    );
  nicReady =
    value:
    builtins.isAttrs value
    && value.status or null == "observed"
    && observedMetadataValid value
    && (
      fixtureEvidence value
      || (
        builtins.match "[a-zA-Z0-9][a-zA-Z0-9_.-]*" (value.interface or "") != null
        && builtins.match "[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}" (value.macAddress or "") != null
        && value.stableId == value.macAddress
        && value.evidence.type == "command-output"
        && value.evidence.command == "network-sysfs"
      )
    );
  gpuReady =
    value:
    builtins.isAttrs value
    && value.status or null == "observed"
    && observedMetadataValid value
    && (
      fixtureEvidence value
      || (
        builtins.match "[0-9a-fA-F]{4}:[0-9a-fA-F]{4}" (value.pciId or "") != null
        &&
          builtins.match "[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\\.[0-7]" (value.deviceAddress or "")
          != null
        && value.stableId == "${value.deviceAddress}:${value.pciId}"
        && value.evidence.type == "command-output"
        && value.evidence.command == "lspci-numeric"
      )
    );
  notApplicable =
    value:
    builtins.isAttrs value
    && value.status or null == "not-applicable"
    && isNonEmptyString (value.reason or null);
  validFact = value: isObservedPositive value || isBlocker value;
  targets = inventory.targets or [ ];
  services = lib.filter (service: service.disposition or null == "retain") (
    inventory.services or [ ]
  );
  datasets = inventory.datasets or [ ];
  allServices = inventory.services or [ ];
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
      databaseKind = database.kind or null;
      databaseDatasetId = database.datasetId or null;
      databaseDataset = lib.findFirst (dataset: dataset.id or null == databaseDatasetId) null datasets;
      databaseId = database.databaseId or null;
      databaseSourcePaths = database.sourcePaths or null;
      databaseTargetPaths = database.targetPaths or null;
      durableDatabase = builtins.elem databaseKind [
        "embedded"
        "external"
      ];
      databaseEvidence = database.datasetEvidence or { };
      databaseEvidenceReady =
        builtins.isAttrs databaseEvidence
        && databaseEvidence.status or null == "observed"
        && databaseEvidence.databaseId or null == databaseId
        && databaseEvidence.datasetId or null == databaseDatasetId
        && databaseEvidence.ownerService or null == name
        && databaseEvidence.targetHost or null == service.targetHost or null
        && builtins.isList (databaseEvidence.sourcePaths or null)
        &&
          lib.sort builtins.lessThan databaseEvidence.sourcePaths
          == lib.sort builtins.lessThan databaseSourcePaths
        && builtins.isList (databaseEvidence.targetPaths or null)
        &&
          lib.sort builtins.lessThan databaseEvidence.targetPaths
          == lib.sort builtins.lessThan databaseTargetPaths
        && databaseDataset != null
        && isObservedPositive (databaseDataset.size or { })
        && databaseEvidence.sizeObservationStableId or null == databaseDataset.size.stableId
        && databaseEvidence.sizeObservationBytes or null == databaseDataset.size.bytes
        && observedMetadataValid databaseEvidence
        && databaseEvidence.evidence.type or null == "command-output"
        && databaseEvidence.evidence.command or null == "database-path-du-bytes"
        && databaseEvidence.evidence.scope or null == "declared-database-paths";
      databaseValid =
        builtins.isAttrs database
        && builtins.elem databaseKind [
          "none"
          "rebuildable-cache"
          "external"
          "embedded"
        ]
        && (
          builtins.elem databaseKind [
            "none"
            "rebuildable-cache"
          ]
          || (
            isNonEmptyString (database.engine or null)
            && isNonEmptyString databaseId
            && builtins.isList databaseSourcePaths
            && databaseSourcePaths != [ ]
            && builtins.isList databaseTargetPaths
            && databaseTargetPaths != [ ]
            && databaseDataset != null
            && lib.all (path: builtins.elem path (databaseDataset.sourcePaths or [ ])) databaseSourcePaths
            && lib.all (path: builtins.elem path (databaseDataset.targetPaths or [ ])) databaseTargetPaths
          )
        )
        && (
          builtins.elem databaseKind [
            "none"
            "rebuildable-cache"
          ]
          || versionReady (database.versionFact or { })
          || isBlocker (database.versionFact or { })
        );
    in
    (map (field: "schema:${name}:missing-${field}") missing)
    ++ (map (field: "schema:${name}:invalid-${field}") badLists)
    ++ (map (field: "schema:${name}:invalid-${field}") badStrings)
    ++ lib.optional (
      !(builtins.isList (service.architectures or null))
      || service.architectures == [ ]
      || !lib.all (
        architecture:
        builtins.elem architecture [
          "linux/amd64"
          "linux/arm64"
          "linux/arm"
        ]
      ) service.architectures
    ) "schema:${name}:invalid-architectures"
    ++ lib.optional (!(digestValid (service.image or null))) "schema:${name}:invalid-image-digest"
    ++ lib.optional (!databaseValid) "schema:${name}:invalid-database"
    ++ lib.optional (
      durableDatabase && !isNonEmptyString databaseDatasetId
    ) "schema:${name}:missing-database-dataset"
    ++ lib.optional (
      durableDatabase
      && databaseDataset != null
      && !(builtins.elem name (databaseDataset.ownerServices or [ ]))
    ) "schema:${name}:database-dataset-owner-mismatch"
    ++ lib.optional (
      durableDatabase
      && isNonEmptyString databaseDatasetId
      && !(databaseEvidenceReady || isBlocker databaseEvidence)
    ) "schema:${name}:invalid-database-dataset-evidence"
    ++ lib.optional (
      durableDatabase
      && databaseDataset != null
      && databaseDataset.targetHost or null != service.targetHost or null
    ) "schema:${name}:database-dataset-target-mismatch"
    ++ lib.optional (
      durableDatabase
      && isNonEmptyString databaseDatasetId
      && !(builtins.elem databaseDatasetId (service.datasetIds or [ ]))
    ) "schema:${name}:database-dataset-not-linked"
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
      !(builtins.isList (dataset.ownerServices or null)) || dataset.ownerServices == [ ]
    ) "schema:${name}:invalid-owner-services"
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
      requirements = target.hardwareRequirements or { };
      hardware = target.hardware or { };
      hardwareFields = [
        "installDisk"
        "nic"
        "gpu"
      ];
      hardwareReady = {
        installDisk = installDiskReady;
        nic = nicReady;
        gpu = gpuReady;
      };
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
    ++ lib.concatMap (
      field:
      lib.optional (
        !(builtins.elem (requirements.${field} or null) [
          "required"
          "optional"
        ])
      ) "schema:${name}:invalid-hardware-requirement-${field}"
      ++ lib.optional (!(builtins.hasAttr field hardware)) "schema:${name}:missing-hardware-${field}"
      ++ lib.optional (
        builtins.hasAttr field hardware
        && !(
          isBlocker hardware.${field}
          || hardwareReady.${field} hardware.${field}
          || ((requirements.${field} or null) == "optional" && notApplicable hardware.${field})
        )
      ) "schema:${name}:invalid-hardware-${field}"
    ) hardwareFields
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
  dependencyErrors = lib.concatMap (
    service:
    let
      name = service.name or "<unnamed>";
      serviceDependencies =
        map (endpoint: builtins.head (builtins.match "service://([^:/.]+).*" endpoint))
          (
            lib.filter (
              endpoint: builtins.isString endpoint && builtins.match "service://.*" endpoint != null
            ) (service.endpoints or [ ])
          );
    in
    lib.concatMap (
      dependency:
      let
        dependedService = lib.findFirst (candidate: candidate.name or null == dependency) null allServices;
      in
      lib.optional (dependedService == null) "schema:${name}:unknown-service-dependency:${dependency}"
      ++ lib.optional (
        dependedService != null && dependedService.disposition or null != "retain"
      ) "schema:${name}:dependency-not-retained:${dependency}"
    ) serviceDependencies
  ) services;
  readinessErrors =
    lib.concatMap (
      target:
      lib.optional (isBlocker (
        target.measuredFreeBytes or { }
      )) "readiness:${target.name}:free-bytes-blocked"
      ++ map (field: "readiness:${target.name}:${field}-blocked") (
        lib.filter
          (
            field:
            target.hardwareRequirements.${field} or null == "required"
            && isBlocker (target.hardware.${field} or { })
          )
          [
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
      ++ lib.optional (isBlocker (
        service.database.datasetEvidence or { }
      )) "readiness:${service.name}:database-dataset-evidence-blocked"
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
  schemaErrors =
    serviceSchemaErrors
    ++ datasetSchemaErrors
    ++ targetSchemaErrors
    ++ referenceErrors
    ++ dependencyErrors;
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
