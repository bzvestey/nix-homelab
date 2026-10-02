{ pkgs }:
let
  routes = import ../lib/public-ingress-routes.nix;
  sentinel = "task10-credential-sentinel-7f9c2d";
  testPython = pkgs.python3.withPackages (python: [ python.pyyaml ]);
  app = pkgs.writeText "origin-app.py" ''
    import http.server, sys
    identity = sys.argv[1]
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            host = self.headers.get("Host", "")
            body = f"origin={identity} host={host}\n".encode()
            self.send_response(200); self.end_headers(); self.wfile.write(body)
        def log_message(self, *args): pass
    http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[2])), Handler).serve_forever()
  '';
  fakeCloudflared = pkgs.writeShellApplication {
    name = "cloudflared";
    runtimeInputs = [ testPython ];
    text = ''
      exec python3 - "$@" <<'PY'
      import fnmatch, http.client, http.server, sys, yaml
      args = sys.argv[1:]
      config = args[args.index("--config") + 1]
      credentials = args[args.index("--credentials-file") + 1]
      with open(credentials, "rb") as f: f.read()
      with open(config) as f: ingress = yaml.safe_load(f)["ingress"]
      class Handler(http.server.BaseHTTPRequestHandler):
          def do_GET(self):
              incoming = self.headers.get("Host", "").split(":")[0]
              for route in ingress:
                  pattern = route.get("hostname")
                  if pattern is None: self.send_error(404); return
                  if fnmatch.fnmatchcase(incoming, pattern):
                      target = route["service"].removeprefix("http://").split(":")
                      override = route.get("originRequest", {}).get("httpHostHeader", incoming)
                      connection = http.client.HTTPConnection(target[0], int(target[1]), timeout=3)
                      connection.request("GET", self.path, headers={"Host": override})
                      response = connection.getresponse(); body = response.read()
                      self.send_response(response.status); self.end_headers(); self.wfile.write(body); return
              self.send_error(404)
          def log_message(self, *args): pass
      http.server.ThreadingHTTPServer(("0.0.0.0", 8888), Handler).serve_forever()
      PY
    '';
  };
  edge = pkgs.writeText "edge.py" ''
    import http.client, http.server
    backends = [("10.15.4.4", 8888), ("10.15.4.6", 8888)]
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            for host, port in backends:
                try:
                    connection = http.client.HTTPConnection(host, port, timeout=.5)
                    connection.request("GET", self.path, headers={"Host": self.headers["Host"]})
                    response = connection.getresponse(); body = response.read()
                    self.send_response(response.status); self.end_headers(); self.wfile.write(body); return
                except OSError: pass
            self.send_error(503)
        def log_message(self, *args): pass
    http.server.ThreadingHTTPServer(("0.0.0.0", 8081), Handler).serve_forever()
  '';
  lan = address: {
    virtualisation.vlans = [ 1 ];
    networking = {
      useNetworkd = true;
      interfaces.eth1.ipv4.addresses = [
        {
          inherit address;
          prefixLength = 24;
        }
      ];
    };
  };
  origin = address: routeList: services: {
    imports = [ ../modules/fleet/ingress.nix ];
    virtualisation.vlans = [ 1 ];
    fleet.ingress = {
      routes = routeList;
      lanInterface = "eth1";
      enableTailscale = false;
      testUseInternalTls = true;
    };
    networking = {
      useNetworkd = true;
      firewall = {
        enable = true;
        checkReversePath = "loose";
      };
      interfaces.eth1.ipv4.addresses = [
        {
          inherit address;
          prefixLength = 24;
        }
      ];
    };
    systemd.services = builtins.listToAttrs (
      map (service: {
        inherit (service) name;
        value = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 ${app} ${service.identity} ${toString service.port}";
        };
      }) services
    );
  };
  connector =
    address:
    {
      imports = [ ../modules/fleet/cloudflared.nix ];
      fleet.cloudflared = {
        enable = true;
        package = fakeCloudflared;
        credentialFile = "/run/secrets/cloudflared-tunnel.json";
        inherit routes;
      };
      systemd.services = {
        cloudflared-fleet.serviceConfig.Restart = pkgs.lib.mkForce "no";
        loki.wantedBy = [ "multi-user.target" ];
        loki.serviceConfig.ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
        prometheus.wantedBy = [ "multi-user.target" ];
        prometheus.serviceConfig.ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
      };
      networking.firewall.extraInputRules = ''
        iifname "eth1" ip saddr 10.15.4.20 tcp dport 8888 accept
      '';
    }
    // lan address;
in
pkgs.testers.runNixOSTest {
  name = "fleet-ingress";
  nodes = {
    origin5 =
      origin "10.15.4.5"
        [
          {
            hostname = "foundry.minastas.xyz";
            upstream = "http://127.0.0.1:9001";
            exposure = "public";
          }
          {
            hostname = "matrix.minastas.social";
            upstream = "http://127.0.0.1:9002";
            exposure = "public";
          }
          {
            hostname = "knot.minastas.xyz";
            upstream = "http://127.0.0.1:9003";
            exposure = "public";
          }
          {
            hostname = "minastas.social";
            upstream = "http://127.0.0.1:9004";
            exposure = "public";
          }
          {
            hostname = "pds.minastas.social";
            upstream = "http://127.0.0.1:9005";
            exposure = "public";
          }
          {
            hostname = "*.minastas.social";
            upstream = "http://127.0.0.1:9006";
            exposure = "public";
          }
          {
            hostname = "private.tailbc181.ts.net";
            upstream = "http://127.0.0.1:9007";
            exposure = "tailnet";
          }
        ]
        [
          {
            name = "foundry";
            identity = "foundry-.5";
            port = 9001;
          }
          {
            name = "matrix";
            identity = "matrix-.5";
            port = 9002;
          }
          {
            name = "knot";
            identity = "knot-.5";
            port = 9003;
          }
          {
            name = "root";
            identity = "root-.5";
            port = 9004;
          }
          {
            name = "pds";
            identity = "pds-.5";
            port = 9005;
          }
          {
            name = "wildcard";
            identity = "wildcard-.5";
            port = 9006;
          }
          {
            name = "private";
            identity = "private-.5";
            port = 9007;
          }
        ]
      // {
        virtualisation.vlans = [
          1
          2
        ];
        systemd.network.links."10-tailnet" = {
          matchConfig.OriginalName = "eth2";
          linkConfig.Name = "tailscale0";
        };
        networking.interfaces.tailscale0.ipv4.addresses = [
          {
            address = "100.64.0.5";
            prefixLength = 24;
          }
        ];
      };
    origin9 =
      origin "10.15.4.9"
        [
          {
            hostname = "id.minastas.xyz";
            upstream = "http://127.0.0.1:9010";
            exposure = "public";
          }
        ]
        [
          {
            name = "pocket-id";
            identity = "pocket-id-.9";
            port = 9010;
          }
        ];
    connectorA = connector "10.15.4.4";
    connectorB = connector "10.15.4.6";
    edge = {
      imports = [ (lan "10.15.4.20") ];
      networking.firewall.allowedTCPPorts = [ 8081 ];
      systemd.services.edge = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 ${edge}";
      };
    };
    lanClient = lan "10.15.4.30";
    tailClient = {
      virtualisation.vlans = [
        1
        2
      ];
      networking = {
        useNetworkd = true;
        interfaces.eth2.ipv4.addresses = [
          {
            address = "100.64.0.2";
            prefixLength = 24;
          }
        ];
      };
    };
  };
  testScript = ''
    import json, yaml
    start_all()
    for node, interface, address in (
        (origin5, "eth1", "10.15.4.5/24"), (origin5, "tailscale0", "100.64.0.5/24"),
        (origin9, "eth1", "10.15.4.9/24"), (connectorA, "eth1", "10.15.4.4/24"),
        (connectorB, "eth1", "10.15.4.6/24"), (edge, "eth1", "10.15.4.20/24"),
        (lanClient, "eth1", "10.15.4.30/24"), (tailClient, "eth2", "100.64.0.2/24")):
        node.succeed(f"ip address replace {address} dev {interface}")
    origin5.succeed("ip -6 address replace 2001:db8:2::5/64 dev tailscale0")
    tailClient.succeed("ip -6 address replace 2001:db8:2::2/64 dev eth2")
    for origin_node in (origin5, origin9):
        origin_node.wait_for_unit("caddy.service")
        origin_node.succeed("${pkgs.caddy}/bin/caddy validate --adapter caddyfile --config /etc/caddy/caddy_config")
    edge.wait_for_unit("edge.service")
    for connector in (connectorA, connectorB):
        connector.wait_for_unit("loki.service")
        connector.succeed("systemctl is-system-running --wait || true")
        connector.fail("systemctl is-active cloudflared-fleet.service")
    origin5.succeed("systemctl is-active foundry matrix knot root pds wildcard private caddy")
    origin9.succeed("systemctl is-active pocket-id caddy")
    lanClient.fail("curl --max-time 1 --fail http://10.15.4.5:9001")
    lanClient.fail("curl --max-time 1 --fail -H 'Host: foundry.minastas.xyz' http://10.15.4.5:8080")
    lanClient.fail("curl --max-time 1 --insecure --fail --resolve private.tailbc181.ts.net:443:10.15.4.5 https://private.tailbc181.ts.net")
    for connector in (connectorA, connectorB):
        connector.succeed("install -d -m 0700 /run/secrets; printf '%s' '{\"TunnelID\":\"\",\"Secret\":\"${sentinel}\"}' > /run/secrets/cloudflared-tunnel.json; chmod 0400 /run/secrets/cloudflared-tunnel.json")
        connector.succeed("systemctl start --no-block cloudflared-fleet.service; sleep 1; ! systemctl is-active cloudflared-fleet.service")
        connector.succeed("printf '%s' 'not-json' > /run/secrets/cloudflared-tunnel.json")
        connector.succeed("systemctl reset-failed cloudflared-fleet; systemctl start --no-block cloudflared-fleet.service; sleep 1; ! systemctl is-active cloudflared-fleet.service")
        connector.succeed("systemctl stop --no-block cloudflared-fleet; sleep 1; printf '%s' '{\"TunnelID\":\"11111111-1111-1111-1111-111111111111\",\"Secret\":\"${sentinel}\"}' > /run/secrets/cloudflared-tunnel.json; systemctl reset-failed cloudflared-fleet; systemctl start --no-block cloudflared-fleet")
        connector.wait_for_unit("cloudflared-fleet.service")
        connector.wait_for_open_port(8888, timeout=10)
        connector.succeed("timeout 10 ${pkgs.cloudflared}/bin/cloudflared --config /etc/cloudflared/fleet-ingress.yml tunnel ingress validate")
        connector.succeed("! grep -R '${sentinel}' /nix/store /etc/systemd/system /proc/$(systemctl show -p MainPID --value cloudflared-fleet)/cmdline /proc/$(systemctl show -p MainPID --value cloudflared-fleet)/environ 2>/dev/null")
    config_a = yaml.safe_load(connectorA.succeed("cat /etc/cloudflared/fleet-ingress.yml"))
    config_b = yaml.safe_load(connectorB.succeed("cat /etc/cloudflared/fleet-ingress.yml"))
    assert config_a == config_b
    expected = json.loads(r"""${builtins.toJSON routes}""")
    assert [entry.get("hostname") for entry in config_a["ingress"][:-1]] == [entry["hostname"] for entry in expected]
    assert config_a["ingress"][-1] == {"service": "http_status:404"}
    assert "originRequest" not in config_a["ingress"][-2]
    probes = {
      "id.minastas.xyz": "origin=pocket-id-.9 host=id.minastas.xyz",
      "foundry.minastas.xyz": "origin=foundry-.5 host=foundry.minastas.xyz",
      "matrix.minastas.social": "origin=matrix-.5 host=matrix.minastas.social",
      "knot.minastas.xyz": "origin=knot-.5 host=knot.minastas.xyz",
      "minastas.social": "origin=root-.5 host=minastas.social",
      "pds.minastas.social": "origin=pds-.5 host=pds.minastas.social",
      "other.minastas.social": "origin=wildcard-.5 host=other.minastas.social",
    }
    def probe(host): return edge.succeed(f"curl --max-time 5 --fail -H 'Host: {host}' http://127.0.0.1:8081")
    for host, expected_body in probes.items(): assert expected_body in probe(host)
    connectorB.succeed("systemctl stop cloudflared-fleet")
    assert probes["id.minastas.xyz"] in probe("id.minastas.xyz")
    connectorB.succeed("systemctl start cloudflared-fleet")
    connectorA.succeed("systemctl stop cloudflared-fleet")
    assert probes["foundry.minastas.xyz"] in probe("foundry.minastas.xyz")
    connectorB.succeed("systemctl stop loki prometheus")
    assert probes["foundry.minastas.xyz"] in probe("foundry.minastas.xyz")
    connectorB.succeed("systemctl stop cloudflared-fleet")
    edge.fail("curl --max-time 2 --fail -H 'Host: foundry.minastas.xyz' http://127.0.0.1:8081")
    origin5.succeed("systemctl is-active foundry matrix knot root pds wildcard private caddy")
  '';
}
