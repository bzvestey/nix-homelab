{ ... }:
{
  imports = [
    ../services/immich
    ../services/mealie
    ../services/tuwunel
  ];
  services.fleet = {
    immich.enable = true;
    mealie.enable = true;
    tuwunel.enable = true;
  };
}
