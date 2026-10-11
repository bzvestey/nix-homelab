{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.fleet.tailscaleServiceProxy;
  proxies = builtins.attrValues cfg.proxies;
  ports = map (proxy: proxy.port) proxies;
  hostnames = map (proxy: proxy.hostname) proxies;
  proxyType = lib.types.submodule {
    options = {
      upstream = lib.mkOption {
        type = lib.types.strMatching "^http://(127\\.0\\.0\\.1|localhost):[0-9]+$";
        description = "Host-loopback HTTP application URL, reached by userspace Serve's system dialer.";
      };
      hostname = lib.mkOption {
        type = lib.types.strMatching "^[a-z0-9][a-z0-9.-]*\\.ts\\.net$";
        description = "Expected existing Self.DNSName, without the trailing dot; never sets or renames the node.";
      };
      seedStateFile = lib.mkOption {
        type = lib.types.strMatching "^/run/secrets/.+";
        description = "Runtime SOPS secret containing native tailscaled JSON state, not Kubernetes Secret JSON or an auth key.";
      };
      port = lib.mkOption {
        type = lib.types.port;
        description = "Dedicated nonzero WireGuard UDP port, distinct from other proxies and the main daemon.";
      };
    };
  };
  mkProxy =
    name: proxy:
    let
      directory = "tailscale-${name}";
      stateDir = "/var/lib/${directory}";
      state = "${stateDir}/tailscaled.state";
      socket = "/run/${directory}/tailscaled.sock";
      cli = "${lib.getExe pkgs.tailscale} --socket=${socket}";
      seed = pkgs.writeShellScript "${directory}-seed" ''
        set -euo pipefail
        umask 077
        # Native state values remain base64 strings; conversion belongs to the caller.
        validate() {
          ${lib.getExe pkgs.jq} -e '
            type == "object" and
            ([.["_machinekey"], .["_profiles"], .["_current-profile"]]
              | all(.[]; type == "string" and length > 0)) and
            (to_entries | any(.[]; (.key | startswith("profile-")) and
              (.value | type == "string" and length > 0)))
          ' "$1" >/dev/null
        }
        if [ ! -e ${state} ]; then
          seed=${lib.escapeShellArg proxy.seedStateFile}
          if [ ! -r "$seed" ] || ! validate "$seed"; then
            echo 'Missing or invalid migrated identity seed; refusing to create a new node.' >&2
            exit 1
          fi
          # Stage and validate before atomic installation; never replace daemon-updated state.
          tmp="$(${lib.getExe' pkgs.coreutils "mktemp"} ${stateDir}/.seed.XXXXXX)"
          trap '${lib.getExe' pkgs.coreutils "rm"} -f "$tmp"' EXIT
          ${lib.getExe' pkgs.coreutils "cat"} "$seed" > "$tmp"
          validate "$tmp"
          ${lib.getExe' pkgs.coreutils "ln"} "$tmp" ${state}
        fi
        if ! validate ${state}; then
          echo 'Invalid persistent identity state; refusing to start or reseed.' >&2
          exit 1
        fi
      '';
      ready = pkgs.writeShellScript "${directory}-serve" ''
        set -euo pipefail
        # Bound both individual LocalAPI calls and the entire readiness phase.
        deadline=$((SECONDS + 60))
        while (( SECONDS < deadline )); do
          if status="$(${lib.getExe' pkgs.coreutils "timeout"} --kill-after=2s 5s ${cli} status --json --peers=false)"; then
            if ${lib.getExe pkgs.jq} -e '.BackendState == "Running"' <<< "$status" >/dev/null; then
              if ! ${lib.getExe pkgs.jq} -e --arg expected ${lib.escapeShellArg proxy.hostname} \
                '(.Self.DNSName | rtrimstr(".")) == $expected' <<< "$status" >/dev/null; then
                echo 'Migrated identity DNS name mismatch; refusing to configure Serve.' >&2
                exit 1
              fi
              exec ${lib.getExe' pkgs.coreutils "timeout"} --kill-after=2s 20s ${cli} serve --bg --yes --https=443 ${lib.escapeShellArg proxy.upstream}
            fi
          fi
          ${lib.getExe' pkgs.coreutils "sleep"} 1
        done
        echo 'Migrated identity did not reach Running before the readiness deadline.' >&2
        exit 1
      '';
    in
    {
      description = "Persistent Tailscale service identity for ${name}";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [
        "network-online.target"
        "sops-install-secrets.service"
      ];
      unitConfig = {
        StartLimitIntervalSec = 300;
        StartLimitBurst = 3;
      };
      serviceConfig = {
        # Match native tailscaled's sd_notify startup, then gate success on identity/Serve.
        Type = "notify";
        ExecStartPre = seed;
        # The containing filesystem is LUKS-encrypted. Keep portable native
        # state for backup/restore rather than binding these identities to TPM.
        ExecStart = "${lib.getExe' pkgs.tailscale "tailscaled"} --encrypt-state=false --tun=userspace-networking --state=${state} --statedir=${stateDir} --socket=${socket} --port=${toString proxy.port}";
        ExecStartPost = ready;
        TimeoutStartSec = 120;
        TimeoutStopSec = 30;
        Restart = "on-failure";
        RestartSec = 10;
        StateDirectory = directory;
        StateDirectoryMode = "0700";
        RuntimeDirectory = directory;
        RuntimeDirectoryMode = "0700";
        UMask = "0077";
        # Host networking is intentional: localhost must reach the host applications.
        # No global tailscaled --cleanup, login, or Serve reset on failure/rollback.
      };
    };
in
{
  options.fleet.tailscaleServiceProxy.proxies = lib.mkOption {
    type = lib.types.attrsOf proxyType;
    default = { };
    description = "Named standalone migrated Tailscale identities. Each gets tailscale-<name>.service and private persistent state; an empty set disables all proxies.";
  };

  config = lib.mkIf (cfg.proxies != { }) {
    assertions = [
      {
        assertion = lib.all (name: builtins.match "[a-z0-9][a-z0-9-]*" name != null) (
          builtins.attrNames cfg.proxies
        );
        message = "fleet.tailscaleServiceProxy proxy names must contain only lowercase letters, digits and hyphens.";
      }
      {
        assertion = builtins.length ports == builtins.length (lib.unique ports);
        message = "fleet.tailscaleServiceProxy proxies must use distinct UDP ports.";
      }
      {
        assertion =
          !config.services.tailscale.enable || !(builtins.elem config.services.tailscale.port ports);
        message = "fleet.tailscaleServiceProxy UDP ports must not overlap the main tailscaled port.";
      }
      {
        assertion = builtins.length hostnames == builtins.length (lib.unique hostnames);
        message = "fleet.tailscaleServiceProxy proxies must have distinct expected DNS hostnames.";
      }
    ];
    networking.firewall.allowedUDPPorts = ports;
    systemd.services = lib.mapAttrs' (
      name: proxy: lib.nameValuePair "tailscale-${name}" (mkProxy name proxy)
    ) cfg.proxies;
  };
}
