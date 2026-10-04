{
  pkgs,
  lib,
  mkFleetTopology,
  fleetTopology,
  selectRoleModules,
}:
let
  expectedNodeIds = map (number: "hl-node-0${toString number}") (lib.range 0 4);
  expectedNodes = {
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
          "enp0s13f0u1"
          "enp0s13f0u2"
        ];
        macAddress = "9c:bf:0d:00:23:fe";
      };
      installDisk = {
        byId = "UNRESOLVED";
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
  expectedRoleAssignments = {
    observability = "hl-node-00";
    lightweight-services = "hl-node-01";
    application-services = "hl-node-02";
    storage-services = "hl-node-03";
    developer-media-services = "hl-node-04";
  };
  expectedAddresses = lib.mapAttrs (_: node: node.address) expectedNodes;
  addresses = lib.mapAttrs (_: node: node.address) fleetTopology.nodes;
  moved = mkFleetTopology {
    roleAssignments = expectedRoleAssignments // {
      observability = "hl-node-04";
    };
  };
  duplicateIpNodes = fleetTopology.nodes // {
    hl-node-01 = fleetTopology.nodes.hl-node-01 // {
      address = fleetTopology.nodes.hl-node-00.address;
    };
  };
  duplicateIp = builtins.tryEval ((mkFleetTopology { nodes = duplicateIpNodes; }).validation);
  unknownRole = builtins.tryEval (
    (mkFleetTopology {
      roleAssignments = expectedRoleAssignments // {
        observability = "hl-node-99";
      };
    }).validation
  );
  aliasCollision = builtins.tryEval (
    (mkFleetTopology {
      roleAliases = {
        observability = "services";
        lightweight-services = "services";
      };
    }).validation
  );
  contract =
    assert fleetTopology.nodeIds == expectedNodeIds;
    assert lib.all (nodeId: builtins.match "hl-node-[0-9]{2}" nodeId != null) fleetTopology.nodeIds;
    assert fleetTopology.nodes == expectedNodes;
    assert addresses == expectedAddresses;
    assert fleetTopology.roleAssignments == expectedRoleAssignments;
    assert
      fleetTopology.roleAliases == {
        observability = "observability";
      };
    assert lib.length (lib.unique (lib.attrValues addresses)) == lib.length fleetTopology.nodeIds;
    assert lib.all (nodeId: builtins.hasAttr nodeId fleetTopology.nodes) (
      lib.attrValues fleetTopology.roleAssignments
    );
    assert lib.all (
      role: lib.length (fleetTopology.rolesForNode fleetTopology.roleAssignments.${role}) == 1
    ) (lib.attrNames expectedRoleAssignments);
    assert
      lib.length (lib.unique (lib.attrValues fleetTopology.roleAliases))
      == lib.length (lib.attrValues fleetTopology.roleAliases);
    assert
      fleetTopology.aliasAddresses == {
        "10.15.4.6" = [ "observability" ];
      };
    assert duplicateIp.success == false;
    assert unknownRole.success == false;
    assert aliasCollision.success == false;
    assert moved.nodes.hl-node-00.address == "10.15.4.6";
    assert moved.nodes.hl-node-04.address == "10.15.4.9";
    assert moved.rolesForNode "hl-node-00" == [ ];
    assert
      moved.rolesForNode "hl-node-04" == [
        "developer-media-services"
        "observability"
      ];
    assert selectRoleModules moved "hl-node-00" == [ ];
    assert lib.length (selectRoleModules moved "hl-node-04") == 2;
    assert
      moved.aliasAddresses == {
        "10.15.4.9" = [ "observability" ];
      };
    true;
in
assert contract;
pkgs.runCommand "fleet-topology" { } ''
  touch "$out"
''
