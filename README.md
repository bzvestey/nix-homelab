# NixOS Homelab Fleet

Declarative NixOS configurations for the five-host homelab fleet.

## Validation

```console
nix flake check --show-trace
```

## CI scope and image builds

Batch locally validated preparation changes into one push per meaningful
milestone; do not weaken signed deployment policy to avoid CI latency.
The shared `.github/scripts/ci-scope.py` selector uses the entire push
`before...after` range or the paginated PR changed-files list (including old
rename paths). A new branch compares against the repository default branch
when available. Missing history, API errors, truncated results and unknown
paths conservatively select all checks, closures and images.

| Changes | Architecture checks / closures | Automatic images |
| --- | --- | --- |
| `docs/`, README, AGENTS only | None | None |
| `hosts/<node>/`, `secrets/hosts/<node>/` | Node architecture / node closure | None |
| Shared modules, packages, lib, checks, flake inputs, secrets policy, CI | Both / all five | None |
| Framework installer files | Both / all five | All three Framework images |
| Pi installer or Pi hardware module | Both / all five | Both Pi images |
| Shared installer files | Both / all five | All images |
| Unknown paths or incomplete discovery | Both / all five | All images |

Selected architectures retain their full existing check commands and KVM
requirements. Empty selections skip build jobs, not an assertion that an
image is fresh or installation-ready. Normal application and secret changes
do not request new installer images. Existing image packaging, provenance,
warnings and artifact retention are unchanged.

For an explicitly needed image, open **Actions → images → Run workflow**,
choose the revision and `host`: `all` or one canonical ID (`hl-node-00`
through `hl-node-04`). One host selects only its image, regardless of changed
paths; `all` selects all five. This builds artifacts only, not deployment.

Local selector and packaging fixtures:

```console
python3 .github/tests/ci-scope.py
bash .github/tests/framework-packaging.sh
actionlint .github/workflows/checks.yml .github/workflows/images.yml
```
