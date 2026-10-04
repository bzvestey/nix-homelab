{ ... }:
{
  fleet = {
    telemetry.enable = true;
    storage.nfsMounts = {
      videos = {
        source = "10.15.4.101:/mnt/spinners-1/videos";
        target = "/mnt/bulk/videos";
      };
      books = {
        source = "10.15.4.101:/mnt/spinners-1/Computer/books";
        target = "/mnt/bulk/books";
      };
    };
  };
}
