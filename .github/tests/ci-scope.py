import importlib.util
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/ci-scope.py'

# Independent observable contract: never obtain expected rows from the selector.
ARM = {'architecture': 'aarch64-linux', 'runner': 'ubuntu-24.04-arm'}
X86 = {'architecture': 'x86_64-linux', 'runner': 'ubuntu-24.04'}
CLOSURES = [
    {'host': 'hl-node-00', 'runner': 'ubuntu-24.04-arm'},
    {'host': 'hl-node-01', 'runner': 'ubuntu-24.04-arm'},
    {'host': 'hl-node-02', 'runner': 'ubuntu-24.04'},
    {'host': 'hl-node-03', 'runner': 'ubuntu-24.04'},
    {'host': 'hl-node-04', 'runner': 'ubuntu-24.04'},
]
FRAMEWORK = [{'host': 'hl-node-02'}, {'host': 'hl-node-03'}, {'host': 'hl-node-04'}]
PI = [{'host': 'hl-node-00'}, {'host': 'hl-node-01'}]


def expected(checks=(), closures=(), framework=(), pi=()):
    return {key: {'include': list(rows)} for key, rows in (
        ('checks', checks), ('closures', closures),
        ('framework_images', framework), ('pi_images', pi))}


EMPTY = expected()
SHARED = expected([ARM, X86], CLOSURES)
FULL = expected([ARM, X86], CLOSURES, FRAMEWORK, PI)
HOST02 = expected([X86], [CLOSURES[2]])


class ScopeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location('scope', SCRIPT)
        cls.scope = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.scope)

    def test_selection(self):
        cases = [
            (['docs/runbook.md'], EMPTY),
            (['hosts/hl-node-02/default.nix'], HOST02),
            (['secrets/hosts/hl-node-01/bootstrap.yaml'], expected([ARM], [CLOSURES[1]])),
            (['hosts/hl-node-02/default.nix', 'README.md'], HOST02),
            (['modules/fleet/base.nix'], SHARED),
            (['flake.lock'], SHARED),
            (['.github/workflows/checks.yml'], SHARED),
            (['installers/framework-iso.nix'], expected([ARM, X86], CLOSURES, FRAMEWORK)),
            (['installers/rpi-image.nix'], expected([ARM, X86], CLOSURES, pi=PI)),
            (['modules/hardware/raspberry-pi-5.nix'], expected([ARM, X86], CLOSURES, pi=PI)),
            (['installers/common.nix'], FULL),
            (['surprise'], FULL),
        ]
        for paths, contract in cases:
            with self.subTest(paths=paths):
                self.assertEqual(self.scope.select_scope(paths), contract)
        self.assertEqual(self.scope.select_scope([], False), FULL)

    def discover(self, event, responses):
        calls = []
        def get(path):
            calls.append(path)
            response = responses[len(calls) - 1]
            if isinstance(response, Exception):
                raise response
            return response
        result = self.scope.discover(event, get)
        return result, calls

    def test_push_complete_range_and_rename(self):
        event = {'before': 'old', 'after': 'new'}
        (paths, complete), calls = self.discover(event, [{
            'status': 'ahead', 'total_commits': 2, 'commits': [{}, {}],
            'files': [{'filename': 'docs/new.md', 'previous_filename': 'hosts/hl-node-02/default.nix', 'status': 'renamed'},
                      {'filename': 'hosts/hl-node-01/default.nix', 'status': 'removed'}]}])
        self.assertEqual(calls, ['/compare/old...new'])
        self.assertTrue(complete)
        self.assertEqual(self.scope.select_scope(paths), expected([ARM, X86], CLOSURES[1:3]))

    def test_initial_branch(self):
        (paths, complete), calls = self.discover({'before': '0' * 40, 'after': 'new', 'repository': {'default_branch': 'main'}},
            [{'status': 'ahead', 'total_commits': 1, 'commits': [{}], 'files': [{'filename': 'hosts/hl-node-02/default.nix'}]}])
        self.assertEqual(calls, ['/compare/main...new'])
        self.assertTrue(complete)
        self.assertEqual(self.scope.select_scope(paths), HOST02)

    def test_initial_repository_has_no_baseline(self):
        (paths, complete), calls = self.discover(
            {'before': '0' * 40, 'after': 'new', 'ref': 'refs/heads/main', 'repository': {'default_branch': 'main'}},
            [{'status': 'identical', 'total_commits': 0, 'commits': [], 'files': []}])
        self.assertFalse(complete)
        self.assertEqual(calls, [])

    def test_incomplete_comparisons(self):
        for response in [OSError('private error'), {},
                         {'status': 'diverged', 'total_commits': 1, 'commits': [{}], 'files': []},
                         {'status': 'behind', 'total_commits': 0, 'commits': [], 'files': []},
                         {'status': 'ahead', 'total_commits': 251, 'commits': [{}] * 250, 'files': []},
                         {'status': 'ahead', 'total_commits': 1, 'commits': [{}], 'files': [{'filename': 'README.md'}] * 300}]:
            (paths, complete), _ = self.discover({'before': 'old', 'after': 'new'}, [response])
            self.assertFalse(complete)
            self.assertEqual(self.scope.select_scope(paths, complete), FULL)
        self.assertFalse(self.scope.discover({'before': '0' * 40, 'after': 'new'}, lambda _: {})[1])

    def test_pr_pagination_and_counts(self):
        event = {'pull_request': {'number': 7, 'changed_files': 101}}
        page = [{'filename': f'docs/{i}.md'} for i in range(100)]
        (paths, complete), calls = self.discover(event, [page, [{'filename': 'docs/new.md', 'previous_filename': 'hosts/hl-node-00/default.nix'}]])
        self.assertTrue(complete)
        self.assertEqual(calls, ['/pulls/7/files?per_page=100&page=1', '/pulls/7/files?per_page=100&page=2'])
        self.assertIn('hosts/hl-node-00/default.nix', paths)
        for count, responses in [(101, [page, []]), (1, [page]), (3000, []), (3001, []),
                                 (100, [page, [{'filename': 'hosts/hl-node-01/default.nix'}]])]:
            (paths, complete), _ = self.discover({'pull_request': {'number': 7, 'changed_files': count}}, responses)
            self.assertFalse(complete)
        self.assertTrue(self.discover({'pull_request': {'number': 7, 'changed_files': 100}}, [page, []])[0][1])

    def test_duplicate_files_are_incomplete(self):
        (paths, complete), _ = self.discover({'pull_request': {'number': 7, 'changed_files': 2}},
            [[{'filename': 'README.md'}, {'filename': 'README.md'}]])
        self.assertFalse(complete)

    def test_real_cli_automatic_http_boundary(self):
        # Real CLI, JSON serialization and REST client; only the HTTP peer is fake.
        cases = [
            ({'before': 'old', 'after': 'new'}, 200,
             {'status': 'ahead', 'total_commits': 2, 'commits': [{'sha': 'first'}, {'sha': 'new'}],
              'files': [{'filename': 'hosts/hl-node-02/default.nix'}, {'filename': 'README.md'}]},
             HOST02),
            ({'before': 'old', 'after': 'new'}, 200,
             {'status': 'ahead', 'total_commits': 1, 'commits': [{}], 'files': [{'filename': 'README.md'}]},
             EMPTY),
            ({'before': 'old', 'after': 'new'}, 404, {'message': 'unreachable'},
             FULL),
            ({'before': 'old', 'after': 'new'}, 200, 'truncated', FULL),
        ]
        for path, contract in [
            ('secrets/hosts/hl-node-01/bootstrap.yaml', expected([ARM], [CLOSURES[1]])),
            ('modules/fleet/base.nix', SHARED),
            ('surprise', FULL),
            ('installers/framework-iso.nix', expected([ARM, X86], CLOSURES, FRAMEWORK)),
            ('installers/rpi-image.nix', expected([ARM, X86], CLOSURES, pi=PI)),
        ]:
            cases.append(({'before': 'old', 'after': 'new'}, 200,
                          {'status': 'ahead', 'total_commits': 1, 'commits': [{}],
                           'files': [{'filename': path}]}, contract))
        for event_data, status, response, contract in cases:
            requests = []
            class Handler(BaseHTTPRequestHandler):
                def do_GET(self):
                    requests.append((self.path, self.headers.get('Authorization')))
                    self.send_response(status)
                    if response == 'truncated':
                        self.send_header('Content-Length', '1000')
                    self.end_headers()
                    self.wfile.write(b'{"files": []}' if response == 'truncated' else json.dumps(response).encode())
                    self.close_connection = True
                def log_message(self, *_):
                    pass
            with ThreadingHTTPServer(('127.0.0.1', 0), Handler) as server, tempfile.TemporaryDirectory() as tmp:
                thread = threading.Thread(target=server.serve_forever, daemon=True)
                thread.start()
                event, output = Path(tmp) / 'event.json', Path(tmp) / 'output'
                event.write_text(json.dumps(event_data))
                env = {**os.environ, 'GITHUB_EVENT_NAME': 'push', 'GITHUB_REPOSITORY': 'owner/fleet',
                       'GITHUB_API_URL': f'http://127.0.0.1:{server.server_port}', 'GITHUB_TOKEN': 'fixture-token'}
                try:
                    process = subprocess.run([sys.executable, str(SCRIPT), '--event', str(event), '--output', str(output)],
                                             env=env, capture_output=True, text=True)
                finally:
                    server.shutdown()
                    thread.join()
                self.assertEqual(process.returncode, 0, process.stderr)
                values = dict(line.split('=', 1) for line in output.read_text().splitlines())
                self.assertEqual(set(values), set(contract) | {'has_' + key for key in contract})
                for key, matrix in contract.items():
                    self.assertEqual(json.loads(values[key]), matrix)
                    self.assertEqual(values['has_' + key], str(bool(matrix['include'])).lower())
                self.assertEqual(requests, [('/repos/owner/fleet/compare/old...new', 'Bearer fixture-token')])
                self.assertNotIn('fixture-token', process.stdout + process.stderr + output.read_text())

    def test_real_cli_manual_outputs(self):
        with tempfile.TemporaryDirectory() as tmp:
            event, output = Path(tmp) / 'event.json', Path(tmp) / 'output'
            contracts = {
                'all': expected(framework=FRAMEWORK, pi=PI),
                'hl-node-00': expected(pi=[{'host': 'hl-node-00'}]),
                'hl-node-01': expected(pi=[{'host': 'hl-node-01'}]),
                'hl-node-02': expected(framework=[{'host': 'hl-node-02'}]),
                'hl-node-03': expected(framework=[{'host': 'hl-node-03'}]),
                'hl-node-04': expected(framework=[{'host': 'hl-node-04'}]),
            }
            for host in [*contracts, 'invalid']:
                event.write_text(json.dumps({'inputs': {'host': host}}))
                output.write_text('')
                process = subprocess.run([sys.executable, str(SCRIPT), '--event', str(event), '--output', str(output)],
                                         env={**os.environ, 'GITHUB_EVENT_NAME': 'workflow_dispatch'}, capture_output=True, text=True)
                if host == 'invalid':
                    self.assertNotEqual(process.returncode, 0)
                    self.assertEqual(output.read_text(), '')
                    continue
                self.assertEqual(process.returncode, 0, process.stderr)
                values = dict(line.split('=', 1) for line in output.read_text().splitlines())
                self.assertEqual({key: json.loads(values[key]) for key in contracts[host]}, contracts[host])
                self.assertEqual(set(values), set(contracts[host]) | {'has_' + key for key in contracts[host]})
                for key in ['checks', 'closures', 'framework_images', 'pi_images']:
                    self.assertEqual(values['has_' + key], str(bool(contracts[host][key]['include'])).lower())


if __name__ == '__main__':
    unittest.main()
