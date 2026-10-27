{
  pkgs,
  lib,
  fleetTopology,
  nixosConfigurations,
}:
let
  inventory = {
    nodes.one.address = "192.0.2.1";
    routesByHost.one = [
      {
        hostname = "app.example.org";
        exposure = "public";
      }
    ];
  };
  evaluate =
    settings:
    (import (pkgs.path + "/nixos/lib/eval-config.nix") {
      system = pkgs.stdenv.hostPlatform.system;
      modules = [
        ../modules/fleet/kuma-reconciler.nix
        {
          boot.isContainer = true;
          system.stateVersion = "26.05";
          _module.args.kumaInventory = inventory;
          fleet.observability.kumaReconciler = settings;
        }
      ];
    }).config;
  disabled = evaluate { };
  enabledSettings = {
    enable = true;
    endpoint = "https://kuma.example.org";
    credentialFile = "/run/private/kuma.json";
    domainZones = [ "example.org" ];
  };
  enabled = evaluate enabledSettings;
  valid = config: lib.all (a: a.assertion) config.assertions;
  observer = nixosConfigurations.hl-node-00;
  realEnabled =
    (observer.extendModules {
      modules = [
        {
          # Tie the observer projection back to this ENABLED configuration, including
          # its own Grafana route. Poison unrelated fields to catch broad forcing.
          _module.args.kumaInventory = lib.mkForce {
            nodes = lib.mapAttrs (_: node: { inherit (node) address; }) fleetTopology.nodes;
            routesByHost = lib.mapAttrs (
              name: host:
              map
                (route: {
                  inherit (route) hostname exposure;
                  upstream = throw "Kuma forced an unrelated route field";
                })
                (
                  if name == "hl-node-00" then realEnabled.fleet.ingress.routes else host.config.fleet.ingress.routes
                )
            ) nixosConfigurations;
          };
        }
      ];
    }).config;
in
assert !(disabled.systemd.services ? kuma-reconciler);
assert !(disabled.systemd.timers ? kuma-reconciler);
assert !(disabled.users.users ? kuma-reconciler);
assert disabled.networking.firewall.allowedTCPPorts == [ ];
assert !(disabled ? sops);
assert valid enabled;
assert enabled.fleet.observability.kumaReconciler.mode == "dry-run";
assert lib.hasInfix " plan " enabled.systemd.services.kuma-reconciler.serviceConfig.ExecStart;
assert !(valid (evaluate (enabledSettings // { endpoint = null; })));
assert lib.all (endpoint: !(valid (evaluate (enabledSettings // { inherit endpoint; })))) [
  "http://kuma.example.org"
  "https://user:pass@kuma.example.org"
  "https://kuma.example.org/path"
  "https://kuma.example.org?token=x"
  "https://kuma.example.org#fragment"
  "https://kuma.example.org:99999"
];
assert lib.all
  (credentialFile: !(valid (evaluate (enabledSettings // { inherit credentialFile; }))))
  [
    null
    "relative"
    "/run/../secret"
    "/nix/store/secret"
    "/run/%n.json"
    "/run/secret\nother"
  ];
assert !(valid (evaluate (enabledSettings // { mode = "apply"; })));
assert lib.all
  (
    notificationPolicy:
    !(valid (
      evaluate (
        enabledSettings
        // {
          mode = "apply";
          inherit notificationPolicy;
        }
      )
    ))
  )
  [
    { }
    { notificationIDList."0" = true; }
    { notificationIDList."1" = "yes"; }
  ];
assert valid (
  evaluate (
    enabledSettings
    // {
      mode = "apply";
      notificationPolicy.notificationIDList = { };
    }
  )
);
assert lib.hasInfix " reconcile "
  (evaluate (
    enabledSettings
    // {
      mode = "apply";
      notificationPolicy.notificationIDList = { };
    }
  )).systemd.services.kuma-reconciler.serviceConfig.ExecStart;
assert observer.config.fleet.observability.kumaReconciler.enable;
assert observer.config.fleet.observability.kumaReconciler.mode == "dry-run";
assert observer.config.fleet.observability.kumaReconciler.notificationPolicy == null;
assert
  observer.config.fleet.observability.kumaReconciler.credentialFile
  == observer.config.sops.secrets.kuma-reconciler-management.path;
assert observer.config.sops.secrets.kuma-reconciler-management.owner == "root";
assert observer.config.sops.secrets.kuma-reconciler-management.group == "root";
assert observer.config.sops.secrets.kuma-reconciler-management.mode == "0600";
assert lib.hasInfix " plan "
  observer.config.systemd.services.kuma-reconciler.serviceConfig.ExecStart;
assert lib.any (
  check:
  check.key == "site:hl-node-00.tailbc181.ts.net"
  && check.target.url == "https://hl-node-00.tailbc181.ts.net/dashboard/api/health"
) realEnabled.fleet.observability.kumaReconciler.desired.checks;
assert lib.length realEnabled.fleet.observability.kumaReconciler.desired.checks == 28;
assert realEnabled.systemd.services.kuma-reconciler.serviceConfig.RuntimeMaxSec == 150;
assert builtins.stringLength realEnabled.system.build.toplevel.drvPath > 0;
pkgs.runCommand "kuma-module" { } "touch $out"
