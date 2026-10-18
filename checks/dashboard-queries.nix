{ pkgs }:
pkgs.runCommand "dashboard-query-contracts"
  {
    nativeBuildInputs = [
      pkgs.python3
      pkgs.prometheus.cli
    ];
  }
  ''
    export DASHBOARDS=${../dashboards}
    python3 ${./dashboard-queries.py}
    promtool test rules contracts.json
    touch $out
  ''
