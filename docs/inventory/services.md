{
  "schemaVersion": 2,
  "observedAt": "2026-10-02",
  "targets": [
    {
      "name": "observability-pi",
      "address": "10.15.4.6",
      "architecture": "aarch64-linux",
      "measuredFreeBytes": {
        "status": "blocked",
        "reason": "host is not online; current filesystem free bytes are unavailable",
        "collectionCommand": "findmnt -bno SOURCE,TARGET,FSTYPE,AVAIL / /var/lib/telemetry 2>/dev/null || df -B1 --output=source,target,avail / /var/lib/telemetry"
      },
      "hardware": {
        "installDisk": {
          "status": "blocked",
          "reason": "stable telemetry SSD identity unavailable",
          "collectionCommand": "lsblk --json -b -o NAME,PATH,MODEL,SERIAL,WWN,SIZE,TYPE,MOUNTPOINTS"
        },
        "nic": {
          "status": "blocked",
          "reason": "stable interface identity unavailable",
          "collectionCommand": "for i in /sys/class/net/*; do printf '%s ' \"$(basename \"$i\")\"; cat \"$i/address\"; done; ip -br link; ip route"
        },
        "gpu": {
          "status": "not-applicable",
          "reason": "approved target role has no GPU requirement"
        }
      },
      "hardwareRequirements": {
        "installDisk": "required",
        "nic": "required",
        "gpu": "optional"
      }
    },
    {
      "name": "framework-01",
      "address": "10.15.4.5",
      "architecture": "x86_64-linux",
      "measuredFreeBytes": {
        "status": "blocked",
        "reason": "Kubernetes allocatable ephemeral storage is not current filesystem free space",
        "collectionCommand": "findmnt -bno SOURCE,TARGET,FSTYPE,AVAIL / /var/lib 2>/dev/null || df -B1 --output=source,target,avail / /var/lib"
      },
      "hardware": {
        "installDisk": {
          "status": "blocked",
          "reason": "stable model/serial unavailable",
          "collectionCommand": "lsblk --json -b -o NAME,PATH,MODEL,SERIAL,WWN,SIZE,TYPE,MOUNTPOINTS"
        },
        "nic": {
          "status": "blocked",
          "reason": "bond member names are known but stable interface/MAC mapping is unavailable",
          "collectionCommand": "for i in /sys/class/net/*; do printf '%s ' \"$(basename \"$i\")\"; cat \"$i/address\"; done; ip -d link show bond0; ip route"
        },
        "gpu": {
          "status": "blocked",
          "reason": "GPU PCI identity unavailable",
          "collectionCommand": "lspci -Dnn | grep -Ei 'vga|3d|display'"
        }
      },
      "hardwareRequirements": {
        "installDisk": "required",
        "nic": "required",
        "gpu": "required"
      }
    },
    {
      "name": "framework-02",
      "address": "10.15.4.7",
      "architecture": "x86_64-linux",
      "measuredFreeBytes": {
        "status": "blocked",
        "reason": "Kubernetes allocatable ephemeral storage is not current filesystem free space",
        "collectionCommand": "findmnt -bno SOURCE,TARGET,FSTYPE,AVAIL / /var/lib 2>/dev/null || df -B1 --output=source,target,avail / /var/lib"
      },
      "hardware": {
        "installDisk": {
          "status": "blocked",
          "reason": "stable model/serial unavailable",
          "collectionCommand": "lsblk --json -b -o NAME,PATH,MODEL,SERIAL,WWN,SIZE,TYPE,MOUNTPOINTS"
        },
        "nic": {
          "status": "blocked",
          "reason": "bond member names are known but stable interface/MAC mapping is unavailable",
          "collectionCommand": "for i in /sys/class/net/*; do printf '%s ' \"$(basename \"$i\")\"; cat \"$i/address\"; done; ip -d link show bond0; ip route"
        },
        "gpu": {
          "status": "blocked",
          "reason": "GPU PCI identity unavailable",
          "collectionCommand": "lspci -Dnn | grep -Ei 'vga|3d|display'"
        }
      },
      "hardwareRequirements": {
        "installDisk": "required",
        "nic": "required",
        "gpu": "required"
      }
    },
    {
      "name": "framework-03",
      "address": "10.15.4.9",
      "architecture": "x86_64-linux",
      "measuredFreeBytes": {
        "status": "blocked",
        "reason": "Kubernetes allocatable ephemeral storage is not current filesystem free space",
        "collectionCommand": "findmnt -bno SOURCE,TARGET,FSTYPE,AVAIL / /var/lib 2>/dev/null || df -B1 --output=source,target,avail / /var/lib"
      },
      "hardware": {
        "installDisk": {
          "status": "blocked",
          "reason": "stable model/serial unavailable",
          "collectionCommand": "lsblk --json -b -o NAME,PATH,MODEL,SERIAL,WWN,SIZE,TYPE,MOUNTPOINTS"
        },
        "nic": {
          "status": "blocked",
          "reason": "bond member names are known but stable interface/MAC mapping is unavailable",
          "collectionCommand": "for i in /sys/class/net/*; do printf '%s ' \"$(basename \"$i\")\"; cat \"$i/address\"; done; ip -d link show bond0; ip route"
        },
        "gpu": {
          "status": "blocked",
          "reason": "GPU PCI identity unavailable",
          "collectionCommand": "lspci -Dnn | grep -Ei 'vga|3d|display'"
        }
      },
      "hardwareRequirements": {
        "installDisk": "required",
        "nic": "required",
        "gpu": "required"
      }
    },
    {
      "name": "services-pi",
      "address": "10.15.4.4",
      "architecture": "aarch64-linux",
      "measuredFreeBytes": {
        "status": "blocked",
        "reason": "Kubernetes allocatable ephemeral storage is not current filesystem free space",
        "collectionCommand": "findmnt -bno SOURCE,TARGET,FSTYPE,AVAIL / /var/lib 2>/dev/null || df -B1 --output=source,target,avail / /var/lib"
      },
      "hardware": {
        "installDisk": {
          "status": "blocked",
          "reason": "stable model/serial unavailable",
          "collectionCommand": "lsblk --json -b -o NAME,PATH,MODEL,SERIAL,WWN,SIZE,TYPE,MOUNTPOINTS"
        },
        "nic": {
          "status": "blocked",
          "reason": "stable interface/MAC mapping unavailable",
          "collectionCommand": "for i in /sys/class/net/*; do printf '%s ' \"$(basename \"$i\")\"; cat \"$i/address\"; done; ip -br link; ip route"
        },
        "gpu": {
          "status": "not-applicable",
          "reason": "approved target role has no GPU requirement"
        }
      },
      "hardwareRequirements": {
        "installDisk": "required",
        "nic": "required",
        "gpu": "optional"
      }
    }
  ],
  "datasets": [
    {
      "id": "comma-feed-data",
      "placement": "local-copy",
      "targetHost": "framework-03",
      "sourcePaths": [
        "/commafeed/data"
      ],
      "targetPaths": [
        "/var/lib/comma-feed"
      ],
      "size": {
        "status": "observed",
        "bytes": 36015194,
        "evidence": {
          "type": "command-output",
          "reference": "du -sb in source workload"
        },
        "stableId": "comma-feed-data-bytes",
        "observedAt": "2026-10-02"
      },
      "ownerServices": [
        "comma-feed"
      ]
    },
    {
      "id": "deluge-config",
      "placement": "local-copy",
      "targetHost": "framework-03",
      "sourcePaths": [
        "/config"
      ],
      "targetPaths": [
        "/var/lib/deluge"
      ],
      "size": {
        "status": "blocked",
        "reason": "read-only container size query returned no usable result",
        "collectionCommand": "kubectl exec -n <namespace> <deluge-pod> -- du -sb -- /config"
      },
      "ownerServices": [
        "deluge"
      ]
    },
    {
      "id": "donetick-data",
      "placement": "local-copy",
      "targetHost": "framework-03",
      "sourcePaths": [
        "/donetick_data"
      ],
      "targetPaths": [
        "/var/lib/donetick"
      ],
      "size": {
        "status": "observed",
        "bytes": 618499,
        "evidence": {
          "type": "command-output",
          "reference": "du -sb in source workload"
        },
        "stableId": "donetick-data-bytes",
        "observedAt": "2026-10-02"
      },
      "ownerServices": [
        "donetick"
      ]
    },
    {
      "id": "forgejo-data",
      "placement": "local-copy",
      "targetHost": "framework-01",
      "sourcePaths": [
        "/var/lib/gitea",
        "/var/lib/postgresql/data"
      ],
      "targetPaths": [
        "/var/lib/forgejo",
        "/var/lib/postgresql"
      ],
      "size": {
        "status": "observed",
        "bytes": 95289922019,
        "evidence": {
          "type": "command-output",
          "reference": "du -sb for repository and PostgreSQL filesystems, summed once"
        },
        "stableId": "forgejo-data-bytes",
        "observedAt": "2026-10-02"
      },
      "ownerServices": [
        "forgejo"
      ]
    },
    {
      "id": "foundry-data",
      "placement": "local-copy",
      "targetHost": "framework-01",
      "sourcePaths": [
        "/home/foundry/app",
        "/home/foundry/data"
      ],
      "targetPaths": [
        "/var/lib/foundry/app",
        "/var/lib/foundry/data"
      ],
      "size": {
        "status": "observed",
        "bytes": 4528195073,
        "evidence": {
          "type": "command-output",
          "reference": "du -sb in source workload"
        },
        "stableId": "foundry-data-bytes",
        "observedAt": "2026-10-02"
      },
      "ownerServices": [
        "foundry"
      ]
    },
    {
      "id": "homarr-data",
      "placement": "local-copy",
      "targetHost": "framework-03",
      "sourcePaths": [
        "/appdata"
      ],
      "targetPaths": [
        "/var/lib/homarr"
      ],
      "size": {
        "status": "observed",
        "bytes": 11768954,
        "evidence": {
          "type": "command-output",
          "reference": "du -sb in source workload"
        },
        "stableId": "homarr-data-bytes",
        "observedAt": "2026-10-02"
      },
      "ownerServices": [
        "homarr"
      ]
    },
    {
      "id": "immich-data",
      "placement": "local-copy",
      "targetHost": "framework-01",
      "sourcePaths": [
        "/usr/src/app/upload",
        "/var/lib/postgresql/data"
      ],
      "targetPaths": [
        "/var/lib/immich/upload",
        "/var/lib/postgresql"
      ],
      "size": {
        "status": "observed",
        "bytes": 77778008026,
        "evidence": {
          "type": "command-output",
          "reference": "du -sb for library and PostgreSQL filesystems, summed once"
        },
        "stableId": "immich-data-bytes",
        "observedAt": "2026-10-02"
      },
      "ownerServices": [
        "immich"
      ]
    },
    {
      "id": "jellyfin-config",
      "placement": "local-copy",
      "targetHost": "framework-02",
      "sourcePaths": [
        "/config"
      ],
      "targetPaths": [
        "/var/lib/jellyfin"
      ],
      "size": {
        "status": "observed",
        "bytes": 364439771,
        "evidence": {
          "type": "command-output",
          "reference": "du -sb in source workload"
        },
        "stableId": "jellyfin-config-bytes",
        "observedAt": "2026-10-02"
      },
      "ownerServices": [
        "jellyfin"
      ]
    },
    {
      "id": "kavita-config",
      "placement": "local-copy",
      "targetHost": "framework-02",
      "sourcePaths": [
        "/config"
      ],
      "targetPaths": [
        "/var/lib/kavita"
      ],
      "size": {
        "status": "observed",
        "bytes": 53121923548,
        "evidence": {
          "type": "command-output",
          "reference": "du -sb in source workload"
        },
        "stableId": "kavita-config-bytes",
        "observedAt": "2026-10-02"
      },
      "ownerServices": [
        "kavita"
      ]
    },
    {
      "id": "mealie-data",
      "placement": "local-copy",
      "targetHost": "framework-01",
      "sourcePaths": [
        "/app/data",
        "/var/lib/postgresql/data"
      ],
      "targetPaths": [
        "/var/lib/mealie",
        "/var/lib/postgresql"
      ],
      "size": {
        "status": "observed",
        "bytes": 920113428,
        "evidence": {
          "type": "command-output",
          "reference": "du -sb for files and PostgreSQL filesystem, summed once"
        },
        "stableId": "mealie-data-bytes",
        "observedAt": "2026-10-02"
      },
      "ownerServices": [
        "mealie"
      ]
    },
    {
      "id": "pocket-id-data",
      "placement": "local-copy",
      "targetHost": "framework-03",
      "sourcePaths": [
        "/app/data"
      ],
      "targetPaths": [
        "/var/lib/pocket-id"
      ],
      "size": {
        "status": "observed",
        "bytes": 137147201,
        "evidence": {
          "type": "command-output",
          "reference": "du -sb in source workload"
        },
        "stableId": "pocket-id-data-bytes",
        "observedAt": "2026-10-02"
      },
      "ownerServices": [
        "pocket-id"
      ]
    },
    {
      "id": "prowlarr-config",
      "placement": "local-copy",
      "targetHost": "framework-03",
      "sourcePaths": [
        "/config"
      ],
      "targetPaths": [
        "/var/lib/prowlarr"
      ],
      "size": {
        "status": "observed",
        "bytes": 130475147,
        "evidence": {
          "type": "command-output",
          "reference": "du -sb in source workload"
        },
        "stableId": "prowlarr-config-bytes",
        "observedAt": "2026-10-02"
      },
      "ownerServices": [
        "prowlarr"
      ]
    },
    {
      "id": "publication-manager-data",
      "placement": "local-copy",
      "targetHost": "framework-03",
      "sourcePaths": [
        "/data",
        "/storage"
      ],
      "targetPaths": [
        "/var/lib/publication-manager/data",
        "/var/lib/publication-manager/storage"
      ],
      "size": {
        "status": "blocked",
        "reason": "read-only container size query returned no usable result",
        "collectionCommand": "kubectl exec -n <namespace> <publication-manager-pod> -- du -sb -- /data /storage"
      },
      "ownerServices": [
        "publication-manager"
      ]
    },
    {
      "id": "radarr-config",
      "placement": "local-copy",
      "targetHost": "framework-03",
      "sourcePaths": [
        "/config"
      ],
      "targetPaths": [
        "/var/lib/radarr"
      ],
      "size": {
        "status": "observed",
        "bytes": 152623104,
        "evidence": {
          "type": "command-output",
          "reference": "du -sb in source workload"
        },
        "stableId": "radarr-config-bytes",
        "observedAt": "2026-10-02"
      },
      "ownerServices": [
        "radarr"
      ]
    },
    {
      "id": "sabnzbd-config",
      "placement": "local-copy",
      "targetHost": "framework-03",
      "sourcePaths": [
        "/config"
      ],
      "targetPaths": [
        "/var/lib/sabnzbd"
      ],
      "size": {
        "status": "observed",
        "bytes": 36344747,
        "evidence": {
          "type": "command-output",
          "reference": "du -sb in source workload"
        },
        "stableId": "sabnzbd-config-bytes",
        "observedAt": "2026-10-02"
      },
      "ownerServices": [
        "sabnzbd"
      ]
    },
    {
      "id": "sonarr-config",
      "placement": "local-copy",
      "targetHost": "framework-03",
      "sourcePaths": [
        "/config"
      ],
      "targetPaths": [
        "/var/lib/sonarr"
      ],
      "size": {
        "status": "observed",
        "bytes": 1703590623,
        "evidence": {
          "type": "command-output",
          "reference": "du -sb in source workload"
        },
        "stableId": "sonarr-config-bytes",
        "observedAt": "2026-10-02"
      },
      "ownerServices": [
        "sonarr"
      ]
    },
    {
      "id": "tangled-knot-data",
      "placement": "local-copy",
      "targetHost": "framework-01",
      "sourcePaths": [
        "/data"
      ],
      "targetPaths": [
        "/var/lib/tangled-knot"
      ],
      "size": {
        "status": "observed",
        "bytes": 712311,
        "evidence": {
          "type": "command-output",
          "reference": "du -sb in source workload"
        },
        "stableId": "tangled-knot-data-bytes",
        "observedAt": "2026-10-02"
      },
      "ownerServices": [
        "tangled-knot"
      ]
    },
    {
      "id": "tranquil-pds-data",
      "placement": "local-copy",
      "targetHost": "framework-01",
      "sourcePaths": [
        "/var/lib/tranquil-pds/blobs",
        "/var/lib/postgresql/data"
      ],
      "targetPaths": [
        "/var/lib/tranquil-pds/blobs",
        "/var/lib/postgresql"
      ],
      "size": {
        "status": "observed",
        "bytes": 2570103626,
        "evidence": {
          "type": "command-output",
          "reference": "du -sb in source workload"
        },
        "stableId": "tranquil-pds-data-bytes",
        "observedAt": "2026-10-02"
      },
      "ownerServices": [
        "tranquil-pds"
      ]
    },
    {
      "id": "tuwunel-data",
      "placement": "local-copy",
      "targetHost": "framework-01",
      "sourcePaths": [
        "/var/lib/tuwunel"
      ],
      "targetPaths": [
        "/var/lib/tuwunel"
      ],
      "size": {
        "status": "blocked",
        "reason": "read-only container size query returned no usable result",
        "collectionCommand": "kubectl exec -n <namespace> <tuwunel-pod> -- du -sb -- /var/lib/tuwunel"
      },
      "ownerServices": [
        "tuwunel"
      ]
    },
    {
      "id": "vikunja-data",
      "placement": "local-copy",
      "targetHost": "framework-02",
      "sourcePaths": [
        "/app/vikunja/files",
        "/var/lib/postgresql/data"
      ],
      "targetPaths": [
        "/var/lib/vikunja",
        "/var/lib/postgresql"
      ],
      "size": {
        "status": "observed",
        "bytes": 841127261,
        "evidence": {
          "type": "command-output",
          "reference": "du -sb in source workload"
        },
        "stableId": "vikunja-data-bytes",
        "observedAt": "2026-10-02"
      },
      "ownerServices": [
        "vikunja"
      ]
    },
    {
      "id": "wallos-data",
      "placement": "local-copy",
      "targetHost": "services-pi",
      "sourcePaths": [
        "/var/www/html/db",
        "/var/www/html/images/uploads/logos"
      ],
      "targetPaths": [
        "/var/lib/wallos/db",
        "/var/lib/wallos/logos"
      ],
      "size": {
        "status": "observed",
        "bytes": 1819838,
        "evidence": {
          "type": "command-output",
          "reference": "du -sb in source workload"
        },
        "stableId": "wallos-data-bytes",
        "observedAt": "2026-10-02"
      },
      "ownerServices": [
        "wallos"
      ]
    },
    {
      "id": "whisparr-config",
      "placement": "local-copy",
      "targetHost": "framework-03",
      "sourcePaths": [
        "/config"
      ],
      "targetPaths": [
        "/var/lib/whisparr"
      ],
      "size": {
        "status": "observed",
        "bytes": 5101768,
        "evidence": {
          "type": "command-output",
          "reference": "du -sb in source workload"
        },
        "stableId": "whisparr-config-bytes",
        "observedAt": "2026-10-02"
      },
      "ownerServices": [
        "whisparr"
      ]
    },
    {
      "id": "shared-video-library",
      "placement": "shared-retained",
      "sourcePaths": [
        "NAS video export"
      ],
      "size": {
        "status": "observed",
        "bytes": 31269016911730,
        "evidence": {
          "type": "command-output",
          "reference": "du -sb once for the shared mount used by five services"
        },
        "stableId": "shared-video-library-bytes",
        "observedAt": "2026-10-02"
      },
      "ownerServices": [
        "deluge",
        "jellyfin",
        "radarr",
        "sabnzbd",
        "sonarr",
        "whisparr"
      ]
    },
    {
      "id": "kavita-library",
      "placement": "shared-retained",
      "sourcePaths": [
        "NAS books export"
      ],
      "size": {
        "status": "observed",
        "bytes": 1722285974181,
        "evidence": {
          "type": "command-output",
          "reference": "du -sb on NAS-backed mount"
        },
        "stableId": "kavita-library-bytes",
        "observedAt": "2026-10-02"
      },
      "ownerServices": [
        "kavita"
      ]
    }
  ],
  "services": [
    {
      "name": "comma-feed",
      "disposition": "retain",
      "targetHost": "framework-03",
      "image": "docker.io/athou/commafeed@sha256:0e52f2a86c2ae36cb446401292c87ba6ca658fafda64c99bc7e8713ed433d8a3",
      "architectures": [
        "linux/amd64"
      ],
      "database": {
        "kind": "embedded",
        "engine": "H2",
        "versionFact": {
          "status": "blocked",
          "reason": "runtime database version not collected",
          "collectionCommand": "kubectl exec -n <namespace> <comma-feed-pod> -- java -cp /commafeed/* org.h2.tools.Shell -url 'jdbc:h2:/commafeed/data/db' -sql 'select h2version()'"
        },
        "databaseId": "comma-feed-database",
        "datasetId": "comma-feed-data",
        "sourcePaths": [ "/commafeed/data" ],
        "targetPaths": [ "/var/lib/comma-feed" ],
        "datasetEvidence": { "status": "blocked", "reason": "database component coverage is not independently evidenced", "collectionCommand": "du -sb /commafeed/data; record database identity, owner, source path, target path, and output digest" }
      },
      "datasetIds": [
        "comma-feed-data"
      ],
      "endpoints": [
        "https://feed.tailbc181.ts.net/"
      ],
      "backupEvidence": {
        "status": "blocked",
        "reason": "fresh backup artifact not yet captured",
        "collectionCommand": "restic snapshots --json --path /commafeed/data"
      },
      "restoreEvidence": {
        "status": "blocked",
        "reason": "isolated restore not yet performed",
        "collectionCommand": "restore into an isolated directory, start with networking disabled, and record feed-count verification"
      }
    },
    {
      "name": "deluge",
      "disposition": "retain",
      "targetHost": "framework-03",
      "image": "docker.io/linuxserver/deluge@sha256:9505c64720afa9e5f0ac1576e660dd6d1e9d4a6733b791f4821e8f496f19f41f",
      "architectures": [
        "linux/amd64"
      ],
      "database": {
        "kind": "none"
      },
      "datasetIds": [
        "deluge-config",
        "shared-video-library"
      ],
      "endpoints": [
        "https://deluge.tailbc181.ts.net/",
        "platform://deluge-direct"
      ],
      "backupEvidence": {
        "status": "blocked",
        "reason": "fresh backup artifact not yet captured",
        "collectionCommand": "restic snapshots --json --path /config"
      },
      "restoreEvidence": {
        "status": "blocked",
        "reason": "isolated restore not yet performed",
        "collectionCommand": "restore config into an isolated Deluge instance and record queue verification"
      }
    },
    {
      "name": "donetick",
      "disposition": "retain",
      "targetHost": "framework-03",
      "image": "docker.io/donetick/donetick@sha256:a1cc21dd5a37acb5009009f13e5d2529153049361afb0a1cd94bde312382d36a",
      "architectures": [
        "linux/amd64"
      ],
      "database": {
        "kind": "embedded",
        "engine": "SQLite",
        "versionFact": {
          "status": "blocked",
          "reason": "SQLite runtime version not collected",
          "collectionCommand": "kubectl exec -n <namespace> <donetick-pod> -- sqlite3 --version"
        },
        "databaseId": "donetick-database",
        "datasetId": "donetick-data",
        "sourcePaths": [ "/donetick_data" ],
        "targetPaths": [ "/var/lib/donetick" ],
        "datasetEvidence": { "status": "blocked", "reason": "database component coverage is not independently evidenced", "collectionCommand": "du -sb /donetick_data; record database identity, owner, source path, target path, and output digest" }
      },
      "datasetIds": [
        "donetick-data"
      ],
      "endpoints": [
        "https://donetick.tailbc181.ts.net/",
        "https://donetick.tailbc181.ts.net/auth/oauth2",
        "https://id.minastas.xyz/authorize",
        "https://id.minastas.xyz/api/oidc/token",
        "https://id.minastas.xyz/api/oidc/userinfo",
        "service://mailrise.mailrise.svc.cluster.local"
      ],
      "backupEvidence": {
        "status": "blocked",
        "reason": "fresh consistent backup not captured",
        "collectionCommand": "create a SQLite online backup, then record sha256sum and byte count"
      },
      "restoreEvidence": {
        "status": "blocked",
        "reason": "isolated restore not performed",
        "collectionCommand": "restore into an isolated instance and record task-count verification"
      }
    },
    {
      "name": "forgejo",
      "disposition": "retain",
      "targetHost": "framework-01",
      "image": "codeberg.org/forgejo/forgejo@sha256:5effb7305584aca479b29fde6f9631a6dbe86ae798ae02eeea33a3666f0c0bf8",
      "architectures": [
        "linux/amd64"
      ],
      "database": {
        "kind": "external",
        "engine": "PostgreSQL",
        "databaseId": "forgejo-database",
        "datasetId": "forgejo-data",
        "sourcePaths": [ "/var/lib/postgresql/data" ],
        "targetPaths": [ "/var/lib/postgresql" ],
        "datasetEvidence": { "status": "blocked", "reason": "database component coverage is not independently evidenced", "collectionCommand": "du -sb /var/lib/postgresql/data; record database identity, owner, source path, target path, and output digest" },
        "versionFact": {
          "status": "observed",
          "value": "18.1",
          "stableId": "forgejo-database-version",
          "observedAt": "2026-10-02",
          "evidence": {
            "type": "api",
            "reference": "CNPG image and cluster status"
          }
        }
      },
      "datasetIds": [
        "forgejo-data"
      ],
      "endpoints": [
        "https://git.tailbc181.ts.net/",
        "ssh://git-ssh"
      ],
      "backupEvidence": {
        "status": "blocked",
        "reason": "fresh logical backup ID unavailable",
        "collectionCommand": "kubectl exec -n <namespace> <postgres-pod> -- pg_dump --format=custom --file=/tmp/forgejo.dump <database>; kubectl exec -n <namespace> <postgres-pod> -- sha256sum /tmp/forgejo.dump"
      },
      "restoreEvidence": {
        "status": "blocked",
        "reason": "isolated logical restore not performed",
        "collectionCommand": "pg_restore into an isolated database and record repository clone and row-count checks"
      }
    },
    {
      "name": "foundry",
      "disposition": "retain",
      "targetHost": "framework-01",
      "image": "ghcr.io/bzvestey/foundry@sha256:5d59c2eabaa4a495171cfa5ca73148aaf76056bd2052e84d978935f80ea32709",
      "architectures": [
        "linux/amd64"
      ],
      "database": {
        "kind": "none"
      },
      "datasetIds": [
        "foundry-data"
      ],
      "endpoints": [
        "https://foundry.minastas.xyz/"
      ],
      "backupEvidence": {
        "status": "blocked",
        "reason": "fresh backup artifact not captured",
        "collectionCommand": "restic snapshots --json --path /home/foundry/data"
      },
      "restoreEvidence": {
        "status": "blocked",
        "reason": "isolated restore not performed",
        "collectionCommand": "restore into an isolated instance and record world/scene load verification"
      }
    },
    {
      "name": "homarr",
      "disposition": "retain",
      "targetHost": "framework-03",
      "image": "ghcr.io/homarr-labs/homarr@sha256:f0fb462299af9749a72f11040fd3f604d1c4976b3d9a137ae5021b7f44d980f5",
      "architectures": [
        "linux/amd64"
      ],
      "database": {
        "kind": "embedded",
        "engine": "SQLite",
        "versionFact": {
          "status": "blocked",
          "reason": "SQLite runtime version not collected",
          "collectionCommand": "kubectl exec -n <namespace> <homarr-pod> -- sqlite3 --version"
        },
        "databaseId": "homarr-database",
        "datasetId": "homarr-data",
        "sourcePaths": [ "/appdata" ],
        "targetPaths": [ "/var/lib/homarr" ],
        "datasetEvidence": { "status": "blocked", "reason": "database component coverage is not independently evidenced", "collectionCommand": "du -sb /appdata; record database identity, owner, source path, target path, and output digest" }
      },
      "datasetIds": [
        "homarr-data"
      ],
      "endpoints": [
        "https://homarr.tailbc181.ts.net/"
      ],
      "backupEvidence": {
        "status": "blocked",
        "reason": "fresh consistent backup not captured",
        "collectionCommand": "create a SQLite online backup, then record sha256sum and byte count"
      },
      "restoreEvidence": {
        "status": "blocked",
        "reason": "isolated restore not performed",
        "collectionCommand": "restore into an isolated instance and record dashboard load verification"
      }
    },
    {
      "name": "immich",
      "disposition": "retain",
      "targetHost": "framework-01",
      "image": "ghcr.io/immich-app/immich-server@sha256:79cc1623323d5894922686d8743b4780181428f98eecbfb58ce12c41ef02d1ea",
      "architectures": [
        "linux/amd64"
      ],
      "database": {
        "kind": "external",
        "engine": "PostgreSQL/vectorchord",
        "databaseId": "immich-database",
        "datasetId": "immich-data",
        "sourcePaths": [ "/var/lib/postgresql/data" ],
        "targetPaths": [ "/var/lib/postgresql" ],
        "datasetEvidence": { "status": "blocked", "reason": "database component coverage is not independently evidenced", "collectionCommand": "du -sb /var/lib/postgresql/data; record database identity, owner, source path, target path, and output digest" },
        "versionFact": {
          "status": "blocked",
          "reason": "CNPG image observation only established major version 16, not an observed numeric dotted database version",
          "collectionCommand": "kubectl exec -n <namespace> <postgres-pod> -- psql -Atqc 'show server_version'"
        }
      },
      "datasetIds": [
        "immich-data"
      ],
      "endpoints": [
        "https://immich.tailbc181.ts.net/"
      ],
      "backupEvidence": {
        "status": "blocked",
        "reason": "fresh logical backup ID unavailable",
        "collectionCommand": "kubectl exec -n <namespace> <postgres-pod> -- pg_dump --format=custom --file=/tmp/immich.dump <database>; kubectl exec -n <namespace> <postgres-pod> -- sha256sum /tmp/immich.dump"
      },
      "restoreEvidence": {
        "status": "blocked",
        "reason": "isolated restore not performed",
        "collectionCommand": "restore into an isolated database and record asset-count and sampled-render checks"
      }
    },
    {
      "name": "jellyfin",
      "disposition": "retain",
      "targetHost": "framework-02",
      "image": "ghcr.io/linuxserver/jellyfin@sha256:b0b6d034aa52ed6e1a76daaa3d7ed29039d2b802a50fa8ffd1d9fc8d3fd836c7",
      "architectures": [
        "linux/amd64"
      ],
      "database": {
        "kind": "embedded",
        "engine": "SQLite",
        "versionFact": {
          "status": "blocked",
          "reason": "SQLite runtime version not collected",
          "collectionCommand": "kubectl exec -n <namespace> <jellyfin-pod> -- sqlite3 --version"
        },
        "databaseId": "jellyfin-database",
        "datasetId": "jellyfin-config",
        "sourcePaths": [ "/config" ],
        "targetPaths": [ "/var/lib/jellyfin" ],
        "datasetEvidence": { "status": "blocked", "reason": "database component coverage is not independently evidenced", "collectionCommand": "du -sb /config; record database identity, owner, source path, target path, and output digest" }
      },
      "datasetIds": [
        "jellyfin-config",
        "shared-video-library"
      ],
      "endpoints": [
        "https://jellyfin.tailbc181.ts.net/"
      ],
      "backupEvidence": {
        "status": "blocked",
        "reason": "fresh consistent config backup not captured",
        "collectionCommand": "create application-consistent config backup and record artifact checksum"
      },
      "restoreEvidence": {
        "status": "blocked",
        "reason": "isolated restore not performed",
        "collectionCommand": "restore config into an isolated instance and record sampled playback check"
      }
    },
    {
      "name": "kavita",
      "disposition": "retain",
      "targetHost": "framework-02",
      "image": "docker.io/linuxserver/kavita@sha256:2842f1c0882b9d0ce3103420eea0a90b27e4537ff29f87b1471cdd752e936837",
      "architectures": [
        "linux/amd64"
      ],
      "database": {
        "kind": "embedded",
        "engine": "SQLite",
        "versionFact": {
          "status": "blocked",
          "reason": "SQLite runtime version not collected",
          "collectionCommand": "kubectl exec -n <namespace> <kavita-pod> -- sqlite3 --version"
        },
        "databaseId": "kavita-database",
        "datasetId": "kavita-config",
        "sourcePaths": [ "/config" ],
        "targetPaths": [ "/var/lib/kavita" ],
        "datasetEvidence": { "status": "blocked", "reason": "database component coverage is not independently evidenced", "collectionCommand": "du -sb /config; record database identity, owner, source path, target path, and output digest" }
      },
      "datasetIds": [
        "kavita-config",
        "kavita-library"
      ],
      "endpoints": [
        "https://kavita.tailbc181.ts.net/"
      ],
      "backupEvidence": {
        "status": "blocked",
        "reason": "fresh consistent config backup not captured",
        "collectionCommand": "create application-consistent config backup and record artifact checksum"
      },
      "restoreEvidence": {
        "status": "blocked",
        "reason": "isolated restore not performed",
        "collectionCommand": "restore into an isolated instance and record library-count and sampled-book checks"
      }
    },
    {
      "name": "mailrise",
      "disposition": "retain",
      "targetHost": "services-pi",
      "image": "docker.io/yoryan/mailrise@sha256:0b8b1ce3447c83b625c9e8896cd9c3db0205590f92ce4d4adaae69729830f52b",
      "architectures": [
        "linux/amd64",
        "linux/arm64"
      ],
      "database": {
        "kind": "none"
      },
      "datasetIds": [],
      "endpoints": [
        "smtp://mailrise"
      ],
      "backupEvidence": {
        "status": "observed",
        "id": "declarative-config",
        "observedAt": "2026-10-02",
        "evidence": {
          "type": "declaration",
          "reference": "configuration is declarative; secrets remain in secret manager"
        },
        "stableId": "declarative-config"
      },
      "restoreEvidence": {
        "status": "blocked",
        "reason": "target rebuild test not performed",
        "collectionCommand": "deploy to an isolated namespace and record synthetic SMTP delivery"
      }
    },
    {
      "name": "mealie",
      "disposition": "retain",
      "targetHost": "framework-01",
      "image": "ghcr.io/mealie-recipes/mealie@sha256:8b02290f4d1806f02acac6f25f6d48a3c965612fda1f8e914d5af533276f8688",
      "architectures": [
        "linux/amd64"
      ],
      "database": {
        "kind": "external",
        "engine": "PostgreSQL",
        "databaseId": "mealie-database",
        "datasetId": "mealie-data",
        "sourcePaths": [ "/var/lib/postgresql/data" ],
        "targetPaths": [ "/var/lib/postgresql" ],
        "datasetEvidence": { "status": "blocked", "reason": "database component coverage is not independently evidenced", "collectionCommand": "du -sb /var/lib/postgresql/data; record database identity, owner, source path, target path, and output digest" },
        "versionFact": {
          "status": "observed",
          "value": "17.5",
          "stableId": "mealie-database-version",
          "observedAt": "2026-10-02",
          "evidence": {
            "type": "api",
            "reference": "CNPG image and cluster status"
          }
        }
      },
      "datasetIds": [
        "mealie-data"
      ],
      "endpoints": [
        "https://mealie.tailbc181.ts.net/"
      ],
      "backupEvidence": {
        "status": "blocked",
        "reason": "fresh logical backup ID unavailable",
        "collectionCommand": "kubectl exec -n <namespace> <postgres-pod> -- pg_dump --format=custom --file=/tmp/mealie.dump <database>; kubectl exec -n <namespace> <postgres-pod> -- sha256sum /tmp/mealie.dump"
      },
      "restoreEvidence": {
        "status": "blocked",
        "reason": "isolated restore not performed",
        "collectionCommand": "restore into an isolated database and record recipe-count check"
      }
    },
    {
      "name": "pocket-id",
      "disposition": "retain",
      "targetHost": "framework-03",
      "image": "ghcr.io/pocket-id/pocket-id@sha256:9366436f3fd21619ed7e5709fa0acac88130f73414ec8ee1caf768fc487111ea",
      "architectures": [
        "linux/amd64"
      ],
      "database": {
        "kind": "embedded",
        "engine": "SQLite",
        "versionFact": {
          "status": "blocked",
          "reason": "SQLite runtime version not collected",
          "collectionCommand": "kubectl exec -n <namespace> <pocket-id-pod> -- sqlite3 --version"
        },
        "databaseId": "pocket-id-database",
        "datasetId": "pocket-id-data",
        "sourcePaths": [ "/app/data" ],
        "targetPaths": [ "/var/lib/pocket-id" ],
        "datasetEvidence": { "status": "blocked", "reason": "database component coverage is not independently evidenced", "collectionCommand": "du -sb /app/data; record database identity, owner, source path, target path, and output digest" }
      },
      "datasetIds": [
        "pocket-id-data"
      ],
      "endpoints": [
        "https://id.minastas.xyz/",
        "https://id.minastas.xyz/authorize",
        "https://id.minastas.xyz/api/oidc/token",
        "https://id.minastas.xyz/api/oidc/userinfo"
      ],
      "backupEvidence": {
        "status": "blocked",
        "reason": "fresh consistent backup not captured",
        "collectionCommand": "create a SQLite online backup, then record sha256sum and byte count"
      },
      "restoreEvidence": {
        "status": "blocked",
        "reason": "isolated restore not performed",
        "collectionCommand": "restore into an isolated instance and record test OIDC login"
      }
    },
    {
      "name": "prowlarr",
      "disposition": "retain",
      "targetHost": "framework-03",
      "image": "ghcr.io/linuxserver/prowlarr@sha256:f2b26429893d4c4cb71941b7ee50b1bdecd9d5f9f9e02d5410615e9f4f7c8d95",
      "architectures": [
        "linux/amd64"
      ],
      "database": {
        "kind": "embedded",
        "engine": "SQLite",
        "versionFact": {
          "status": "blocked",
          "reason": "SQLite runtime version not collected",
          "collectionCommand": "kubectl exec -n <namespace> <prowlarr-pod> -- sqlite3 --version"
        },
        "databaseId": "prowlarr-database",
        "datasetId": "prowlarr-config",
        "sourcePaths": [ "/config" ],
        "targetPaths": [ "/var/lib/prowlarr" ],
        "datasetEvidence": { "status": "blocked", "reason": "database component coverage is not independently evidenced", "collectionCommand": "du -sb /config; record database identity, owner, source path, target path, and output digest" }
      },
      "datasetIds": [
        "prowlarr-config"
      ],
      "endpoints": [
        "https://prowlarr.tailbc181.ts.net/"
      ],
      "backupEvidence": {
        "status": "blocked",
        "reason": "fresh application backup not captured",
        "collectionCommand": "create application backup and record artifact checksum"
      },
      "restoreEvidence": {
        "status": "blocked",
        "reason": "isolated restore not performed",
        "collectionCommand": "restore into an isolated instance and record indexer/downstream sync tests"
      }
    },
    {
      "name": "publication-manager",
      "disposition": "retain",
      "targetHost": "framework-03",
      "image": "private-registry/lcp-decryption-plugin@sha256:542e39a5fffc457dd8d3475cb1529b7d5461d720b142ce00133f6f639e32974c",
      "architectures": [
        "linux/amd64"
      ],
      "database": {
        "kind": "none"
      },
      "datasetIds": [
        "publication-manager-data"
      ],
      "endpoints": [
        "https://publications.tailbc181.ts.net/",
        "https://publications.tailbc181.ts.net/auth/callback"
      ],
      "backupEvidence": {
        "status": "blocked",
        "reason": "fresh backup artifact not captured",
        "collectionCommand": "restic snapshots --json --path /data --path /storage"
      },
      "restoreEvidence": {
        "status": "blocked",
        "reason": "isolated restore not performed",
        "collectionCommand": "restore into an isolated instance and record sampled publication decrypt/retrieve check"
      }
    },
    {
      "name": "radarr",
      "disposition": "retain",
      "targetHost": "framework-03",
      "image": "ghcr.io/linuxserver/radarr@sha256:adb6c09d6b729ea5e642c99cea35af72702ef476bf4763f153299ac5db9f0b4f",
      "architectures": [
        "linux/amd64"
      ],
      "database": {
        "kind": "embedded",
        "engine": "SQLite",
        "versionFact": {
          "status": "blocked",
          "reason": "SQLite runtime version not collected",
          "collectionCommand": "kubectl exec -n <namespace> <radarr-pod> -- sqlite3 --version"
        },
        "databaseId": "radarr-database",
        "datasetId": "radarr-config",
        "sourcePaths": [ "/config" ],
        "targetPaths": [ "/var/lib/radarr" ],
        "datasetEvidence": { "status": "blocked", "reason": "database component coverage is not independently evidenced", "collectionCommand": "du -sb /config; record database identity, owner, source path, target path, and output digest" }
      },
      "datasetIds": [
        "radarr-config",
        "shared-video-library"
      ],
      "endpoints": [
        "https://radarr.tailbc181.ts.net/"
      ],
      "backupEvidence": {
        "status": "blocked",
        "reason": "fresh application backup not captured",
        "collectionCommand": "create application backup and record artifact checksum"
      },
      "restoreEvidence": {
        "status": "blocked",
        "reason": "isolated restore not performed",
        "collectionCommand": "restore into an isolated instance and record movie-count/download-client checks"
      }
    },
    {
      "name": "sabnzbd",
      "disposition": "retain",
      "targetHost": "framework-03",
      "image": "ghcr.io/linuxserver/sabnzbd@sha256:4f7ee6c53834bc336365bd0a7c35f4fc870156a72d33a334753010258aa077a4",
      "architectures": [
        "linux/amd64"
      ],
      "database": {
        "kind": "none"
      },
      "datasetIds": [
        "sabnzbd-config",
        "shared-video-library"
      ],
      "endpoints": [
        "https://sabnzbd.tailbc181.ts.net/"
      ],
      "backupEvidence": {
        "status": "blocked",
        "reason": "fresh config backup not captured",
        "collectionCommand": "restic snapshots --json --path /config"
      },
      "restoreEvidence": {
        "status": "blocked",
        "reason": "isolated restore not performed",
        "collectionCommand": "restore into an isolated instance and record server/download-path checks"
      }
    },
    {
      "name": "sonarr",
      "disposition": "retain",
      "targetHost": "framework-03",
      "image": "ghcr.io/linuxserver/sonarr@sha256:f247545d23ba8b233d6604575347e48a623fe6ad75dda02348bf81917f3b5c06",
      "architectures": [
        "linux/amd64"
      ],
      "database": {
        "kind": "embedded",
        "engine": "SQLite",
        "versionFact": {
          "status": "blocked",
          "reason": "SQLite runtime version not collected",
          "collectionCommand": "kubectl exec -n <namespace> <sonarr-pod> -- sqlite3 --version"
        },
        "databaseId": "sonarr-database",
        "datasetId": "sonarr-config",
        "sourcePaths": [ "/config" ],
        "targetPaths": [ "/var/lib/sonarr" ],
        "datasetEvidence": { "status": "blocked", "reason": "database component coverage is not independently evidenced", "collectionCommand": "du -sb /config; record database identity, owner, source path, target path, and output digest" }
      },
      "datasetIds": [
        "sonarr-config",
        "shared-video-library"
      ],
      "endpoints": [
        "https://sonarr.tailbc181.ts.net/"
      ],
      "backupEvidence": {
        "status": "blocked",
        "reason": "fresh application backup not captured",
        "collectionCommand": "create application backup and record artifact checksum"
      },
      "restoreEvidence": {
        "status": "blocked",
        "reason": "isolated restore not performed",
        "collectionCommand": "restore into an isolated instance and record series-count/download-client checks"
      }
    },
    {
      "name": "tangled-knot",
      "disposition": "retain",
      "targetHost": "framework-01",
      "image": "atcr.io/tangled.org/knot@sha256:6a9246da7b49a8bbe6f84122fd6fc09aac3ae93589b193956873daf33f88faa6",
      "architectures": [
        "linux/amd64"
      ],
      "database": {
        "kind": "none"
      },
      "datasetIds": [
        "tangled-knot-data"
      ],
      "endpoints": [
        "https://knot.minastas.xyz/",
        "ssh://knot-ssh"
      ],
      "backupEvidence": {
        "status": "blocked",
        "reason": "fresh backup artifact not captured",
        "collectionCommand": "restic snapshots --json --path /data"
      },
      "restoreEvidence": {
        "status": "blocked",
        "reason": "isolated restore not performed",
        "collectionCommand": "restore into an isolated instance and record sampled repository clone"
      }
    },
    {
      "name": "tranquil-pds",
      "disposition": "retain",
      "targetHost": "framework-01",
      "image": "atcr.io/tranquil.farm/tranquil-pds@sha256:bfbcb3b574bd836e9719012c98b172a8ebea2046acb6a87cb989eeb4f4dba9a4",
      "architectures": [
        "linux/amd64"
      ],
      "database": {
        "kind": "external",
        "engine": "PostgreSQL",
        "databaseId": "tranquil-pds-database",
        "datasetId": "tranquil-pds-data",
        "sourcePaths": [ "/var/lib/postgresql/data" ],
        "targetPaths": [ "/var/lib/postgresql" ],
        "datasetEvidence": { "status": "blocked", "reason": "database component coverage is not independently evidenced", "collectionCommand": "du -sb /var/lib/postgresql/data; record database identity, owner, source path, target path, and output digest" },
        "versionFact": {
          "status": "observed",
          "value": "18.1",
          "stableId": "tranquil-pds-database-version",
          "observedAt": "2026-10-02",
          "evidence": {
            "type": "api",
            "reference": "CNPG image and cluster status"
          }
        }
      },
      "datasetIds": [
        "tranquil-pds-data"
      ],
      "endpoints": [
        "https://minastas.social/",
        "https://pds.minastas.social/",
        "https://*.minastas.social/"
      ],
      "backupEvidence": {
        "status": "blocked",
        "reason": "CNPG object backup has no successful recovery point and no fresh logical backup ID exists",
        "collectionCommand": "kubectl exec -n <namespace> <tranquil-postgres-pod> -- pg_dump --format=custom --file=/tmp/tranquil.dump <database>; kubectl exec -n <namespace> <tranquil-postgres-pod> -- sha256sum /tmp/tranquil.dump"
      },
      "restoreEvidence": {
        "status": "blocked",
        "reason": "no isolated restore evidence exists",
        "collectionCommand": "pg_restore into an isolated PostgreSQL instance; start an isolated PDS with outbound networking blocked; record sampled DID/blob verification"
      }
    },
    {
      "name": "tuwunel",
      "disposition": "retain",
      "targetHost": "framework-01",
      "image": "docker.io/jevolk/tuwunel@sha256:678b7f5350e06a41614444497c587da9dddf66767e4068a27480402f3c1367d0",
      "architectures": [
        "linux/amd64"
      ],
      "database": {
        "kind": "embedded",
        "engine": "RocksDB",
        "versionFact": {
          "status": "blocked",
          "reason": "RocksDB format/runtime version not collected",
          "collectionCommand": "kubectl exec -n <namespace> <tuwunel-pod> -- /usr/local/bin/tuwunel --version"
        },
        "databaseId": "tuwunel-database",
        "datasetId": "tuwunel-data",
        "sourcePaths": [ "/var/lib/tuwunel" ],
        "targetPaths": [ "/var/lib/tuwunel" ],
        "datasetEvidence": { "status": "blocked", "reason": "database component coverage and size are unobserved", "collectionCommand": "du -sb /var/lib/tuwunel; record database identity, owner, source path, target path, and output digest" }
      },
      "datasetIds": [
        "tuwunel-data"
      ],
      "endpoints": [
        "https://matrix.minastas.social/",
        "https://matrix.minastas.social/webhook",
        "https://matrix.minastas.social/_matrix/client/unstable/login/sso/callback/9c05911b-c58f-449f-9792-40e87bb25b12",
        "https://id.minastas.xyz/"
      ],
      "backupEvidence": {
        "status": "blocked",
        "reason": "fresh quiesced backup not captured",
        "collectionCommand": "quiesce the service, run restic backup /var/lib/tuwunel, and record snapshot ID"
      },
      "restoreEvidence": {
        "status": "blocked",
        "reason": "isolated restore not performed",
        "collectionCommand": "restore into an isolated instance and record federation and sampled-room checks"
      }
    },
    {
      "name": "vikunja",
      "disposition": "retain",
      "targetHost": "framework-02",
      "image": "docker.io/vikunja/vikunja@sha256:417ada6f94e81f0267aa2f007d0a811fc82d38dd2aa58351e3ea520ca01c2ea5",
      "architectures": [
        "linux/amd64"
      ],
      "database": {
        "kind": "external",
        "engine": "PostgreSQL",
        "databaseId": "vikunja-database",
        "datasetId": "vikunja-data",
        "sourcePaths": [ "/var/lib/postgresql/data" ],
        "targetPaths": [ "/var/lib/postgresql" ],
        "datasetEvidence": { "status": "blocked", "reason": "database component coverage is not independently evidenced", "collectionCommand": "du -sb /var/lib/postgresql/data; record database identity, owner, source path, target path, and output digest" },
        "versionFact": {
          "status": "observed",
          "value": "17.5",
          "stableId": "vikunja-database-version",
          "observedAt": "2026-10-02",
          "evidence": {
            "type": "api",
            "reference": "CNPG image and cluster status"
          }
        }
      },
      "datasetIds": [
        "vikunja-data"
      ],
      "endpoints": [
        "https://vikunja.tailbc181.ts.net/",
        "https://id.minastas.xyz/",
        "service://mailrise.mailrise.svc.cluster.local"
      ],
      "backupEvidence": {
        "status": "blocked",
        "reason": "fresh logical backup ID unavailable",
        "collectionCommand": "kubectl exec -n <namespace> <postgres-pod> -- pg_dump --format=custom --file=/tmp/vikunja.dump <database>; kubectl exec -n <namespace> <postgres-pod> -- sha256sum /tmp/vikunja.dump"
      },
      "restoreEvidence": {
        "status": "blocked",
        "reason": "isolated restore not performed",
        "collectionCommand": "restore into an isolated database and record project/task-count checks"
      }
    },
    {
      "name": "wallos",
      "disposition": "retain",
      "targetHost": "services-pi",
      "image": "docker.io/bellamy/wallos@sha256:0f049dbab45b9f8e8d43b84fd1b77ef9e55909bd1a384a0f4fe8597ab68a1d5d",
      "architectures": [
        "linux/amd64",
        "linux/arm",
        "linux/arm64"
      ],
      "database": {
        "kind": "embedded",
        "engine": "SQLite",
        "versionFact": {
          "status": "blocked",
          "reason": "SQLite runtime version not collected",
          "collectionCommand": "kubectl exec -n <namespace> <wallos-pod> -- sqlite3 --version"
        },
        "databaseId": "wallos-database",
        "datasetId": "wallos-data",
        "sourcePaths": [ "/var/www/html/db" ],
        "targetPaths": [ "/var/lib/wallos/db" ],
        "datasetEvidence": { "status": "blocked", "reason": "database component coverage is not independently evidenced", "collectionCommand": "du -sb /var/www/html/db; record database identity, owner, source path, target path, and output digest" }
      },
      "datasetIds": [
        "wallos-data"
      ],
      "endpoints": [
        "https://wallos.tailbc181.ts.net/"
      ],
      "backupEvidence": {
        "status": "blocked",
        "reason": "fresh consistent backup not captured",
        "collectionCommand": "create a SQLite online backup, then record sha256sum and byte count"
      },
      "restoreEvidence": {
        "status": "blocked",
        "reason": "isolated restore not performed",
        "collectionCommand": "restore into an isolated instance and record subscription-count/logo checks"
      }
    },
    {
      "name": "whisparr",
      "disposition": "retain",
      "targetHost": "framework-03",
      "image": "ghcr.io/hotio/whisparr@sha256:c60aabe2ab85417e8f23dfc56285a33be413c5336ebe47b8f26eca9e7145540c",
      "architectures": [
        "linux/amd64"
      ],
      "database": {
        "kind": "embedded",
        "engine": "SQLite",
        "versionFact": {
          "status": "blocked",
          "reason": "SQLite runtime version not collected",
          "collectionCommand": "kubectl exec -n <namespace> <whisparr-pod> -- sqlite3 --version"
        },
        "databaseId": "whisparr-database",
        "datasetId": "whisparr-config",
        "sourcePaths": [ "/config" ],
        "targetPaths": [ "/var/lib/whisparr" ],
        "datasetEvidence": { "status": "blocked", "reason": "database component coverage is not independently evidenced", "collectionCommand": "du -sb /config; record database identity, owner, source path, target path, and output digest" }
      },
      "datasetIds": [
        "whisparr-config",
        "shared-video-library"
      ],
      "endpoints": [
        "https://whisparr.tailbc181.ts.net/"
      ],
      "backupEvidence": {
        "status": "blocked",
        "reason": "fresh application backup not captured",
        "collectionCommand": "create application backup and record artifact checksum"
      },
      "restoreEvidence": {
        "status": "blocked",
        "reason": "isolated restore not performed",
        "collectionCommand": "restore into an isolated instance and record item-count/download-client checks"
      }
    },
    {
      "name": "gitea",
      "disposition": "defer",
      "reason": "PostgreSQL export/archive decision outstanding",
      "endpoints": null
    },
    {
      "name": "gitea-runner",
      "disposition": "retire",
      "reason": "replaced by Forgejo runner",
      "endpoints": null
    },
    {
      "name": "manyfold",
      "disposition": "defer",
      "reason": "PostgreSQL export/archive decision outstanding",
      "endpoints": null
    },
    {
      "name": "qbittorrent",
      "disposition": "retire",
      "reason": "replaced by Deluge",
      "endpoints": null
    },
    {
      "name": "hookshot",
      "disposition": "retire",
      "reason": "scaled to zero",
      "endpoints": null
    }
  ]
}
