{ lib }:
let
  routes = lib.filter (route: !(lib.hasInfix "*" route.hostname)) (
    import ../../lib/public-ingress-routes.nix
  );
  path =
    hostname:
    if hostname == "matrix.minastas.social" then
      "/_matrix/client/versions"
    else if hostname == "pds.minastas.social" then
      "/xrpc/_health"
    else
      "/";
in
{
  modules.public-http = {
    prober = "http";
    timeout = "10s";
    http = {
      preferred_ip_protocol = "ip4";
      # A protected service is available when it challenges anonymous clients.
      valid_status_codes = [
        200
        201
        202
        204
        301
        302
        303
        307
        308
        401
        403
      ];
    };
  };
  scrapeConfig = {
    job_name = "public-endpoints";
    metrics_path = "/probe";
    params.module = [ "public-http" ];
    static_configs = map (route: {
      targets = [ "https://${route.hostname}${path route.hostname}" ];
      labels.service = route.hostname;
    }) routes;
    relabel_configs = [
      {
        source_labels = [ "__address__" ];
        target_label = "__param_target";
      }
      {
        source_labels = [ "service" ];
        target_label = "instance";
      }
      {
        target_label = "__address__";
        replacement = "127.0.0.1:9115";
      }
    ];
  };
}
