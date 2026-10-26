{ lib }:
let
  # Reviewed bootstrap identities, not a live inventory or an executable import.
  siteIdentities = [
    [
      "foundry.minastas.xyz"
      "Foundry"
      1
    ]
    [
      "id.minastas.xyz"
      "PocketID"
      10
    ]
    [
      "matrix.minastas.social"
      "Matrix (Tuwunel)"
      14
    ]
    [
      "kavita.tailbc181.ts.net"
      "Kavita"
      17
    ]
    [
      "publications.tailbc181.ts.net"
      "Publication Manager"
      18
    ]
    [
      "minastas.social"
      "Tranquil PDS"
      22
    ]
    [
      "knot.minastas.xyz"
      "Knot (tangled)"
      23
    ]
    [
      "donetick.tailbc181.ts.net"
      "Donetick"
      24
    ]
    [
      "git.tailbc181.ts.net"
      "Forgejo"
      25
    ]
    [
      "jellyfin.tailbc181.ts.net"
      "Jellyfin"
      26
    ]
  ];
  groupIds = {
    nix-homelab = 5;
    "tailbc181.ts.net" = 19;
    "minastas.xyz" = 20;
    "minastas.social" = 21;
  };
  nodeIdentities = [
    [
      "hl-node-00"
      15
      "10.15.4.6"
    ]
    [
      "hl-node-01"
      6
      "10.15.4.4"
    ]
    [
      "hl-node-02"
      7
      "10.15.4.5"
    ]
    [
      "hl-node-03"
      11
      "10.15.4.7"
    ]
    [
      "hl-node-04"
      13
      "10.15.4.9"
    ]
  ];
  defaultAdoptions =
    lib.mapAttrs' (
      name: id:
      lib.nameValuePair "group:${name}" {
        inherit id name;
        type = "group";
      }
    ) groupIds
    // lib.listToAttrs (
      map (
        row:
        lib.nameValuePair "node:${builtins.elemAt row 0}" {
          id = builtins.elemAt row 1;
          name = builtins.elemAt row 0;
          type = "ping";
          target.hostname = builtins.elemAt row 2;
        }
      ) nodeIdentities
    )
    // lib.listToAttrs (
      map (
        row:
        lib.nameValuePair "site:${builtins.elemAt row 0}" {
          id = builtins.elemAt row 2;
          name = builtins.elemAt row 1;
          type = "http";
          target.url = "https://${builtins.elemAt row 0}/";
        }
      ) siteIdentities
    );
  defaultOverrides =
    lib.listToAttrs (
      map (
        row:
        lib.nameValuePair (builtins.elemAt row 0) {
          name = builtins.elemAt row 1;
        }
      ) siteIdentities
    )
    // {
      "hl-node-00.tailbc181.ts.net" = {
        name = "Observability Grafana";
        path = "/dashboard/api/health";
      };
      "homarr.tailbc181.ts.net" = {
        name = "Homarr";
        path = "/api/health/live";
      };
      "wallos.tailbc181.ts.net".name = "Wallos";
      "feed.tailbc181.ts.net".name = "CommaFeed";
      "mealie.tailbc181.ts.net".name = "Mealie";
      "immich.tailbc181.ts.net".name = "Immich";
      "vikunja.tailbc181.ts.net".name = "Vikunja";
      "deluge.tailbc181.ts.net".name = "Deluge";
      "prowlarr.tailbc181.ts.net".name = "Prowlarr";
      "radarr.tailbc181.ts.net".name = "Radarr";
      "sabnzbd.tailbc181.ts.net".name = "SABnzbd";
      "sonarr.tailbc181.ts.net".name = "Sonarr";
      "whisparr.tailbc181.ts.net".name = "Whisparr";
      "pds.minastas.social".exclude = true;
      "deluge-direct.tailbc181.ts.net".exclude = true;
    };
  unique = values: lib.length values == lib.length (lib.unique values);
  sortByKey = lib.sort (a: b: a.key < b.key);
in
{
  nodes,
  routesByHost,
  domainZones ? [
    "tailbc181.ts.net"
    "minastas.xyz"
    "minastas.social"
  ],
  overrides ? { },
  adoptions ? { },
  notificationPolicy ? null,
}:
let
  effectiveOverrides = lib.recursiveUpdate defaultOverrides overrides;
  zones = map lib.toLower domainZones;
  groups = sortByKey (
    map (name: {
      key = "group:${name}";
      inherit name;
    }) ([ "nix-homelab" ] ++ zones)
  );
  parentFor =
    hostname:
    let
      matches = lib.sort (a: b: builtins.stringLength a > builtins.stringLength b) (
        lib.filter (zone: hostname == zone || lib.hasSuffix ".${zone}" hostname) zones
      );
    in
    if matches == [ ] then
      throw "Kuma inventory: unconfigured domain for ${hostname}"
    else
      "group:${lib.head matches}";
  routes = lib.concatMap (
    host:
    map (route: {
      inherit host;
      hostname = lib.toLower route.hostname;
      inherit (route) exposure;
    }) routesByHost.${host}
  ) (lib.attrNames routesByHost);
  selected = lib.filter (
    route:
    !(lib.hasInfix "*" route.hostname) && !(effectiveOverrides.${route.hostname}.exclude or false)
  ) routes;
  sites = map (
    route:
    let
      override = effectiveOverrides.${route.hostname} or { };
      path = override.path or "/";
    in
    assert lib.assertMsg (builtins.elem route.exposure [
      "public"
      "tailnet"
    ]) "Kuma inventory: invalid exposure";
    assert lib.assertMsg (
      builtins.match "[a-z0-9][a-z0-9.-]*" route.hostname != null
    ) "Kuma inventory: invalid hostname";
    assert lib.assertMsg (
      lib.hasPrefix "/" path && !(lib.hasPrefix "//" path)
    ) "Kuma inventory: health path must be absolute";
    {
      key = override.key or "site:${route.hostname}";
      type = "http";
      name = override.name or route.hostname;
      parentKey = parentFor route.hostname;
      target.url = "https://${route.hostname}${path}";
    }
  ) selected;
  pings = lib.mapAttrsToList (id: node: {
    key = "node:${id}";
    type = "ping";
    name = id;
    parentKey = "group:nix-homelab";
    target.hostname = node.address;
  }) nodes;
  checks = sortByKey (pings ++ sites);
  commonDefaults = {
    interval = 60;
    timeout = 10;
    maxretries = 2;
    retryInterval = 30;
  };
  document = {
    schemaVersion = 1;
    inherit groups checks;
    adoptions = defaultAdoptions // adoptions;
    policy = {
      inherit notificationPolicy;
      # Creation-only: these are deliberately not fields on existing checks.
      newChecks = {
        ping = commonDefaults;
        http = commonDefaults // {
          method = "GET";
          ignoreTls = false;
          maxredirects = 10;
          accepted_statuscodes = [ "200-299" ];
        };
      };
    };
  };
in
assert lib.assertMsg (unique (
  map (item: item.key) (groups ++ checks)
)) "Kuma inventory: duplicate key";
assert lib.assertMsg (unique (
  map (item: builtins.toJSON item.target) checks
)) "Kuma inventory: duplicate target";
assert lib.assertMsg (unique (
  map (route: route.hostname) selected
)) "Kuma inventory: duplicate route";
document // { digest = builtins.hashString "sha256" (builtins.toJSON document); }
