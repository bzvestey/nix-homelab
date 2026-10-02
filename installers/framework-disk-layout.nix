{
  device ? "/dev/installer-target",
}:
{
  disko.devices.disk.system = {
    type = "disk";
    inherit device;
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          label = "framework-efi";
          size = "1G";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [ "umask=0077" ];
          };
        };
        root = {
          label = "framework-root";
          size = "64G";
          content = {
            type = "luks";
            name = "cryptroot";
            passwordFile = "/run/framework-installer/recovery.key";
            settings = {
              allowDiscards = true;
              crypttabExtraOpts = [ "tpm2-device=auto" ];
            };
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/";
            };
          };
        };
        data = {
          label = "framework-data";
          size = "100%";
          content = {
            type = "luks";
            name = "cryptdata";
            passwordFile = "/run/framework-installer/recovery.key";
            settings = {
              allowDiscards = true;
              crypttabExtraOpts = [ "tpm2-device=auto" ];
            };
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/var/lib";
            };
          };
        };
      };
    };
  };
}
