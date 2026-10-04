{ fleetTopology, ... }:
{
  networking.hosts = fleetTopology.aliasAddresses;
}
