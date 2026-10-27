{ pkgs }:
let
  fixture = import ./fixtures/kuma-2.5.6.nix { inherit pkgs; };
  client = pkgs.callPackage ../packages/kuma-reconciler { };
  inherit (client) python;
  generate = import ../lib/kuma-inventory.nix { inherit (pkgs) lib; };
  generated = generate {
    nodes.one.address = "192.0.2.1";
    routesByHost.one = [
      {
        hostname = "test.example.org";
        exposure = "public";
      }
    ];
    domainZones = [ "example.org" ];
    overrides."test.example.org".name = ''Café 😀 / "quoted" \ slash'';
  };
  document = (builtins.removeAttrs generated [ "digest" ]) // {
    adoptions = { };
  };
  desired = pkgs.writeText "kuma-planner-desired.json" (
    builtins.toJSON (
      document
      // {
        digest = builtins.hashString "sha256" (builtins.toJSON document);
      }
    )
  );
in
pkgs.testers.runNixOSTest {
  # Keep this contract check stable; kuma-service separately exercises the
  # hardened NixOS units without consuming this suite's 600s driver budget,
  # which accommodates slower native ARM execution.
  name = "kuma-reconciler-contracts";
  # Actual ICMP requires CAP_NET_RAW; an ordinary build sandbox cannot supply
  # it. Keep the real server and all test ports inside this disposable VM.
  nodes.machine = {
    virtualisation.memorySize = 2048;
    environment.systemPackages = [
      python
      pkgs.nodejs
      pkgs.openssl
      pkgs.iputils
    ];
  };
  testScript = ''
    from datetime import timedelta

    start_all()
    machine.wait_for_unit("multi-user.target")
    print(machine.succeed(
        "PYTHONDONTWRITEBYTECODE=1 "
        "KUMA_ROOT=${fixture}/lib/node_modules/uptime-kuma "
        "CLIENT_FILE=${client}/lib/kuma-reconciler/client.py "
        "RECONCILE_FILE=${client}/lib/kuma-reconciler/reconcile.py "
        "RECONCILE_BIN=${client}/bin/kuma-reconciler "
        "DESIRED_FILE=${desired} "
        # Includes the literal 120s deadline test plus create/update durability
        # failure and reviewed-recovery cases; allow slower native ARM execution
        # without changing any runtime deadlines or individual test assertions.
        "${python}/bin/python ${./kuma-reconciler.py}", timeout=timedelta(seconds=600)
    ))
  '';
}
