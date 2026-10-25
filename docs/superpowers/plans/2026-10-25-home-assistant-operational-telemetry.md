# Home Assistant Operational Telemetry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add private, operational-only HAOS and app metrics to hl-node-00 with provisioned dashboards and explicit coverage/failure states.

**Architecture:** A protected local HAOS app polls Supervisor and allowlisted native application exporters. Authenticated Prometheus scrapes on the Pi consume bounded snapshots, never Supervisor credentials. No entity export, Docker socket, or general-purpose proxy is introduced.

**Tech Stack:** Python 3, prometheus-client parser/exposition, HAOS local app packaging, NixOS Prometheus/Grafana, SOPS, unittest, promtool, NixOS VM checks.

**Spec:** `docs/superpowers/specs/2026-10-25-home-assistant-operational-telemetry-design.md`

## Global Constraints

- Operational metrics only; entity/sensor states, device identities, logs and traces are excluded.
- Preserve HAOS 18.3 / Core 2026.10.4 / Supervisor 2026.10.3 and installed app versions.
- Poll every 30 seconds; central scrape interval 60 seconds; timeouts shorter than that interval.
- Host is `homeassistant`, Tailscale address `100.75.116.65`; central node is hl-node-00.
- Proposed collector TCP port 9126 requires a live conflict check before installation.
- Keep Supervisor credentials on HAOS; protect every metrics path with a dedicated bearer token.
- Manager role is broader than read-only: document it; never enable Docker/Core API access or disable Protection mode.
- Separate collection jobs; no dimension-stripping OTLP path or duplicate ingestion.
- Use jj, jj workspaces if isolation is required, and signed commits when publication is authorized.
- Implementation approval does not itself authorize installations, service reconfiguration, publication, or deployment.
- Preserve unrelated work and the known unrelated telemetry-agent CI failure.

## Review Focus

1. Worker stalls while HTTP still responds: old snapshots must not appear healthy (Task 2).
2. Native metrics collapse after sensitive labels are removed: do not silently duplicate or sum unrelated series (Task 3).
3. Stopped/removed apps and API errors must not appear as zero resource use or healthy services (Tasks 2 and 4).
4. Native redirects must never forward credentials to another host (Task 3).
5. Metric labels/help text can contain sensitive data even when metric names look safe (Task 3).

## File ownership

- `packages/home-assistant-telemetry/collector.py`: polling, validated operational snapshots, bounded authenticated HTTP endpoints and native metric filtering.
- `packages/home-assistant-telemetry/{config.yaml,Dockerfile,requirements.txt,run.sh}`: HAOS local app packaging and startup; no app configuration secrets committed.
- `checks/home-assistant-telemetry.py`: external HTTP contracts using local Supervisor/native fixtures.
- `checks/home-assistant-telemetry.nix`: collector test runner and central authenticated scrape integration; keep fixtures in the test file unless separation is justified.
- `modules/fleet/home-assistant-telemetry.nix`: disabled-by-default central scrape options/configuration and source-health alerts.
- `hosts/hl-node-00/default.nix`: eventual host enablement and runtime SOPS secret declaration.
- `modules/roles/observability.nix`: module import and dashboard provisioning list.
- `dashboards/{home-assistant,home-assistant-apps,uptime-kuma}.json`: operational views.
- `checks/{dashboard-queries.py,evaluation.nix}`, `flake.nix`: extend existing query/evaluation/check registration.
- `docs/runbooks/home-assistant-telemetry.md`, `README.md`: coverage, private credential entry, installation, rollback and troubleshooting.

## Task 1: Lock the live source contracts and coverage

**Interfaces:** Produce a version-specific API/metric coverage table in the runbook. Later tasks implement only verified fields/families and clearly mark unsupported sources.

- [ ] Inspect the installed Supervisor-version source for GET inventory/info/stats paths, manager-role permissions, byte/CPU units and boot timestamp formats. Pin source references in the runbook; don't infer disk GB/GiB from display names.
- [ ] Read-only inspect port 9126 availability and each installed app's supported metrics endpoint/configuration: Kuma, Tailscale, Grafana, InfluxDB v1, Z-Wave JS UI, Matter Server, OTBR, Studio Code, both ESPHome builders, Get HACS and SSH. Do not open ports or restart apps during discovery.
- [ ] Write the coverage table with one row per app: baseline Supervisor metrics, verified native families, authentication method, required configuration/restart, or explicit unsupported/unavailable reason. Include Core and Supervisor runtime coverage separately.
- [ ] Inspect Kuma's authenticated metrics/API-key contract for 2.5.6 and determine its supported private key-entry workflow. Do not use an account password or browser session as a scrape credential.
- [ ] Produce sanitized example payloads for tests with asymmetric resource values and a deliberately sensitive field. Keep actual credentials and raw household data out of fixtures and artifacts.
- [ ] Verify the table distinguishes observed availability from planned configuration; stop for a design correction only if required coverage cannot fit the approved privilege boundary.

## Task 2: Implement and package the operational Supervisor collector

**Interfaces:** Executable `python collector.py`; uses `SUPERVISOR_TOKEN` from the HAOS environment and `/data/options.json` for configuration. External contract is authenticated `GET /metrics` on port 9126; no management endpoints. Tests launch the process against a loopback Supervisor fixture through a test-only environment configuration for its upstream address.

Metric prefix `haos_`; resource labels `component` (`core`, `supervisor`, or `app`) and `app` (slug for apps). Inventory info may add display name/version/latest version; state uses a separate bounded state label. Poll results export `haos_collection_success`, `haos_collection_last_success_timestamp_seconds` and duration by fixed source. Use explicit resource family names ending in `_bytes`, `_seconds_total`, `_bytes_total`, or `_percent` according to the verified source unit/type. Avoid custom types/classes unless needed to own snapshot lifecycle.

- [ ] Add HTTP contract tests in `checks/home-assistant-telemetry.py`: correct bearer returns 200; missing/wrong bearer returns 401; unknown path returns 404 after authentication; non-GET never changes upstream state. Request logs must contain no Authorization values or upstream response bodies.
- [ ] Add a resource contract using two apps with different memory and network values, Core and Supervisor, plus host disk/boot/version data. Assert exact independent expected unit conversions; CPU above 100 stays above 100 if the source contract allows it. Inject options/token/entity fields and assert they never appear.
- [ ] Add lifecycle/failure tests: stopped utility retains inventory without usage; removed app disappears; one app timeout leaves another's fresh data intact; inventory failure does not report zero apps; malformed required data reports failure rather than success. An absent optional field stays absent.
- [ ] Add a clock-controlled stalled-worker case: retain source failure/freshness metadata but omit operational samples once a snapshot is 90 seconds old. Test 89 seconds and exactly 90 seconds. An exception in a poll cannot leave an indefinitely fresh-looking success indicator.
- [ ] Run the new tests before implementation and confirm failure because collector behavior is missing, not because the fixture cannot start.
- [ ] Implement atomic per-source snapshots, 30-second polling, 5-second upstream timeout, at most four concurrent requests and a 1 MiB per-response limit. Disable redirects for credential-bearing upstream requests. Serve only explicit fields, correct Prometheus types and bounded process metrics; no environment/configuration export.
- [ ] Package the collector as a protected HAOS local app, aarch64 supported, `hassio_api: true`, manager role, Core/Docker APIs off, no host privileges/mounts. Pin the build base/dependencies; fail startup on absent/empty metrics token instead of enabling anonymous access. Read secrets only from local configuration/private files.
- [ ] Run the HTTP contract suite with pinned `prometheus-client` available and validate output with `promtool check metrics`. Build the app image on ARM64 using the normal container build tooling without installing it into live Supervisor. Verify no credentials entered the build context/image.

## Task 3: Add privacy-bounded native application metrics

**Interfaces:** Configured local targets produce distinct authenticated `GET /metrics/kuma`, `/metrics/grafana`, `/metrics/influxdb` and other source paths only for sources verified in Task 1. `/metrics` includes a coverage/status inventory for configured, disabled, unsupported and failing native sources. Native source snapshots use Task 2's polling/freshness contract.

- [ ] Add fixtures for the verified Kuma families: `monitor_status`, `monitor_response_time`, `monitor_uptime_ratio`, `monitor_response_time_seconds`, `monitor_cert_days_remaining`, `monitor_cert_is_valid`. Allow only monitor ID/name/type plus `window` where present. Use canned HELP text rather than reflecting arbitrary upstream text.
- [ ] Add privacy tests containing sensor families, secrets in arbitrary labels/help text, tags such as `Productivity`, URLs and device identifiers. Assert excluded content is absent from the HTTP response, not just removed later by Prometheus.
- [ ] Add collision tests: series differing only in removed labels may collapse to one only when their values agree; conflicting values reject the affected family and report a collection/filter failure, never sum or arbitrarily select. If required identity labels are absent, omit/reject rather than merging monitors.
- [ ] Add redirection/authentication tests: an upstream redirect fails collection and its bearer/basic credentials never reach the redirect destination; a 401 is source failure while the exporter itself remains reachable. Unsupported families remain absent.
- [ ] Run the new tests red, then implement metric-family and label allowlists using `prometheus-client` parsing/exposition rather than text substitutions. Preserve verified units and counter/histogram consistency; don't cache indefinitely or retain sensitive upstream text in logs.
- [ ] Add only the other native family sets verified in Task 1, applying the same privacy/collision rules. Document required credentials/settings as disabled until explicitly configured. Do not fabricate device/protocol coverage for apps without a safe endpoint.
- [ ] Run the full collector HTTP suite and `promtool check metrics` against each exposed source. Verify source failure and authenticated exporter reachability are distinguishable.

## Task 4: Integrate central collection, dashboards and query contracts

**Interfaces:** `fleet.observability.homeAssistant` owns `enable`, `target` (default `100.75.116.65:9126`), `tokenFile` (runtime `/run/...` path), verified enabled native source list, and explicitly required always-on app slugs. No alert assumes every installed app must run.

- [ ] Extend evaluation/check tests before implementation: jobs use runtime authorization files, `host_name=homeassistant`, 60-second interval, 10-second timeout and sample limits (platform 10000, each native source 20000). Disabled module adds no jobs/alerts/secrets. No Supervisor credential is accepted by module options.
- [ ] Add the central module and import it from the observability role. Configure job `homeassistant-platform` at `/metrics` and `homeassistant-<source>` at verified native paths. Register tests in `flake.nix` for both architectures using locked Python dependencies.
- [ ] Add an authenticated scrape integration test in `checks/home-assistant-telemetry.nix` following the NAS test pattern: real collector with fixture upstream, real Prometheus, runtime token; wrong token gives `up=0`, upstream failure gives `up=1` and source success 0 with absent usage. Include stopped and removed app controls.
- [ ] Create dashboards with UIDs `home-assistant`, `home-assistant-apps`, `uptime-kuma`; provision through the existing list. Keep actual units, percentage normalization, app/window selectors, coverage table and explicit unknown states. Use freshness `< 90` plus source success when showing snapshot data; don't use `or vector(0)` to hide absence.
- [ ] Extend `checks/dashboard-queries.py` with asymmetric app/monitor fixtures, job/host decoys, stopped apps, stale 89/90-second boundary, collection failure and counter-reset cases. Assert chart values and separation rather than JSON formatting. Preserve all existing query checks.
- [ ] Add alerts only for collector unavailability, stale critical collection, host disk pressure and explicitly required running apps, using existing alert conventions and a sustained interval to avoid restart noise. Test intentionally stopped Get HACS does not alert; unknown inventory is not healthy. Do not duplicate all Kuma notifications.
- [ ] Run targeted collector, query and VM checks, formatting/Statix/Deadnix, flake evaluation and the hl-node-00 closure build on ARM64. Run broader observability coverage because the shared role/flake registration changes.
- [ ] Render provisioned dashboards in an existing disposable/local Grafana environment with the actual queries and test data. Inspect default, selected app/monitor, stopped app and stale/missing states using screenshots under `.amp/in/artifacts/`; never publish raw sensitive captures. No production fixture injection.

## Task 5: Prepare private setup, staged rollout and end-to-end evidence

**Interfaces:** A runbook with exact local-app installation, secret entry, enablement and rollback steps. Delivery remains local until publication/install approval; this task does not imply permission to push or deploy.

- [ ] Complete `docs/runbooks/home-assistant-telemetry.md` and README links: coverage table, manager-role risk, authenticated LAN exposure, no router forwarding/Funnel, future sensor scope separate, Kuma tag/restart limitation and rollback. Include collector overhead and version compatibility expectations.
- [ ] Prepare hl-node-00 runtime secret declaration and enablement diff without plaintext values. Keep live host enablement disabled until the collector and encrypted token are ready; do not leave an enabled job referencing a missing secret in a published revision.
- [ ] Present the exact rollout actions for approval: copy/install/build/start only the new HAOS app, provide metrics-only native credentials through private local files, enable only approved native exporter settings/restarts, and publish signed Pi configuration once validation succeeds. Explicitly name any unrelated app restart required by a native exporter.
- [ ] After approval, generate a random shared scrape token locally, store it privately on HAOS and encrypted in `secrets/hosts/hl-node-00/telemetry.yaml`; declare mode 0400 owner prometheus. Preserve all existing secrets. No account password, Supervisor token or live credentials enter Git or logs. Remove temporary plaintext setup files.
- [ ] Verify port conflict and actual manager-role permissions, install/start the protected collector and verify anonymous/wrong-token requests fail from LAN and tailnet. Verify legitimate Pi tailnet scrape and document that LAN requests are authenticated but not automatically tailnet-encrypted.
- [ ] Validate all installed apps' inventory and all approved native sources for at least three 30-second polling cycles and two 60-second central scrapes. Confirm disabled/unsupported sources are clearly labeled, no excluded family/label appears, counters/units are correct and Kuma has no new label errors.
- [ ] Measure source count/sample count, collector CPU/RSS and scrape duration. Record actual limitations, tests, inspected dashboard screenshots, delivery revision and deployment state; do not describe local changes as deployed.
- [ ] Follow jj-only signed publication if authorized, without starting deployment workflows manually. If a PR is created, subscribe to comments/reviews and exact-head CI as required. Report the pre-existing unrelated CI failure separately from any new failure; don't weaken checks or silently repair it in this scope.

## Validation commands and execution boundary

During implementation, run the collector test suite with the flake's Python and
prometheus-client dependencies; register it as `checks.<system>.home-assistant-telemetry`
so the reproducible entry point is:

```sh
nix build --no-link .#checks.x86_64-linux.home-assistant-telemetry
nix build --no-link .#checks.x86_64-linux.dashboard-queries
nix fmt -- --check .
nix run .#statix -- check .
nix run .#deadnix -- --fail .
nix flake check --no-build --show-trace
```

Confirm existing check attribute names before running; retain repository naming
patterns if they differ. Build ARM checks/closure on an available authorized
native ARM executor, not by silently enabling new infrastructure. If no ARM
builder or UI rendering environment is available, report the concrete limitation
and finish all other validation rather than claiming it passed.

Keep the five implementation deliverables reviewable; do not create a commit per
test iteration. Commit/push only within the user's authorization and use jj, not
git staging/commit commands. Keep implementation, fixes and verification in the
same checkout; use subagents only for genuinely independent work or an explicitly
selected review/execution workflow.
