{ config, ... }:
let
  branchPolicy = {
    main = {
      name = "main";
      operation = "switch";
    };
    testing = {
      name = "testing-${config.networking.hostName}";
      operation = "test";
    };
  };
in
{
  environment.etc."comin/allowed_signers".text =
    "bryan@vestey.dev ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMpx0yPdFPKUFBLn6OKJJAyqnlvoLmll4m97l/YMLu8\n";
  services.comin = {
    enable = true;
    debug = false;
    sshAllowedSignersPath = "/etc/comin/allowed_signers";
    exporter = {
      listen_address = "0.0.0.0";
      port = 4243;
      openFirewall = false;
    };
    remotes = [
      {
        name = "github";
        url = "https://github.com/bzvestey/nix-homelab.git";
        branches = branchPolicy;
        poller.period = 60;
      }
      {
        name = "tangled";
        url = "https://tangled.org/bzvestey.minastas.social/nix-homelab";
        branches = branchPolicy;
        poller.period = 60;
      }
    ];
    retention = {
      deployment_boot_entry_capacity = 3;
      deployment_successful_capacity = 3;
      deployment_any_capacity = 5;
    };
  };
  networking.nftables.enable = true;
  networking.firewall.extraInputRules = ''
    ip saddr 10.15.4.6 tcp dport 4243 accept comment "observability comin scrape"
  '';
}
