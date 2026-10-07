{ pkgs, nixosConfigurations }:
let
  inherit (pkgs) lib;
  frameworks = [
    "hl-node-02"
    "hl-node-03"
    "hl-node-04"
  ];
  labels = [ "ubuntu-latest:docker://ghcr.io/catthehacker/ubuntu:act-latest" ];
  validFramework =
    name:
    let
      c = nixosConfigurations.${name}.config;
      instances = c.services.forgejo-runner.instances;
      runner = instances.${name};
      units = lib.filterAttrs (n: _: lib.hasPrefix "forgejo-runner-" n) c.systemd.services;
      unit = builtins.head (builtins.attrValues units);
    in
    builtins.attrNames instances == [ name ]
    && runner.enable
    && runner.settings.runner.labels == labels
    && runner.settings.container.docker_host == "-"
    && !runner.settings.container.privileged
    && runner.settings.container.valid_volumes == [ ]
    && runner.secrets.server.connections.default.token_url == "/run/secrets/forgejo-runner-${name}"
    && builtins.length (builtins.attrNames units) == 1
    && unit.serviceConfig.StandardOutput == "journal"
    && unit.serviceConfig.StateDirectory == "forgejo-runner/${name}"
    && unit.unitConfig.ConditionPathExists == "/run/secrets/forgejo-runner-${name}"
    && !runner.settings.cache.enabled
    && !c.virtualisation.docker.enable
    && c.services.restic.backups == { };
  image = pkgs.dockerTools.buildLayeredImage {
    name = "runner-fixture";
    tag = "local";
    contents = pkgs.buildEnv {
      name = "runner-fixture-root";
      paths = [
        pkgs.bashInteractive
        pkgs.coreutils
        pkgs.gitMinimal
      ];
      pathsToLink = [ "/bin" ];
    };
    extraCommands = ''
      mkdir -p tmp
      chmod 1777 tmp
    '';
    config = {
      Env = [ "PATH=/bin" ];
      Cmd = [
        "/bin/sleep"
        "infinity"
      ];
    };
  };
  fixtureUuid = "11111111-1111-4111-8111-111111111111";
  runnerNode =
    name:
    { config, lib, ... }:
    {
      imports = [
        ../modules/fleet/podman.nix
        ../modules/services/forgejo-runner
      ];
      virtualisation.memorySize = 2048;
      virtualisation.diskSize = 4096;
      networking.firewall.enable = false;
      environment.systemPackages = [ pkgs.jq ];
      services.fleet.forgejo-runner = {
        enable = true;
        inherit name;
        uuid = fixtureUuid;
        instanceUrl = "http://server:3000/";
        tokenFile = "/run/runner-token";
        labels = [ "${name}:docker://runner-fixture:local" ];
      };
      services.forgejo-runner.instances.${name}.settings.log.level = "debug";
      # Fixture API allocates UUIDs at runtime. Follow the upstream forgejo.nix
      # test's substitution, without changing production credential handling.
      systemd.services."forgejo-runner-${name}" = {
        preStart = ''
          rm -f ./config.yaml
          cp ${config.services.forgejo-runner.instances.${name}.configFile} ./config.yaml
          chmod u+w ./config.yaml
          ${lib.getExe pkgs.replace-secret} "${fixtureUuid}" "$CREDENTIALS_DIRECTORY/UUID" ./config.yaml
          chmod u-w ./config.yaml
        '';
        serviceConfig = {
          ExecStart = lib.mkForce "${lib.getExe pkgs.forgejo-runner} daemon --config ./config.yaml";
          LoadCredential = [ "UUID:/run/runner-uuid" ];
        };
      };
    };
  integration = pkgs.testers.runNixOSTest {
    name = "forgejo-three-podman-runners";
    nodes = {
      r2 = runnerNode "r2";
      r3 = runnerNode "r3";
      r4 = runnerNode "r4";
      server = { config, ... }: {
        virtualisation.memorySize = 2048;
        networking.firewall.allowedTCPPorts = [ 3000 ];
        services.forgejo = {
          enable = true;
          settings = {
            server.ROOT_URL = "http://server:3000/";
            service.DISABLE_REGISTRATION = true;
            actions.ENABLED = true;
          };
        };
        environment.systemPackages = [
          config.services.forgejo.package
          pkgs.gitMinimal
          pkgs.jq
        ];
      };
    };
    testScript = ''
      import json
      import shlex
      import time

      start_all()
      runners = [r2, r3, r4]
      server.wait_for_unit("forgejo.service")
      server.wait_for_open_port(3000)
      server.succeed("su -l forgejo -c 'GITEA_WORK_DIR=/var/lib/forgejo forgejo admin user create --admin --username test --password totallysafe --email test@localhost --must-change-password=false'")
      api_token = json.loads(server.succeed("curl --fail -s http://test:totallysafe@localhost:3000/api/v1/users/test/tokens --json '{\"name\":\"fixture\",\"scopes\":[\"all\"]}'"))["sha1"]

      def api(path, body=None, method=None):
          cmd = "curl --fail -s http://localhost:3000/api/v1/" + path
          cmd += " -H " + shlex.quote("Authorization: token " + api_token)
          if body is not None:
              cmd += " --json " + shlex.quote(json.dumps(body))
          if method is not None:
              cmd += " -X " + method
          return json.loads(server.succeed(cmd))

      identities = []
      for machine in runners:
          unit = "forgejo-runner-" + machine.name + ".service"
          machine.wait_for_unit("multi-user.target")
          machine.succeed("test $(systemctl show " + unit + " -p ActiveState --value) = inactive")
          machine.succeed("test $(systemctl --failed --no-legend | wc -l) = 0")
          registration = api("admin/actions/runners", {"name": machine.name, "ephemeral": False})
          identities.append(registration["uuid"])
          # Only fixture credentials are transported; no production secrets.
          machine.succeed("umask 077; printf %s " + shlex.quote(registration["token"]) + " > /run/runner-token")
          machine.succeed("umask 077; printf %s " + shlex.quote(registration["uuid"]) + " > /run/runner-uuid")
          machine.succeed("podman load -i ${image}")
          machine.succeed("systemctl start " + unit)
          machine.wait_for_unit(unit)
          machine.wait_until_succeeds("journalctl -u " + unit + " -o cat | grep 'declared successfully'")
          machine.succeed("test -d /var/lib/forgejo-runner/" + machine.name)
          machine.succeed("test -z \"$(systemctl list-unit-files --no-legend 'restic-backups-*')\"")

      assert len(set(identities)) == 3
      def runner_identities():
          response = api("admin/actions/runners")
          entries = response["runners"] if isinstance(response, dict) else response
          assert len(entries) == 3, response
          # last_online/status are activity, not registration identity.
          return sorted((entry["id"], entry["name"], entry["uuid"]) for entry in entries)

      before = runner_identities()
      for machine in runners:
          machine.succeed("systemctl restart forgejo-runner-" + machine.name)
          machine.wait_for_unit("forgejo-runner-" + machine.name)
      assert runner_identities() == before, "Restart created or changed runner registrations"

      api("user/repos", {"name": "repo", "private": False, "auto_init": False})
      api("repos/test/repo", {"has_actions": True}, "PATCH")
      jobs = {}
      for name in ["r2", "r3", "r4"]:
          for iteration in range(2):
              marker = name + str(iteration)
              jobs[marker] = {
                  "runs-on": name,
                  "steps": [{"run": "set -eu; test ! -e /tmp/job-marker; test ! -e \"$GITHUB_WORKSPACE/job-marker\"; "
                            + "test ! -S /var/run/docker.sock; test ! -S /run/podman/podman.sock; "
                            + "echo " + marker + " > /tmp/job-marker; "
                            + "echo " + marker + " > \"$GITHUB_WORKSPACE/job-marker\"; "
                            + "sleep 20; test $(cat /tmp/job-marker) = " + marker
                            + "; test $(cat \"$GITHUB_WORKSPACE/job-marker\") = " + marker}]
              }
      workflow = json.dumps({"on": {"push": {}}, "jobs": jobs})
      server.succeed("mkdir -p /tmp/repo/.forgejo/workflows; git -C /tmp/repo init -b main")
      server.succeed("printf %s " + shlex.quote(workflow) + " > /tmp/repo/.forgejo/workflows/test.yaml")
      server.succeed("git -C /tmp/repo add .; git -C /tmp/repo -c user.name=test -c user.email=test@localhost commit -m fixture")
      server.succeed("git -C /tmp/repo push http://test:totallysafe@localhost:3000/test/repo.git main")

      inspected = {m.name: set() for m in runners}
      deadline = time.monotonic() + 240
      while time.monotonic() < deadline:
          for machine in runners:
              ids = machine.succeed("podman ps -q").split()
              for container_id in ids:
                  code, output = machine.execute("podman inspect " + container_id)
                  if code != 0:
                      continue
                  container = json.loads(output)[0]
                  assert not container["HostConfig"]["Privileged"]
                  assert all("sock" not in mount["Destination"] for mount in container["Mounts"])
                  inspected[machine.name].add(container_id)
          tasks = api("repos/test/repo/actions/tasks").get("workflow_runs", [])
          if any(task["status"] == "failure" for task in tasks):
              for machine in runners:
                  print(machine.succeed("journalctl -u forgejo-runner-" + machine.name + " -o cat"))
              raise Exception("An inline job failed: " + json.dumps(tasks))
          if len(tasks) >= 6 and all(task["status"] == "success" for task in tasks):
              break
          time.sleep(1)
      else:
          raise Exception("Six independent jobs did not finish: " + json.dumps(tasks))
      for machine in runners:
          assert len(inspected[machine.name]) >= 2, inspected
          machine.wait_until_succeeds("test -z \"$(podman ps -aq)\"")
          machine.wait_until_succeeds("test -z \"$(podman volume ls -q)\"")
          machine.succeed("journalctl -u forgejo-runner-" + machine.name + " -o cat | grep -i 'success'")
      assert runner_identities() == before, "Job execution changed runner identities"
    '';
  };
in
assert lib.assertMsg (lib.all validFramework frameworks) "Framework runner invariants failed";
assert lib.assertMsg (
  builtins.length (
    lib.unique (
      map (name: nixosConfigurations.${name}.config.services.fleet.forgejo-runner.uuid) frameworks
    )
  ) == 3
) "Runner UUIDs must be unique";
assert lib.assertMsg (lib.all
  (name: nixosConfigurations.${name}.config.services.forgejo-runner.instances == { })
  [
    "hl-node-00"
    "hl-node-01"
  ]
) "Pis must not run Actions runners";
pkgs.linkFarm "forgejo-runner-checks" [
  {
    name = "integration";
    path = integration;
  }
]
