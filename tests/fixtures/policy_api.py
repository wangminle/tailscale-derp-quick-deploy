#!/usr/bin/env python3
"""仅供一次性 VM 的本地 HTTP fixture；不连接 Tailscale，不证明真实 API 可写。"""
import argparse
import hashlib
import http.server
import json
import os
import pathlib
import tempfile


def make_server(root):
    root = pathlib.Path(root)
    policy = root / 'policy.json'

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass  # 不记录请求正文/Authorization。

        def reply(self, status, body, etag=None):
            self.send_response(status)
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Content-Type', 'application/json')
            if etag:
                self.send_header('ETag', etag)
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if (root / 'deny').exists():
                self.reply(403, b'{}')
            elif self.path == '/api/v2/tailnet/fixture.test/acl':
                body = policy.read_bytes()
                self.reply(200, body, '"' + hashlib.sha256(body).hexdigest() + '"')
            else:
                self.reply(404, b'{}')

        def do_POST(self):
            size = int(self.headers.get('Content-Length', 0))
            if size < 0 or size > 1024 * 1024:
                self.reply(413, b'{}')
                return
            body = self.rfile.read(size)
            if (root / 'deny').exists():
                self.reply(403, b'{}')
                return
            if self.path == '/api/v2/oauth/token':
                self.reply(200, b'{"access_token":"fixture-only","scope":"policy_file"}')
                return
            if self.path not in ('/api/v2/tailnet/fixture.test/acl', '/api/v2/tailnet/fixture.test/acl/validate'):
                self.reply(404, b'{}')
                return
            try:
                json.loads(body)
            except (ValueError, UnicodeError):
                self.reply(400, b'{}')
                return
            if self.path.endswith('/validate'):
                self.reply(200, b'{}')
                return
            etag = '"' + hashlib.sha256(policy.read_bytes()).hexdigest() + '"'
            if self.headers.get('If-Match') != etag:
                self.reply(412, b'{}')
                return
            fd, name = tempfile.mkstemp(dir=root)
            with os.fdopen(fd, 'wb') as output:
                output.write(body)
            os.replace(name, policy)
            counter = root / 'writes'
            counter.write_text(str(int(counter.read_text() if counter.exists() else '0') + 1))
            self.reply(200, body, '"' + hashlib.sha256(body).hexdigest() + '"')

    # 单线程串行处理读改写，ETag比较与写入之间不允许第二请求插入。
    return http.server.HTTPServer(('127.0.0.1', 0), Handler)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--state-dir', required=True)
    parser.add_argument('--port-file', required=True)
    args = parser.parse_args()
    server = make_server(args.state_dir)
    pathlib.Path(args.port_file).write_text(str(server.server_port))
    server.serve_forever()
