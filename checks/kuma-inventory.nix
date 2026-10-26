{
  pkgs,
  lib,
  fleetTopology,
  nixosConfigurations,
}:
let
  generate = import ../lib/kuma-inventory.nix { inherit lib; };
  nodes = lib.mapAttrs (_: node: { inherit (node) address; }) fleetTopology.nodes;
  routesByHost = lib.mapAttrs (
    _: host:
    map (route: {
      inherit (route) hostname exposure;
    }) host.config.fleet.ingress.routes
  ) nixosConfigurations;
  input = { inherit nodes routesByHost; };
  baseline = generate input;
  inherit (baseline) checks;
  byKey = document: lib.listToAttrs (map (check: lib.nameValuePair check.key check) document.checks);
  lookup = byKey baseline;
  rejected = args: !(builtins.tryEval (builtins.deepSeq (generate args) true)).success;
  route = hostname: {
    inherit hostname;
    exposure = "tailnet";
  };
  synthetic =
    hostnames:
    input
    // {
      routesByHost = {
        synthetic = map route hostnames;
      };
    };
  grown = generate (
    input
    // {
      nodes = nodes // {
        hl-node-05.address = "10.15.4.10";
      };
    }
  );
  moved = generate (
    input
    // {
      nodes = nodes // {
        hl-node-00.address = "10.15.4.99";
      };
    }
  );
  removed = generate (
    input
    // {
      routesByHost = routesByHost // {
        hl-node-01 = [ ];
      };
    }
  );
  nested = generate (
    (synthetic [ "deep.child.tailbc181.ts.net" ])
    // {
      domainZones = [
        "ts.net"
        "tailbc181.ts.net"
      ];
    }
  );
  newZone = generate ((synthetic [ "app.example.org" ]) // { domainZones = [ "example.org" ]; });
  renamed = generate (
    (synthetic [ "new.minastas.xyz" ])
    // {
      overrides."new.minastas.xyz" = {
        key = "site:old.minastas.xyz";
        name = "Retained";
      };
    }
  );
  serialized = builtins.toJSON baseline;
  commonDefaults = {
    interval = 60;
    timeout = 10;
    retryInterval = 30;
    maxretries = 2;
  };
in
assert baseline.schemaVersion == 1;
assert baseline == nixosConfigurations.hl-node-00.config.fleet.observability.kumaReconciler.desired;
assert lib.length baseline.groups == 4;
assert lib.length checks == 28;
assert lib.count (check: check.type == "ping") checks == 5;
assert lib.count (check: check.parentKey == "group:tailbc181.ts.net") checks == 18;
assert lib.count (check: check.parentKey == "group:minastas.xyz") checks == 3;
assert lib.count (check: check.parentKey == "group:minastas.social") checks == 2;
assert lib.length grown.checks == 29;
assert (byKey grown)."node:hl-node-05".parentKey == "group:nix-homelab";
assert (byKey moved)."node:hl-node-00".target.hostname == "10.15.4.99";
assert moved.adoptions."node:hl-node-00".target.hostname == "10.15.4.6";
assert !builtins.hasAttr "site:id.minastas.xyz" (byKey removed);
assert
  lib.length
    (generate (synthetic [
      "*.minastas.social"
      "pds.minastas.social"
      "deluge-direct.tailbc181.ts.net"
    ])).checks == 5;
assert rejected (synthetic [ "app.unknown.org" ]);
assert rejected (synthetic [ "evilminastas.xyz" ]);
assert (byKey nested)."site:deep.child.tailbc181.ts.net".parentKey == "group:tailbc181.ts.net";
assert lib.any (group: group.key == "group:example.org") newZone.groups;
assert (byKey newZone)."site:app.example.org".parentKey == "group:example.org";
assert (byKey renamed)."site:old.minastas.xyz".name == "Retained";
assert rejected (
  input
  // {
    routesByHost = {
      a = [ (route "same.minastas.xyz") ];
      b = [ (route "same.minastas.xyz") ];
    };
  }
);
assert rejected (
  (synthetic [
    "a.minastas.xyz"
    "b.minastas.xyz"
  ])
  // {
    overrides."b.minastas.xyz".key = "site:a.minastas.xyz";
  }
);
assert rejected (
  input
  // {
    nodes = nodes // {
      other.address = nodes.hl-node-00.address;
    };
  }
);
assert
  lookup."site:hl-node-00.tailbc181.ts.net".target.url
  == "https://hl-node-00.tailbc181.ts.net/dashboard/api/health";
assert
  lookup."site:homarr.tailbc181.ts.net".target.url
  == "https://homarr.tailbc181.ts.net/api/health/live";
assert lookup."site:matrix.minastas.social".target.url == "https://matrix.minastas.social/";
assert lookup."site:minastas.social".target.url == "https://minastas.social/";
assert lookup."site:id.minastas.xyz".name == "PocketID";
assert lookup."site:knot.minastas.xyz".name == "Knot (tangled)";
assert lib.length (lib.attrNames baseline.adoptions) == 19;
assert
  map (id: baseline.adoptions.${"node:hl-node-0${toString id}"}.id) (lib.range 0 4) == [
    15
    6
    7
    11
    13
  ];
assert
  lib.mapAttrs (_: adoption: adoption.id) baseline.adoptions == {
    "group:nix-homelab" = 5;
    "group:tailbc181.ts.net" = 19;
    "group:minastas.xyz" = 20;
    "group:minastas.social" = 21;
    "node:hl-node-00" = 15;
    "node:hl-node-01" = 6;
    "node:hl-node-02" = 7;
    "node:hl-node-03" = 11;
    "node:hl-node-04" = 13;
    "site:foundry.minastas.xyz" = 1;
    "site:id.minastas.xyz" = 10;
    "site:matrix.minastas.social" = 14;
    "site:kavita.tailbc181.ts.net" = 17;
    "site:publications.tailbc181.ts.net" = 18;
    "site:minastas.social" = 22;
    "site:knot.minastas.xyz" = 23;
    "site:donetick.tailbc181.ts.net" = 24;
    "site:git.tailbc181.ts.net" = 25;
    "site:jellyfin.tailbc181.ts.net" = 26;
  };
assert lib.all (
  check:
  let
    adoption = baseline.adoptions.${check.key} or null;
  in
  adoption == null
  || (adoption.name == check.name && adoption.type == check.type && adoption.target == check.target)
) checks;
assert lib.all (
  adoption:
  !(builtins.elem adoption.id [
    8
    12
  ])
) (lib.attrValues baseline.adoptions);
assert baseline.policy.newChecks.ping == commonDefaults;
assert
  baseline.policy.newChecks.http == commonDefaults
  // {
    method = "GET";
    ignoreTls = false;
    maxredirects = 10;
    accepted_statuscodes = [ "200-299" ];
  };
assert baseline.policy.notificationPolicy == null;
assert
  (generate (
    input
    // {
      notificationPolicy = {
        "1" = true;
      };
    }
  )).policy.notificationPolicy == {
    "1" = true;
  };
assert
  baseline.digest
  == builtins.hashString "sha256" (builtins.toJSON (builtins.removeAttrs baseline [ "digest" ]));
assert
  baseline.digest
  == (generate (input // { routesByHost = lib.mapAttrs (_: lib.reverseList) routesByHost; })).digest;
assert baseline.digest != moved.digest;
assert lib.all (text: !(lib.hasInfix text serialized)) [
  "upstream"
  "/run/secrets"
  "password"
  "token"
  "entity"
  "installDisk"
];
assert
  (generate (
    input
    // {
      nodes = lib.mapAttrs (_: node: node // { secret = throw "node configuration leaked"; }) nodes;
      routesByHost = lib.mapAttrs (
        _: map (r: r // { upstream = throw "route origin leaked"; })
      ) routesByHost;
    }
  )).digest == baseline.digest;
pkgs.runCommand "kuma-inventory"
  {
    manifest = serialized;
    passAsFile = [ "manifest" ];
  }
  ''
    mkdir -p $out
    cp "$manifestPath" $out/manifest.json
  ''
