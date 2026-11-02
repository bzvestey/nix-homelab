{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.fleet.tailscaleServices.services;
  cli = lib.getExe config.services.tailscale.package;
in
{
  options.fleet.tailscaleServices.services = lib.mkOption {
    default = { };
    description = "Native Tailscale Services hosted by the existing tagged host daemon.";
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          upstream = lib.mkOption {
            type = lib.types.strMatching "^http://127\\.0\\.0\\.1:[0-9]+$";
            description = "Loopback HTTP application origin, served over Service HTTPS 443.";
          };
          serviceUnit = lib.mkOption {
            type = lib.types.strMatching "^[a-zA-Z0-9@_.-]+\\.service$";
            description = "Application unit that must run before advertisement.";
          };
        };
      }
    );
  };

  config = lib.mkIf (cfg != { }) {
    assertions = [
      {
        assertion = config.services.tailscale.enable;
        message = "Native Tailscale Services require the existing host daemon.";
      }
      {
        assertion = lib.all (name: builtins.match "[a-z0-9][a-z0-9-]*" name != null) (
          builtins.attrNames cfg
        );
        message = "Native Tailscale Service names must be lowercase letters, digits, and hyphens.";
      }
    ];
    systemd.services = lib.mapAttrs' (
      name: service:
      lib.nameValuePair "tailscale-service-${name}" {
        description = "Advertise native Tailscale Service svc:${name}";
        wantedBy = [
          "multi-user.target"
          "tailscaled.service"
          service.serviceUnit
        ];
        requires = [
          "tailscaled.service"
          service.serviceUnit
        ];
        after = [
          "tailscaled.service"
          "tailscaled-autoconnect.service"
          service.serviceUnit
        ];
        bindsTo = [ service.serviceUnit ];
        partOf = [ "tailscaled.service" ];
        path = [
          pkgs.coreutils
          pkgs.jq
          pkgs.util-linux
        ];
        unitConfig.StartLimitIntervalSec = 0;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          Restart = "on-failure";
          RestartSec = 10;
          TimeoutStartSec = 90;
          TimeoutStopSec = 30;
        };
        script = ''
          set -euo pipefail
          # Serialize local Serve read/modify/write operations across these units.
          exec 9>/run/lock/fleet-tailscale-services.lock
          flock -w 20 9
          deadline=$((SECONDS + 60))
          until status="$(timeout 5s ${cli} status --json --peers=false)" &&
            jq -e '.BackendState == "Running" and ((.Self.Tags // []) | length > 0)' <<< "$status" >/dev/null; do
            if (( SECONDS >= deadline )); then
              echo 'Host Tailscale daemon must be running with a tagged identity.' >&2
              exit 1
            fi
            sleep 1
          done
          timeout 20s ${cli} serve --yes --service=svc:${name} --https=443 ${lib.escapeShellArg service.upstream}
          # The pinned Serve CLI ignores errors from its implicit advertisement.
          # Explicit advertisement propagates preference failures for retries.
          timeout 20s ${cli} serve advertise svc:${name}
          echo 'Local Service configured; control-plane approval and remote reachability require separate verification.'
        '';
        preStop = ''
          set -euo pipefail
          exec 9>/run/lock/fleet-tailscale-services.lock
          flock -w 5 9
          # Drain only this Service; leave its configuration for existing sessions.
          # Intentional decommissioning clears it after clients have disconnected.
          timeout 20s ${cli} serve drain svc:${name}
        '';
      }
    ) cfg;
  };
}
