{ pkgs }:
let
  inherit (pkgs) lib;
  module = ../modules/fleet/tailscale-services.nix;
  evaluate =
    services:
    import (pkgs.path + "/nixos/lib/eval-config.nix") {
      system = pkgs.stdenv.hostPlatform.system;
      modules = [
        module
        {
          services.tailscale.enable = true;
          fleet.tailscaleServices.services = services;
          system.stateVersion = "26.05";
        }
      ];
    };
  fixture = evaluate {
    fixture = {
      upstream = "http://127.0.0.1:18081";
      serviceUnit = "fixture-app.service";
    };
  };
  c = fixture.config;
in
assert lib.assertMsg (builtins.pathExists module) "Native Tailscale Services module is missing";
assert c.systemd.services.tailscale-service-fixture.enable;
assert builtins.elem "tailscaled.service" c.systemd.services.tailscale-service-fixture.after;
assert builtins.elem "fixture-app.service" c.systemd.services.tailscale-service-fixture.after;
assert !(evaluate { }).config.systemd.services ? tailscale-service-fixture;
assert
  !(builtins.tryEval (
    builtins.deepSeq
      (evaluate {
        fixture = {
          upstream = "http://10.15.4.9:18081";
          serviceUnit = "fixture-app.service";
        };
      }).config.systemd.services.tailscale-service-fixture.script
      true
  )).success;
pkgs.testers.runNixOSTest {
  name = "native-tailscale-services";
  nodes.machine = { lib, ... }: {
    imports = [ module ];
    services.tailscale.enable = true;
    environment.systemPackages = [
      pkgs.tailscale
      pkgs.jq
    ];
    fleet.tailscaleServices.services.fixture = {
      upstream = "http://127.0.0.1:18081";
      serviceUnit = "fixture-app.service";
    };
    systemd.services = {
      fixture-app.serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.coreutils}/bin/true";
      };
      # Exercise the real pinned CLI against a controlled LocalAPI boundary.
      # This tests our unit lifecycle, not control-plane approval or VPN routing.
      tailscaled.serviceConfig = {
        Type = lib.mkForce "simple";
        ExecStopPost = lib.mkForce "";
        ExecStart = lib.mkForce [
          ""
          "${pkgs.python3}/bin/python3 ${pkgs.writeText "localapi-fixture.py" ''
            import http.server, json, os, pathlib, socketserver
            root = pathlib.Path('/var/lib/service-fixture')
            root.mkdir(exist_ok=True)
            state = root / 'config.json'
            prefs = root / 'prefs.json'
            if not state.exists():
                state.write_text(json.dumps({'Services': {'svc:unrelated': {
                    'TCP': {'444': {'HTTPS': True}},
                    'Web': {'unrelated.example.ts.net:444': {'Handlers': {'/': {'Proxy': 'http://127.0.0.1:19000'}}}}
                }}}))
            if not prefs.exists():
                prefs.write_text(json.dumps({'AdvertiseServices': ['svc:unrelated']}))
            class Handler(http.server.BaseHTTPRequestHandler):
                def handle_request(self):
                    path = self.path.split('?')[0]
                    if self.command == 'PATCH' and pathlib.Path('/run/prefs-fail').exists():
                        self.send_error(503, 'fixture preference update failure')
                        return
                    if path == '/localapi/v0/status':
                        value = {'BackendState': 'NeedsLogin' if pathlib.Path('/run/logged-out').exists() else 'Running',
                                 'Self': {'DNSName': 'host.example.ts.net.', 'Tags': [] if pathlib.Path('/run/untagged').exists() else ['tag:test'], 'CapMap': {'https': []}},
                                 'CurrentTailnet': {'MagicDNSSuffix': 'example.ts.net'}}
                    elif path in ['/localapi/v0/serve-config', '/localapi/v0/prefs']:
                        file = state if path.endswith('serve-config') else prefs
                        value = json.loads(file.read_text())
                        if self.command != 'GET':
                            if self.headers.get('Transfer-Encoding') == 'chunked':
                                chunks = []
                                while True:
                                    size = int(self.rfile.readline().strip(), 16)
                                    if not size:
                                        self.rfile.readline()
                                        break
                                    chunks.append(self.rfile.read(size))
                                    self.rfile.read(2)
                                body = b"".join(chunks)
                            else:
                                body = self.rfile.read(int(self.headers['Content-Length']))
                            update = json.loads(body)
                            if self.command == 'PATCH':
                                value['AdvertiseServices'] = update['AdvertiseServices']
                            else:
                                value = update
                            file.write_text(json.dumps(value))
                    else:
                        self.send_error(404, path)
                        return
                    body = json.dumps(value).encode()
                    self.send_response(200)
                    self.send_header('Content-Length', str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                do_GET = do_POST = do_PATCH = handle_request
                def log_message(self, *args): pass
            socket = '/run/tailscale/tailscaled.sock'
            pathlib.Path(socket).parent.mkdir(exist_ok=True)
            if os.path.exists(socket): os.unlink(socket)
            class Server(socketserver.UnixStreamServer): pass
            Server(socket, Handler).serve_forever()
          ''}"
        ];
      };
      tailscale-service-fixture.serviceConfig.TimeoutStartSec = lib.mkForce 5;
    };
  };
  testScript = ''
    start_all()
    machine.wait_for_unit("tailscale-service-fixture.service")
    def check_preserved():
        machine.succeed("jq -e '.Services[\"svc:unrelated\"].Web[\"unrelated.example.ts.net:444\"].Handlers[\"/\"].Proxy == \"http://127.0.0.1:19000\"' /var/lib/service-fixture/config.json")
        machine.succeed("jq -e '.AdvertiseServices | index(\"svc:unrelated\") != null' /var/lib/service-fixture/prefs.json")
    def check_fixture():
        machine.succeed("jq -e '.Services[\"svc:fixture\"].Web[\"fixture.example.ts.net:443\"].Handlers[\"/\"].Proxy == \"http://127.0.0.1:18081\"' /var/lib/service-fixture/config.json")
        machine.succeed("jq -e '.AdvertiseServices | index(\"svc:fixture\") != null' /var/lib/service-fixture/prefs.json")
        check_preserved()
    check_fixture()
    machine.succeed("systemctl restart tailscale-service-fixture")
    check_fixture()
    machine.succeed("tailscale serve drain svc:fixture; tailscale serve --yes --service=svc:fixture --https=443 http://127.0.0.1:18082")
    machine.succeed("jq -e '.Services[\"svc:fixture\"].Web[\"fixture.example.ts.net:443\"].Handlers[\"/\"].Proxy == \"http://127.0.0.1:18082\"' /var/lib/service-fixture/config.json")
    check_preserved()
    machine.succeed("systemctl restart tailscale-service-fixture")
    check_fixture()
    machine.succeed("systemctl restart tailscaled")
    machine.wait_for_unit("tailscale-service-fixture.service")
    check_fixture()
    machine.succeed("systemctl stop fixture-app")
    machine.wait_until_fails("systemctl is-active --quiet tailscale-service-fixture")
    machine.succeed("jq -e '.AdvertiseServices | index(\"svc:fixture\") == null' /var/lib/service-fixture/prefs.json")
    check_preserved()
    machine.succeed("systemctl start fixture-app")
    machine.wait_for_unit("tailscale-service-fixture.service")
    check_fixture()
    for failure in ['logged-out', 'untagged']:
        machine.succeed("systemctl stop tailscale-service-fixture; touch /run/" + failure)
        machine.fail("systemctl start tailscale-service-fixture")
        machine.succeed("jq -e '.AdvertiseServices | index(\"svc:fixture\") == null' /var/lib/service-fixture/prefs.json")
        machine.succeed("rm /run/" + failure + "; systemctl restart tailscale-service-fixture")
        check_fixture()
    machine.succeed("systemctl stop tailscale-service-fixture; touch /run/prefs-fail")
    machine.fail("systemctl start tailscale-service-fixture")
    machine.succeed("jq -e '.AdvertiseServices | index(\"svc:fixture\") == null' /var/lib/service-fixture/prefs.json")
    machine.succeed("rm /run/prefs-fail")
    machine.wait_until_succeeds("systemctl is-active --quiet tailscale-service-fixture", timeout=30)
    check_fixture()
    machine.succeed("systemctl stop tailscale-service-fixture; tailscale serve clear svc:fixture")
    machine.succeed("jq -e '.Services | has(\"svc:fixture\") | not' /var/lib/service-fixture/config.json")
    check_preserved()
  '';
}
