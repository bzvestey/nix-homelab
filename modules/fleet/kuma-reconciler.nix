{
  config,
  lib,
  pkgs,
  kumaInventory ? { },
  ...
}:
let
  cfg = config.fleet.observability.kumaReconciler;
  generate = import ../../lib/kuma-inventory.nix { inherit lib; };
  origin =
    if cfg.endpoint == null then
      null
    else
      builtins.match "https://([A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?|[[][0-9A-Fa-f:]+[]])(:([0-9]{1,5}))?" cfg.endpoint;
  port = if origin == null then null else builtins.elemAt origin 3;
  validOrigin = origin != null && (port == null || (lib.toInt port >= 1 && lib.toInt port <= 65535));
  validCredential =
    cfg.credentialFile != null
    && lib.hasPrefix "/" cfg.credentialFile
    && !lib.hasPrefix "/nix/store/" cfg.credentialFile
    && builtins.match "/[^[:space:]]+" cfg.credentialFile != null
    && !lib.hasInfix "%" cfg.credentialFile
    && !(builtins.elem ".." (lib.splitString "/" cfg.credentialFile));
  validPolicy =
    cfg.notificationPolicy != null
    && builtins.attrNames cfg.notificationPolicy == [ "notificationIDList" ]
    && builtins.isAttrs cfg.notificationPolicy.notificationIDList
    && lib.all (
      key:
      builtins.match "[1-9][0-9]*" key != null
      && builtins.isBool cfg.notificationPolicy.notificationIDList.${key}
    ) (builtins.attrNames cfg.notificationPolicy.notificationIDList);
  package = pkgs.callPackage ../../packages/kuma-reconciler { };
  desiredFile = pkgs.writeText "kuma-desired.json" (builtins.toJSON cfg.desired);
  state = "/var/lib/kuma-reconciler";
  arguments = lib.escapeShellArgs [
    "--desired"
    (toString desiredFile)
    "--endpoint"
    (if cfg.endpoint == null then "" else cfg.endpoint)
    "--state-dir"
    state
  ];
  # %d is expanded by systemd, never the shell/environment. Credential contents
  # remain in the private credential mount, including for the child transport.
  command =
    mode: suffix:
    "${package}/bin/kuma-reconciler ${mode} ${arguments} --credential-file %d/management.json${suffix}";
  service = mode: suffix: {
    description = "Uptime Kuma inventory reconciliation (${mode})";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      User = "kuma-reconciler";
      Group = "kuma-reconciler";
      StateDirectory = [
        "kuma-reconciler"
        "kuma-reconciler-review"
      ];
      StateDirectoryMode = "0700";
      UMask = "0077";
      LoadCredential = [
        "management.json:${if cfg.credentialFile == null then "" else cfg.credentialFile}"
      ];
      ExecStart = command mode suffix;
      RuntimeMaxSec = 150;
      # RuntimeMaxSec does not cover a oneshot's activation phase.
      TimeoutStartSec = 150;
      TimeoutStopSec = 5;
      KillMode = "control-group";
      MemoryMax = "256M";
      NoNewPrivileges = true;
      CapabilityBoundingSet = "";
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectKernelLogs = true;
      ProtectControlGroups = true;
      ProtectClock = true;
      RestrictSUIDSGID = true;
      RestrictRealtime = true;
      LockPersonality = true;
      RestrictNamespaces = true;
      RestrictAddressFamilies = [
        "AF_UNIX"
        "AF_INET"
        "AF_INET6"
      ];
      SystemCallArchitectures = "native";
      SystemCallFilter = [ "@system-service" ];
    };
  };
in
{
  options.fleet.observability.kumaReconciler = {
    enable = lib.mkEnableOption "private Uptime Kuma reconciliation";
    mode = lib.mkOption {
      type = lib.types.enum [
        "dry-run"
        "apply"
      ];
      default = "dry-run";
    };
    endpoint = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Exact HTTPS management origin, without path or credentials.";
    };
    credentialFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Private runtime absolute credential JSON path (not in the Nix store).";
    };
    domainZones = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "tailbc181.ts.net"
        "minastas.xyz"
        "minastas.social"
      ];
    };
    overrides = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
    };
    adoptions = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
    };
    notificationPolicy = lib.mkOption {
      type = lib.types.nullOr (lib.types.attrsOf lib.types.anything);
      default = null;
    };
    desired = lib.mkOption {
      type = lib.types.attrs;
      readOnly = true;
      default = generate (
        kumaInventory
        // {
          inherit (cfg)
            domainZones
            overrides
            adoptions
            notificationPolicy
            ;
        }
      );
      description = "Non-secret schemaVersion 1 generated inventory; evaluated only when used.";
    };
  };
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = validOrigin;
        message = "kumaReconciler.endpoint must be an exact HTTPS origin with a valid port.";
      }
      {
        assertion = validCredential;
        message = "kumaReconciler.credentialFile must be an absolute private runtime path.";
      }
      {
        assertion = cfg.mode != "apply" || validPolicy;
        message = "Kuma apply requires explicit notificationPolicy.notificationIDList approval.";
      }
    ];
    users.groups.kuma-reconciler = { };
    users.users.kuma-reconciler = {
      isSystemUser = true;
      group = "kuma-reconciler";
    };
    systemd.services = {
      kuma-reconciler =
        if cfg.mode == "dry-run" then service "plan" "" else service "reconcile" " --authorize-ongoing";
      # Deliberately unhooked from targets/timers: explicit operator starts only.
      kuma-reconciler-plan = service "plan" " --output /var/lib/kuma-reconciler-review/plan.json";
      kuma-reconciler-bootstrap = service "apply" " --plan-file /var/lib/kuma-reconciler-review/plan.json";
    };
    systemd.timers.kuma-reconciler = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2m";
        OnUnitActiveSec = "5m";
        Unit = "kuma-reconciler.service";
      };
    };
  };
}
