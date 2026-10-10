{ lib }:
let
  defaultNodes = {
    hl-node-00 = {
      system = "aarch64-linux";
      address = "10.15.4.6";
      hardwareClass = "raspberry-pi-5";
      imageType = "rpi";
      nic = {
        members = [ "end0" ];
        macAddress = "2c:cf:67:72:a7:20";
      };
    };
    hl-node-01 = {
      system = "aarch64-linux";
      address = "10.15.4.4";
      hardwareClass = "raspberry-pi-5";
      imageType = "rpi";
      nic = {
        members = [ "end0" ];
        macAddress = "2c:cf:67:ed:27:ed";
      };
    };
    hl-node-02 = {
      system = "x86_64-linux";
      address = "10.15.4.5";
      hardwareClass = "framework";
      imageType = "framework";
      nic = {
        members = [
          "lan0"
          "lan1"
        ];
        macAddress = "9c:bf:0d:00:23:fe";
        # Stable names are assigned by permanent MAC, not USB controller or port.
        permanentMacAddresses = {
          lan0 = "9c:bf:0d:00:23:fe";
          lan1 = "9c:bf:0d:00:25:5d";
        };
      };
      installDisk = {
        byId = "/dev/disk/by-id/nvme-Samsung_SSD_970_EVO_Plus_2TB_S59CNM0W713317D_1";
        model = "Samsung SSD 970 EVO Plus 2TB";
        serial = "S59CNM0W713317D";
        sectors = 3907029168;
      };
      gpuPciId = "8086:9a49";
    };
    hl-node-03 = {
      system = "x86_64-linux";
      address = "10.15.4.7";
      hardwareClass = "framework";
      imageType = "framework";
      nic = {
        members = [
          "enp0s13f0u3"
          "enp0s13f0u4"
        ];
        macAddress = "9c:bf:0d:00:0d:3c";
      };
      installDisk = {
        byId = "UNRESOLVED";
        model = "Samsung SSD 980 1TB";
        serial = "S64ANS0RB36721W";
        sectors = 1953525168;
      };
      gpuPciId = "8086:4626";
    };
    hl-node-04 = {
      system = "x86_64-linux";
      address = "10.15.4.9";
      hardwareClass = "framework";
      imageType = "framework";
      nic = {
        members = [
          "enp0s13f0u3"
          "enp0s13f0u4"
        ];
        macAddress = "9c:bf:0d:00:20:37";
      };
      installDisk = {
        byId = "UNRESOLVED";
        model = "Samsung SSD 980 1TB";
        serial = "S64ANL0T801753P";
        sectors = 1953525168;
      };
      gpuPciId = "8086:9a49";
    };
  };
  defaultRoleAssignments = {
    observability = "hl-node-00";
    lightweight-services = "hl-node-01";
    application-services = "hl-node-02";
    storage-services = "hl-node-03";
    developer-media-services = "hl-node-04";
  };
  defaultRoleAliases = {
    observability = "observability";
  };
  expectedNodeIds = map (number: "hl-node-0${toString number}") (lib.range 0 4);
  duplicates = values: lib.length (lib.unique values) != lib.length values;
  mkFleetTopology =
    {
      nodes ? defaultNodes,
      roleAssignments ? defaultRoleAssignments,
      roleAliases ? defaultRoleAliases,
    }:
    let
      nodeIds = lib.attrNames nodes;
      rolesForNode =
        nodeId: lib.attrNames (lib.filterAttrs (_: target: target == nodeId) roleAssignments);
      aliasAddresses = lib.foldlAttrs (
        result: role: alias:
        let
          nodeId = roleAssignments.${role};
          address = nodes.${nodeId}.address;
        in
        result // { ${address} = (result.${address} or [ ]) ++ [ alias ]; }
      ) { } roleAliases;
      validation =
        assert lib.assertMsg (
          nodeIds == expectedNodeIds
        ) "fleet topology must contain exactly the canonical node IDs";
        assert lib.assertMsg (lib.all (
          nodeId: builtins.match "hl-node-[0-9]{2}" nodeId != null
        ) nodeIds) "fleet topology contains a non-canonical node ID";
        assert lib.assertMsg (
          !duplicates (map (nodeId: nodes.${nodeId}.address) nodeIds)
        ) "fleet topology contains duplicate addresses";
        assert lib.assertMsg (
          !duplicates (map (nodeId: nodes.${nodeId}.nic.macAddress) nodeIds)
        ) "fleet topology contains duplicate NIC identities";
        assert lib.assertMsg (lib.all (nodeId: builtins.hasAttr nodeId nodes) (
          lib.attrValues roleAssignments
        )) "fleet topology role targets an unknown node";
        assert lib.assertMsg (lib.all (role: builtins.hasAttr role roleAssignments) (
          lib.attrNames roleAliases
        )) "fleet topology alias targets an unknown role";
        assert lib.assertMsg (
          !duplicates (lib.attrValues roleAliases)
        ) "fleet topology contains duplicate role aliases";
        true;
    in
    {
      inherit
        nodes
        roleAssignments
        roleAliases
        nodeIds
        rolesForNode
        aliasAddresses
        validation
        ;
    };
  fleetTopology = mkFleetTopology { };
in
{
  inherit mkFleetTopology fleetTopology;
}
