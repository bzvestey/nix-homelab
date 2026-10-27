{ pkgs }:
let
  fixture = import ./fixtures/kuma-2.5.6.nix { inherit pkgs; };
  client = pkgs.callPackage ../packages/kuma-reconciler { };
  inherit (client) python;
in
pkgs.testers.runNixOSTest {
  name = "kuma-reconciler-service";
  nodes.machine = { config, lib, ... }: {
    imports = [ ../modules/fleet/kuma-reconciler.nix ];
    _module.args.kumaInventory = {
      nodes.one.address = "127.0.0.1";
      routesByHost = { };
    };
    fleet.observability.kumaReconciler = {
      enable = true;
      endpoint = "https://127.0.0.1:8443";
      credentialFile = "/run/kuma-test.json";
      domainZones = [ "example.org" ];
      notificationPolicy.notificationIDList = { };
      adoptions =
        lib.mapAttrs (_: anchor: anchor // { id = anchor.id + 100; })
          ((import ../lib/kuma-inventory.nix { inherit lib; }) {
            nodes = { };
            routesByHost = { };
          }).adoptions
        // {
          "group:nix-homelab" = {
            id = 1;
            name = "nix-homelab";
            type = "group";
          };
          "node:one" = {
            id = 2;
            name = "one";
            type = "ping";
            target.hostname = "127.0.0.1";
          };
        };
    };
    # Exercise the module's identical sandbox with the separately gated ongoing
    # command, without changing the real timer's dry-run mode.
    systemd.services.kuma-reconciler-ongoing = {
      serviceConfig = config.systemd.services.kuma-reconciler.serviceConfig // {
        ExecStart =
          lib.replaceStrings [ " plan " ] [ " reconcile " ]
            config.systemd.services.kuma-reconciler.serviceConfig.ExecStart
          + " --authorize-ongoing";
      };
    };
    services.prometheus.exporters.node = {
      enable = true;
      enabledCollectors = [ "systemd" ];
      extraFlags = [ "--collector.systemd.enable-restarts-metrics" ];
    };
    virtualisation.memorySize = 2048;
    environment.systemPackages = [
      python
      pkgs.nodejs
      pkgs.openssl
      pkgs.iputils
      pkgs.util-linux
    ];
  };
  testScript = ''
    from datetime import timedelta
    start_all()
    machine.wait_for_unit("multi-user.target")
    machine.succeed("systemctl stop kuma-reconciler.timer")
    print(machine.succeed(
      "PYTHONDONTWRITEBYTECODE=1 KUMA_ROOT=${fixture}/lib/node_modules/uptime-kuma "
      "CLIENT_FILE=${client}/lib/kuma-reconciler/client.py "
      "RECONCILE_FILE=${client}/lib/kuma-reconciler/reconcile.py "
      "CONTRACTS_FILE=${./kuma-reconciler.py} "
      "${python}/bin/python ${./kuma-service.py}", timeout=timedelta(seconds=210)))
  '';
}
