"""适配器的协议/错误边界回归；替身不构成真实 H3 证据。"""
import importlib.util
import pathlib
import unittest
from unittest.mock import patch

path = pathlib.Path(__file__).resolve().parents[1] / 'scripts/h3_probe.py'
spec = importlib.util.spec_from_file_location('h3_probe', path)
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class ProbeTests(unittest.TestCase):
    def setUp(self):
        self.target = probe.Target(900, '203.0.113.10', 30399, 3478)
        self.node = {'HostName': '203.0.113.10', 'IPv4': '203.0.113.10',
                     'DERPPort': 30399, 'STUNPort': 3478, 'CertName': 'sha256-raw:' + 'a'*64}
        self.mapping = {'Regions': {'900': {'RegionID': 900, 'RegionCode': 'test', 'Nodes': [self.node]}}}
        self.status = {'BackendState': 'Running', 'Self': {'ID': 'one', 'TailscaleIPs': ['100.64.0.1']},
                       'Peer': {'key': {'ID': 'two', 'TailscaleIPs': ['100.64.0.2']}}}

    def test_matching_single_node(self):
        self.assertEqual(probe.match_region(self.mapping, self.target), self.node['CertName'])

    def test_numeric_hostname_without_explicit_address(self):
        del self.node['IPv4']
        self.assertEqual(probe.match_region(self.mapping, self.target), self.node['CertName'])

    def test_hostname_requires_exact_numeric_target(self):
        del self.node['IPv4']
        self.node['HostName'] = 'relay.example.test'
        with self.assertRaises(probe.Unverified): probe.match_region(self.mapping, self.target)

    def test_wrong_node_or_ports_unknown(self):
        for field, value in [('IPv4', '203.0.113.11'), ('DERPPort', 443), ('STUNPort', 1)]:
            with self.subTest(field=field):
                node = dict(self.node, **{field: value})
                self.mapping['Regions']['900']['Nodes'] = [node]
                with self.assertRaises(probe.Unverified): probe.match_region(self.mapping, self.target)

    def test_multiple_nodes_unknown(self):
        self.mapping['Regions']['900']['Nodes'].append(dict(self.node))
        with self.assertRaises(probe.Unverified): probe.match_region(self.mapping, self.target)

    def test_missing_pin_unknown(self):
        self.node['CertName'] = ''
        with self.assertRaises(probe.Unverified): probe.match_region(self.mapping, self.target)

    def test_actual_region_roundtrip(self):
        probe.check_ping({'DERPRegionID': 900, 'NodeIP': '100.64.0.2'}, self.target, '100.64.0.2')

    def test_direct_wrong_region_peer_or_peerrelay_unknown(self):
        for result in [ {'NodeIP': '100.64.0.2', 'Endpoint': '203.0.113.1:1'},
                        {'DERPRegionID': 1, 'NodeIP': '100.64.0.2'},
                        {'DERPRegionID': 900, 'NodeIP': '100.64.0.3'},
                        {'DERPRegionID': 900, 'NodeIP': '100.64.0.2', 'PeerRelay': 'other'} ]:
            with self.subTest(result=result):
                with self.assertRaises(probe.Unverified): probe.check_ping(result, self.target, '100.64.0.2')

    def test_ping_confirmed_error_failed(self):
        with self.assertRaises(probe.ProbeFailed): probe.check_ping({'Err': 'timeout'}, self.target, '100.64.0.2')

    def test_peer_must_be_distinct_registered_node(self):
        probe.check_peer(self.status, '100.64.0.2')
        for peer in ['100.64.0.1', '100.64.0.3']:
            with self.assertRaises(probe.Unverified): probe.check_peer(self.status, peer)

    def test_stun_transaction_and_mapped_address(self):
        import struct
        tx = b'abcdefghijkl'
        attr = struct.pack('!HHBBH4s', 0x0020, 8, 0, 1, 1234 ^ 0x2112, bytes([1^0x21, 2^0x12, 3^0xa4, 4^0x42]))
        packet = struct.pack('!HHI', 0x0101, len(attr), 0x2112a442) + tx + attr
        probe.validate_stun(packet, tx)
        for bad in [packet[:-1], packet[:8] + b'otherbadtxid' + packet[20:], b'', packet[:20]]:
            with self.subTest(bad=bad):
                with self.assertRaises(probe.ProbeFailed): probe.validate_stun(bad, tx)

    def test_pin_drift_is_unverified(self):
        with patch.object(probe, 'live_pin', return_value='sha256-raw:' + 'b'*64):
            with self.assertRaises(probe.Unverified): probe.check_pin(self.target, self.node['CertName'], 1)

    def test_success_report_whitelist(self):
        lines = probe.report(self.target, True, True).splitlines()
        self.assertEqual(len(lines), 8)
        self.assertIn('region_id=900', lines)
        self.assertIn('derp=ok', lines)
        self.assertIn('stun=ok', lines)

    def test_stun_wire_request_uses_tailscale_software_and_fingerprint(self):
        import socket, struct, threading, zlib
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as server:
            server.bind(('127.0.0.1', 0))
            server.settimeout(2)
            captured = []
            def respond():
                packet, addr = server.recvfrom(2048)
                captured.append(packet)
                attr = struct.pack('!HHBBH4s', 0x0001, 8, 0, 1, 1234, bytes([1, 2, 3, 4]))
                server.sendto(struct.pack('!HHI', 0x0101, len(attr), 0x2112a442) + packet[8:20] + attr, addr)
            thread = threading.Thread(target=respond)
            thread.start()
            probe.check_stun(probe.Target(900, '127.0.0.1', 443, server.getsockname()[1]), 2)
            thread.join()
            packet = captured[0]
            self.assertIn(b'tailnode', packet)
            self.assertEqual(struct.unpack('!I', packet[-4:])[0], zlib.crc32(packet[:-8]) ^ 0x5354554e)

    def test_run_end_to_end_contract_and_direct_route(self):
        import contextlib, io
        from types import SimpleNamespace
        args = SimpleNamespace(region_id=900, ip='203.0.113.10', derp_port=30399,
                               stun_port=3478, peer_ip='100.64.0.2', timeout=10, socket='unused')
        ping = {'DERPRegionID': 900, 'NodeIP': '100.64.0.2'}
        def api(_socket, method, endpoint, _timeout):
            if endpoint == 'status': return self.status
            if endpoint == 'derpmap': return self.mapping
            self.assertEqual(method, 'POST')
            self.assertIn('type=disco', endpoint)
            return ping
        for region, expected in [(900, 0), (0, 2), (1, 2)]:
            ping['DERPRegionID'] = region
            output = io.StringIO()
            with patch.object(probe, 'local_api', side_effect=api), patch.object(probe, 'check_pin'), patch.object(probe, 'check_stun'), contextlib.redirect_stdout(output):
                if expected == 0:
                    self.assertEqual(probe.run(args), 0)
                    self.assertIn('derp=ok', output.getvalue())
                else:
                    with self.assertRaises(probe.Unverified): probe.run(args)
                    self.assertEqual(output.getvalue(), '')

    def test_localapi_real_unix_http_transport(self):
        import http.server, socketserver, tempfile, threading
        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_args): pass
            def do_POST(self):
                self.send_response(200); self.end_headers()
                self.wfile.write(b'{"DERPRegionID":900}')
        class Server(socketserver.UnixStreamServer): pass
        with tempfile.TemporaryDirectory() as folder:
            path = str(pathlib.Path(folder) / 'api.sock')
            with Server(path, Handler) as server:
                thread = threading.Thread(target=server.handle_request)
                thread.start()
                self.assertEqual(probe.local_api(path, 'POST', 'ping?ip=100.64.0.2&type=disco', 2)['DERPRegionID'], 900)
                thread.join()


if __name__ == '__main__': unittest.main()
