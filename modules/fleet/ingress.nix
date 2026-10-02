{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.fleet.ingress;
  publicRoutes = builtins.filter (route: route.exposure == "public") cfg.routes;
  tailnetRoutes = builtins.filter (route: route.exposure == "tailnet") cfg.routes;
  hostnames = map (route: route.hostname) cfg.routes;
  duplicates = lib.filter (hostname: lib.count (candidate: candidate == hostname) hostnames > 1) (
    lib.unique hostnames
  );
  wildcardValid = hostname: !(lib.hasInfix "*" hostname) || lib.hasPrefix "*." hostname;
  routeType = lib.types.submodule {
    options = {
      hostname = lib.mkOption {
        type = lib.types.strMatching "^(\\*\\.)?[A-Za-z0-9][A-Za-z0-9.-]*$";
        description = "DNS hostname served by Caddy; a wildcard is allowed only as the complete first label.";
      };
      upstream = lib.mkOption {
        type = lib.types.strMatching "^http://(127\\.0\\.0\\.1|localhost):[0-9]+$";
        description = "Loopback HTTP application origin.";
      };
      exposure = lib.mkOption {
        type = lib.types.enum [
          "public"
          "tailnet"
        ];
        description = "Exactly one route visibility class.";
      };
    };
  };
  mkSite = port: route: ''
    http://${route.hostname}:${toString port} {
      reverse_proxy ${route.upstream}
    }
  '';
  caddyfile = pkgs.writeText "fleet-caddyfile" ''
    {
      auto_https off
      admin 127.0.0.1:2019
    }
    ${lib.concatMapStringsSep "\n" (mkSite cfg.publicPort) publicRoutes}
    ${lib.concatMapStringsSep "\n" (mkSite cfg.tailnetPort) tailnetRoutes}
  '';
in
{
  options.fleet.ingress = {
    routes = lib.mkOption {
      type = lib.types.listOf routeType;
      default = [ ];
      description = "Service-owned local HTTP routes.";
    };
    publicPort = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "LAN origin port used only by the two tunnel connectors.";
    };
    tailnetPort = lib.mkOption {
      type = lib.types.port;
      default = 8443;
      description = "Private HTTP port admitted only on tailscale0.";
    };
    enableTailscale = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable native Tailscale and noninteractive enrollment.";
    };
    tailscaleAuthKeyFile = lib.mkOption {
      type = lib.types.strMatching "^/run/secrets/.*";
      default = "/run/secrets/tailscale-auth-key";
      description = "Runtime-only Tailscale auth key path.";
    };
  };

  config = lib.mkIf (cfg.routes != [ ]) {
    assertions = [
      {
        assertion = duplicates == [ ];
        message = "fleet.ingress.routes contains duplicate hostnames: ${lib.concatStringsSep ", " duplicates}";
      }
      {
        assertion = lib.all (route: wildcardValid route.hostname) cfg.routes;
        message = "fleet.ingress.routes wildcard must be the complete first hostname label";
      }
    ];

    services.caddy = {
      enable = true;
      configFile = caddyfile;
    };
    services.tailscale = lib.mkIf cfg.enableTailscale {
      enable = true;
      openFirewall = false;
      authKeyFile = cfg.tailscaleAuthKeyFile;
      authKeyParameters = {
        ephemeral = false;
        preauthorized = true;
      };
    };
    systemd.services.tailscaled-autoconnect.unitConfig.ConditionPathIsReadable =
      lib.mkIf cfg.enableTailscale cfg.tailscaleAuthKeyFile;

    networking.firewall.extraInputRules = ''
      ${lib.optionalString (publicRoutes != [ ]) ''
        ip saddr { 10.15.4.4, 10.15.4.6 } tcp dport ${toString cfg.publicPort} accept comment "cloudflared origins"
      ''}
      ${lib.optionalString (tailnetRoutes != [ ]) ''
        iifname "tailscale0" tcp dport ${toString cfg.tailnetPort} accept comment "tailnet Caddy"
      ''}
    '';
  };
}
