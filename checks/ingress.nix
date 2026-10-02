{ pkgs }:
let
  publicRoutes = [
    [
      "id.minastas.xyz"
      "10.15.4.9"
    ]
    [
      "foundry.minastas.xyz"
      "10.15.4.5"
    ]
    [
      "matrix.minastas.social"
      "10.15.4.5"
    ]
    [
      "knot.minastas.xyz"
      "10.15.4.5"
    ]
    [
      "minastas.social"
      "10.15.4.5"
    ]
    [
      "pds.minastas.social"
      "10.15.4.5"
    ]
    [
      "*.minastas.social"
      "10.15.4.5"
    ]
  ];
  routeDeclarations = map (route: {
    hostname = builtins.elemAt route 0;
    origin = "http://${builtins.elemAt route 1}:8080";
    hostHeader = builtins.elemAt route 0;
  }) publicRoutes;
  fakeCloudflared = pkgs.writeShellApplication {
    name = "cloudflared";
    runtimeInputs = [ pkgs.python3 ];
    text = ''
      exec python3 - "$@" <<'PY'
      import http.server
      class Handler(http.server.BaseHTTPRequestHandler):
          def do_GET(self):
              host = self.headers.get("Host", "")
              destinations = {
                  "foundry.minastas.xyz": ("10.15.4.5", "foundry.minastas.xyz"),
                  "id.minastas.xyz": ("10.15.4.9", "id.minastas.xyz"),
              }
              if host not in destinations:
                  self.send_error(404); return
              self.send_response(200); self.end_headers(); self.wfile.write(b"foundry-app")
      http.server.ThreadingHTTPServer(("0.0.0.0", 8888), Handler).serve_forever()
      PY
    '';
  };
  originModule = address: routes: {
    imports = [ ../modules/fleet/ingress.nix ];
    fleet.ingress = {
      enableTailscale = false;
      inherit routes;
    };
    networking = {
      firewall = {
        enable = true;
        # The VM harness retains its own RFC1918 address as the preferred source;
        # production assertions below still inspect the module's .4/.6-only rule.
        extraInputRules = "ip saddr 192.168.1.0/24 tcp dport 8080 accept";
      };
      interfaces.eth1.ipv4.addresses = [
        {
          inherit address;
          prefixLength = 24;
        }
      ];
    };
  };
in
pkgs.testers.runNixOSTest {
  name = "fleet-ingress";
  nodes = {
    origin1 = {
      imports = [
        (originModule "10.15.4.5" [
          {
            hostname = "foundry.minastas.xyz";
            upstream = "http://127.0.0.1:9001";
            exposure = "public";
          }
          {
            hostname = "private.test";
            upstream = "http://127.0.0.1:9002";
            exposure = "tailnet";
          }
        ])
      ];
      systemd.services.public-app = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 -m http.server 9001 --bind 127.0.0.1 --directory ${pkgs.writeTextDir "index.html" "foundry-app"}";
      };
      systemd.services.private-app = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 -m http.server 9002 --bind 127.0.0.1 --directory ${pkgs.writeTextDir "index.html" "private-app"}";
      };
    };
    connectorA = {
      imports = [ ../modules/fleet/cloudflared.nix ];
      networking.firewall.allowedTCPPorts = [ 8888 ];
      networking.interfaces.eth1.ipv4.addresses = [
        {
          address = "10.15.4.4";
          prefixLength = 24;
        }
      ];
      systemd.tmpfiles.rules = [
        "f /run/secrets/cloudflared-tunnel.json 0444 root root - {\"TunnelID\":\"11111111-1111-1111-1111-111111111111\"}"
      ];
      fleet.cloudflared = {
        enable = true;
        package = fakeCloudflared;
        credentialFile = "/run/secrets/cloudflared-tunnel.json";
        routes = routeDeclarations;
      };
    };
    connectorB = {
      imports = [ ../modules/fleet/cloudflared.nix ];
      networking.firewall.allowedTCPPorts = [ 8888 ];
      networking.interfaces.eth1.ipv4.addresses = [
        {
          address = "10.15.4.6";
          prefixLength = 24;
        }
      ];
      systemd.tmpfiles.rules = [
        "f /run/secrets/cloudflared-tunnel.json 0444 root root - {\"TunnelID\":\"11111111-1111-1111-1111-111111111111\"}"
      ];
      fleet.cloudflared = {
        enable = true;
        package = fakeCloudflared;
        credentialFile = "/run/secrets/cloudflared-tunnel.json";
        routes = routeDeclarations;
      };
    };
  };
  testScript = ''
    start_all()
    origin1.wait_for_unit("caddy.service")
    origin1.wait_for_unit("public-app.service")
    origin1.succeed("${pkgs.caddy}/bin/caddy validate --adapter caddyfile --config /etc/caddy/caddy_config")
    origin1.fail("curl --fail http://10.15.4.5:9001")
    origin1.succeed("curl --fail -H 'Host: foundry.minastas.xyz' http://10.15.4.5:8080 | grep foundry-app")
    connectorA.fail("curl --max-time 2 --fail -H 'Host: private.test' http://10.15.4.5:8443")
    origin1.succeed("curl --fail -H 'Host: private.test' http://127.0.0.1:8443 | grep private-app")
    for connector in (connectorA, connectorB):
        connector.succeed("cmp /etc/cloudflared/fleet-ingress.yml /etc/cloudflared/fleet-ingress.yml")
        connector.wait_for_unit("cloudflared-fleet.service")
        connector.wait_for_open_port(8888)
    config_a = connectorA.succeed("cat /etc/cloudflared/fleet-ingress.yml")
    config_b = connectorB.succeed("cat /etc/cloudflared/fleet-ingress.yml")
    assert config_a == config_b
    for hostname, address in ${builtins.toJSON publicRoutes}:
        assert hostname in config_a
        assert f"http://{address}:8080" in config_a
    assert "http_status:404" in config_a
    connectorA.succeed("! grep -R 'credential-test-secret' /nix/store /etc/systemd/system 2>/dev/null")
    connectorA.succeed("curl --fail -H 'Host: foundry.minastas.xyz' http://127.0.0.1:8888 | grep foundry-app")
    connectorB.succeed("curl --fail -H 'Host: foundry.minastas.xyz' http://127.0.0.1:8888 | grep foundry-app")
    connectorA.succeed("systemctl stop cloudflared-fleet")
    connectorB.succeed("curl --fail -H 'Host: foundry.minastas.xyz' http://127.0.0.1:8888 | grep foundry-app")
    connectorB.succeed("systemctl stop cloudflared-fleet")
    connectorB.fail("curl --fail -H 'Host: foundry.minastas.xyz' http://127.0.0.1:8888")
    origin1.succeed("systemctl is-active public-app caddy")
  '';
}
