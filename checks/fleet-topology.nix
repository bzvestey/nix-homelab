{
  pkgs,
  lib,
  mkFleetTopology,
  fleetTopology,
}:
let
  expectedNodeIds = map (number: "hl-node-0${toString number}") (lib.range 0 4);
  expectedRoleAssignments = {
    observability = "hl-node-00";
    lightweight-services = "hl-node-01";
    application-services = "hl-node-02";
    storage-services = "hl-node-03";
    developer-media-services = "hl-node-04";
  };
  expectedAddresses = {
    hl-node-00 = "10.15.4.6";
    hl-node-01 = "10.15.4.4";
    hl-node-02 = "10.15.4.5";
    hl-node-03 = "10.15.4.7";
    hl-node-04 = "10.15.4.9";
  };
  addresses = lib.mapAttrs (_: node: node.address) fleetTopology.nodes;
  moved = mkFleetTopology {
    roleAssignments = expectedRoleAssignments // {
      observability = "hl-node-01";
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
    assert moved.nodes.hl-node-01.address == "10.15.4.4";
    assert
      moved.aliasAddresses == {
        "10.15.4.4" = [ "observability" ];
      };
    true;
in
assert contract;
pkgs.runCommand "fleet-topology" { } ''
  touch "$out"
''
