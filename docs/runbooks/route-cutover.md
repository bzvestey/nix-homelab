# Route cutover

The repository prepares origins and two connectors but does not enroll nodes or mutate Cloudflare.

## Approval gates

1. Enroll each host in Tailscale with a preauthorized key rendered as `/run/secrets/tailscale-auth-key`; verify its existing inventory-approved MagicDNS name before enabling a private route.
2. Render the same Cloudflare named-tunnel credential JSON to `/run/secrets/cloudflared-tunnel.json` on both members of the `pi-connectors` sops recipient group.
3. Validate Caddy locally and validate the generated connector file with `cloudflared tunnel ingress validate` on each Pi.
4. Probe every hostname through each connector independently. Only then update Cloudflare tunnel routing/DNS in an approved maintenance window.

Missing credentials intentionally leave only the enrollment/connector unit skipped; origins and unrelated applications remain available.

## Rollback

Restore the previous Cloudflare route/DNS target, stop `cloudflared-fleet` on both Pis, and retain the prior origin service until probes and authentication succeed through the old path. For a private-route failure, disable the new route and restore the previous Tailscale endpoint; do not rotate or revoke old credentials until soak completes.
