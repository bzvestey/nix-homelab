_: {
  virtualisation = {
    containers.containersConf.settings = {
      containers.log_driver = "journald";
      network.default_rootless_network_cmd = "pasta";
    };
    podman = {
      enable = true;
      defaultNetwork.settings.dns_enabled = true;
      autoPrune = {
        enable = true;
        dates = "weekly";
        flags = [ "--filter=until=720h" ];
      };
    };
  };
}
