_:
{
  networking = {
    useDHCP = false;
    useNetworkd = true;
    nameservers = [ "10.15.4.1" ];
  };
  systemd.network.enable = true;
}
