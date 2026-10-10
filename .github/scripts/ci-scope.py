#!/usr/bin/env python3
"""Conservative fleet CI selection; HTTP failures never clear validation."""
import argparse
from http.client import HTTPException
import json
import os
from urllib.parse import quote
from urllib.request import Request, urlopen

PI = ('hl-node-00', 'hl-node-01')
FRAMEWORK = ('hl-node-02', 'hl-node-03', 'hl-node-04')
HOSTS = {h: 'aarch64-linux' if h in PI else 'x86_64-linux' for h in (*PI, *FRAMEWORK)}
RUNNERS = {'aarch64-linux': 'ubuntu-24.04-arm', 'x86_64-linux': 'ubuntu-24.04'}


def matrices(hosts, framework=(), pi=()):
    def images(selected):
        return {'include': [{'host': h} for h in sorted(selected)]}
    return {
        'checks': {'include': [{'architecture': a, 'runner': RUNNERS[a]}
                               for a in sorted({HOSTS[h] for h in hosts})]},
        'closures': {'include': [{'host': h, 'runner': RUNNERS[HOSTS[h]]} for h in sorted(hosts)]},
        'framework_images': images(framework), 'pi_images': images(pi),
    }


def select_scope(paths: list[str], complete: bool = True) -> dict:
    hosts, framework, pi = set(), set(), set()
    if not complete:
        return matrices(HOSTS, FRAMEWORK, PI)
    for path in paths:
        if path in ('README.md', 'AGENTS.md') or path.startswith('docs/'):
            continue
        host = next((h for h in HOSTS if path.startswith((f'hosts/{h}/', f'secrets/hosts/{h}/'))), None)
        if host:
            hosts.add(host)
        elif path.startswith('installers/framework-'):
            hosts.update(HOSTS)
            framework.update(FRAMEWORK)
        elif path in ('installers/rpi-image.nix', 'modules/hardware/raspberry-pi-5.nix'):
            hosts.update(HOSTS)
            pi.update(PI)
        elif path.startswith('installers/'):
            hosts.update(HOSTS)
            framework.update(FRAMEWORK)
            pi.update(PI)
        elif path in ('flake.nix', 'flake.lock', '.sops.yaml', '.gitignore') or path.startswith(
                ('modules/fleet/', 'modules/roles/', 'modules/services/', 'packages/', 'lib/', 'checks/', '.github/', 'secrets/pi-connectors/')):
            hosts.update(HOSTS)
        else:
            return matrices(HOSTS, FRAMEWORK, PI)
    return matrices(hosts, framework, pi)


def discover(event, get):
    """get is the sole HTTP boundary. Never trust capped or inconsistent data."""
    try:
        if 'pull_request' in event:
            pr = event['pull_request']
            count = pr['changed_files']
            # GitHub caps this endpoint at 3000 files; equality is ambiguous.
            if not isinstance(count, int) or not 0 <= count < 3000:
                return [], False
            files = []
            # Fetch a terminal short page even when the count is a multiple
            # of 100, so a stale count cannot silently hide the next page.
            for page in range(1, count // 100 + 2):
                batch = get(f'/pulls/{int(pr["number"])}/files?per_page=100&page={page}')
                expected = min(100, max(0, count - len(files)))
                if not isinstance(batch, list) or len(batch) != expected:
                    return [], False
                files.extend(batch)
        else:
            before, after = event.get('before'), event.get('after')
            if before == '0' * 40:
                before = event.get('repository', {}).get('default_branch')
                # The first push to the default branch cannot compare against
                # itself: that would incorrectly classify a new repo as empty.
                if event.get('ref') == f'refs/heads/{before}':
                    return [], False
            if not before or not after or after == '0' * 40:
                return [], False
            comparison = get(f'/compare/{quote(before, safe="")}...{quote(after, safe="")}')
            files = comparison['files']
            if (comparison['status'] not in ('ahead', 'identical')
                    or comparison['total_commits'] != len(comparison['commits'])
                    or not isinstance(files, list) or len(files) >= 300):
                return [], False
        paths, filenames = [], set()
        for file in files:
            filename = file['filename']
            if filename in filenames:
                return [], False
            filenames.add(filename)
            paths.append(filename)
            if 'previous_filename' in file:
                paths.append(file['previous_filename'])
        if not all(isinstance(p, str) and p for p in paths):
            return [], False
        return sorted(set(paths)), True
    except (OSError, HTTPException, ValueError, KeyError, TypeError):
        return [], False


def github_get(path):
    repository = os.environ['GITHUB_REPOSITORY']
    api = os.environ.get('GITHUB_API_URL', 'https://api.github.com')
    request = Request(f'{api}/repos/{repository}{path}', headers={
        'Authorization': 'Bearer ' + os.environ['GITHUB_TOKEN'],
        'Accept': 'application/vnd.github+json', 'X-GitHub-Api-Version': '2022-11-28',
    })
    with urlopen(request, timeout=30) as response:
        return json.load(response)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--event', required=True)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    with open(args.event) as stream:
        event = json.load(stream)
    if os.environ.get('GITHUB_EVENT_NAME') == 'workflow_dispatch':
        host = event.get('inputs', {}).get('host', 'all')
        if host != 'all' and host not in HOSTS:
            parser.error('invalid image host')
        selected = HOSTS if host == 'all' else [host]
        result = matrices([], set(selected) & set(FRAMEWORK), set(selected) & set(PI))
    else:
        result = select_scope(*discover(event, github_get))
    with open(args.output, 'a') as stream:
        for key, matrix in result.items():
            stream.write(f'{key}={json.dumps(matrix, separators=(",", ":"))}\n')
            stream.write(f'has_{key}={str(bool(matrix["include"])).lower()}\n')


if __name__ == '__main__':
    main()
