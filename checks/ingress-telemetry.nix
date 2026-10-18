{ pkgs }:
let
  inherit (pkgs) lib;
  evaluated = import (pkgs.path + "/nixos/lib/eval-config.nix") {
    inherit pkgs;
    system = pkgs.stdenv.hostPlatform.system;
    modules = [
      ../modules/fleet/ingress.nix
      ../modules/fleet/cloudflared.nix
      ../modules/fleet/tailscale-telemetry.nix
      ({ lib, ... }: {
        options.fleet.telemetry = {
          enable = lib.mkOption { default = true; };
          localPrometheusTargets = lib.mkOption {
            default = { };
            type = lib.types.attrsOf lib.types.str;
          };
        };
        config = {
          fleet.ingress = {
            enableTailscale = false;
            routes = [
              {
                hostname = "test.local";
                upstream = "http://127.0.0.1:18081";
                exposure = "public";
              }
            ];
          };
          fleet.cloudflared.enable = true;
          services.tailscale.enable = true;
        };
      })
    ];
  };
  cfg = evaluated.config;
  probes = import ../modules/fleet/public-probes.nix { inherit lib; };
  target = pkgs.writeText "probe-target.py" ''
    import http.server
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            code = int(self.path.strip("/")) if self.path != "/" else 200
            self.send_response(code)
            self.end_headers()
    http.server.ThreadingHTTPServer(("127.0.0.1", 18081), Handler).serve_forever()
  '';
in
assert cfg.fleet.telemetry.localPrometheusTargets.caddy or null == "127.0.0.1:2019";
assert cfg.fleet.telemetry.localPrometheusTargets.cloudflared or null == "127.0.0.1:20241";
pkgs.runCommand "ingress-telemetry"
  {
    nativeBuildInputs = [
      pkgs.caddy
      pkgs.curl
      pkgs.python3
    ];
  }
  ''
    export HOME=$TMPDIR
    caddy run --config ${cfg.services.caddy.configFile} --adapter caddyfile >caddy.log 2>&1 &
    trap 'kill $(jobs -pr) 2>/dev/null || true' EXIT
    for n in $(seq 1 100); do
      curl -fsS http://127.0.0.1:2019/metrics >metrics 2>/dev/null && break
      sleep .1
    done
    curl -s http://127.0.0.1:8080 -H 'Host: test.local' >/dev/null
    curl -fsS http://127.0.0.1:2019/metrics >metrics
    grep -q caddy_http_requests_total metrics
    ${pkgs.prometheus-blackbox-exporter}/bin/blackbox_exporter --config.file=${
      pkgs.writeText "probes.json" (builtins.toJSON { inherit (probes) modules; })
    } --web.listen-address=127.0.0.1:19115 >prober.log 2>&1 &
    python3 ${target} >http.log 2>&1 &
    for n in $(seq 1 100); do
      if curl -fsS 'http://127.0.0.1:19115/probe?module=public-http&target=http://127.0.0.1:18081/' >probe 2>/dev/null && grep -q '^probe_success 1' probe; then break; fi
      sleep .1
    done
    grep -q '^probe_success 1' probe
    for code in 401 403; do
      curl -fsS "http://127.0.0.1:19115/probe?module=public-http&target=http://127.0.0.1:18081/$code" >probe
      grep -q '^probe_success 1' probe
    done
    curl -fsS 'http://127.0.0.1:19115/probe?module=public-http&target=http://127.0.0.1:18081/500' >probe
    grep -q '^probe_success 0' probe
    curl -fsS 'http://127.0.0.1:19115/probe?module=public-http&target=http://127.0.0.1:18082/' >probe
    grep -q '^probe_success 0' probe
    export CREDENTIALS_DIRECTORY=$TMPDIR/credentials
    mkdir "$CREDENTIALS_DIRECTORY"
    echo '{"AccountTag":"fixture","TunnelID":"11111111-1111-1111-1111-111111111111","TunnelSecret":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}' > "$CREDENTIALS_DIRECTORY/tunnel.json"
    ${cfg.systemd.services.cloudflared-fleet.serviceConfig.ExecStart} >cloudflared.log 2>&1 &
    for n in $(seq 1 100); do
      curl -fsS http://127.0.0.1:20241/metrics >cloudflared.metrics 2>/dev/null && break
      sleep .1
    done
    grep '^cloudflared_tunnel_ha_connections ' cloudflared.metrics || { cat cloudflared.log; exit 1; }
    test -x ${cfg.systemd.services.tailscale-telemetry.serviceConfig.ExecStart}
    python3 ${../modules/fleet/tailscale-status.py} ${lib.getExe pkgs.tailscale} "$TMPDIR/failed-status.prom" native=/nonexistent/tailscaled.sock
    grep -q 'tailscale_status_collection_success{identity="native"} 0' "$TMPDIR/failed-status.prom"
    python3 ${./tailscale-telemetry.py} ${../modules/fleet/tailscale-status.py}
    echo 'PASS: real Caddy/cloudflared metrics; blackbox 200/401/403 up, 500/closed-port down; Tailscale valid/zero/offline/failure fixtures'
    touch $out
  ''
