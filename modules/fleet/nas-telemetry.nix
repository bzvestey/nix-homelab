{ config, lib, ... }:
let
  cfg = config.fleet.observability.nas;
in
{
  options.fleet.observability.nas = {
    enable = lib.mkEnableOption "TrueNAS Graphite and authenticated Garage metrics";
    garageTarget = lib.mkOption {
      type = lib.types.str;
      default = "nas.tailbc181.ts.net:30190";
    };
    tokenFile = lib.mkOption {
      type = lib.types.strMatching "^/run/.*";
      default = "/run/secrets/garage-metrics-token";
    };
    allowedSenders = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "100.102.187.89" ];
      description = "NAS source IPv4 addresses permitted to send Graphite over TCP.";
    };
  };
  config = lib.mkIf cfg.enable {
    services.prometheus.exporters.graphite = {
      enable = true;
      listenAddress = "0.0.0.0";
      openFirewall = false;
      extraFlags = [
        "--graphite.mapping-strict-match"
        "--graphite.sample-expiry=180s"
      ];
      mappingSettings.mappings = [
        {
          match = "^truenas\\.(.+)$";
          match_type = "regex";
          name = "truenas_netdata";
          labels.metric = "$1";
        }
      ];
    };
    # Runtime SOPS credentials are intentionally unavailable in the build sandbox.
    services.prometheus.checkConfig = "syntax-only";
    services.prometheus.scrapeConfigs = [
      {
        job_name = "truenas";
        sample_limit = 20000;
        static_configs = [
          {
            targets = [ "127.0.0.1:9108" ];
            labels.host_name = "nas";
          }
        ];
      }
      {
        job_name = "garage";
        sample_limit = 10000;
        authorization = {
          type = "Bearer";
          credentials_file = cfg.tokenFile;
        };
        static_configs = [
          {
            targets = [ cfg.garageTarget ];
            labels.host_name = "nas";
          }
        ];
      }
    ];
    networking.nftables.enable = true;
    networking.firewall.extraInputRules =
      lib.concatMapStringsSep "\n" (address: ''
        ip saddr ${address} tcp dport 9109 accept comment "TrueNAS Graphite"
      '') cfg.allowedSenders
      + ''
        tcp dport { 9108, 9109 } drop comment "No external exporter access or untrusted Graphite"
        udp dport 9109 drop comment "Graphite accepts TCP only"
      '';
  };
}
