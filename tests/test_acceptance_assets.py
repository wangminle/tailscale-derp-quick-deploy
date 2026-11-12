"""真实集成入口的本地资产检查，不替代 VM/Tailnet 实跑。"""
import importlib.util
import json
import pathlib
import re
import subprocess
import tempfile
import threading
import unittest
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]


class AssetsTests(unittest.TestCase):
    def test_fixed_matrix_runs_root_evidence(self):
        text = (ROOT / '.github/workflows/tests.yml').read_text().split('  bash_fixed_matrix:', 1)[1].split('  systemd_vm:', 1)[0]
        self.assertIn('sudo bash tests/test_s2_evidence.sh', text)
        self.assertIn('sudo bash tests/test_c_stage.sh test_root_probe_path_trust test_bug072_root_rejects_untrusted_state_ancestors', text)

    def test_vm_cleanup_includes_private_key_archive(self):
        text = (ROOT / 'tests/test_systemd_integration.sh').read_text()
        cleanup = text.split('cleanup() {', 1)[1].split('trap cleanup EXIT', 1)[0]
        self.assertIn('rm -rf /etc/systemd/system/derper.service.certs-archive', cleanup)
        self.assertIn('! -e /etc/systemd/system/derper.service.certs-archive', cleanup)
        self.assertIn('-e /etc/systemd/system/derper.service.certs-archive', text.split('ROOT_DIR=', 1)[0])

    def test_vm_requests_c_d_and_preserves_artifacts(self):
        text = (ROOT / '.github/workflows/tests.yml').read_text().split('  systemd_vm:', 1)[1]
        self.assertIn('DERPER_INTEGRATION_C=1 DERPER_INTEGRATION_D=1', text)
        self.assertIn('actions/upload-artifact@v4', text)
        self.assertIn('if: always()', text)
        self.assertIn('cleanup.txt', text)


class PolicyFixtureTests(unittest.TestCase):
    def setUp(self):
        path = ROOT / 'tests/fixtures/policy_api.py'
        spec = importlib.util.spec_from_file_location('policy_fixture', path)
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.tmp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.tmp.name)
        (self.root / 'policy.json').write_text('{"derpMap": {"Regions": {}}}')
        self.server = self.module.make_server(self.root)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.url = 'http://127.0.0.1:' + str(self.server.server_port)

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.tmp.cleanup()

    def request(self, path, data=None, headers=None):
        req = urllib.request.Request(self.url + path, data, headers or {})
        return urllib.request.urlopen(req, timeout=2)

    def test_oauth_and_revocation(self):
        with self.request('/api/v2/oauth/token', b'grant_type=client_credentials') as response:
            self.assertEqual(json.load(response)['scope'], 'policy_file')
        (self.root / 'deny').touch()
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self.request('/api/v2/oauth/token', b'grant_type=client_credentials')
        self.assertEqual(caught.exception.code, 403)

    def test_etag_conflict_never_overwrites(self):
        before = (self.root / 'policy.json').read_bytes()
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self.request('/api/v2/tailnet/fixture.test/acl', b'{}', {'If-Match': 'stale'})
        self.assertEqual(caught.exception.code, 412)
        self.assertEqual((self.root / 'policy.json').read_bytes(), before)

    def test_real_http_read_validate_conditional_write(self):
        endpoint = '/api/v2/tailnet/fixture.test/acl'
        with self.request(endpoint) as response:
            etag = response.headers['ETag']
        with self.request(endpoint + '/validate', b'{}') as response:
            self.assertEqual(response.status, 200)
        with self.request(endpoint, b'{"new":1}', {'If-Match': etag}) as response:
            self.assertEqual(response.status, 200)
        self.assertEqual(json.loads((self.root / 'policy.json').read_text()), {'new': 1})
        self.assertEqual((self.root / 'writes').read_text(), '1')


if __name__ == '__main__': unittest.main()
