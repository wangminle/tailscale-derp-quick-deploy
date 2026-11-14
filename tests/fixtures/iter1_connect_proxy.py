#!/usr/bin/env python3
import argparse
import socket
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class ConnectProxy(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, handler, log_path):
        super().__init__(address, handler)
        self.log_path = log_path
        self.log_lock = threading.Lock()

    def record(self, action, target):
        with self.log_lock:
            with open(self.log_path, "a", encoding="utf-8") as handle:
                handle.write(f"{action} {target}\n")
                handle.flush()


class Handler(BaseHTTPRequestHandler):
    def do_CONNECT(self):
        target = self.path
        host = target.rsplit(":", 1)[0].strip("[]").lower()
        if host == "go.dev" or host.endswith(".go.dev"):
            self.server.record("blocked", target)
            self.send_error(503, "go.dev blocked by iter1 acceptance fixture")
            return
        try:
            upstream = socket.create_connection((host, int(target.rsplit(":", 1)[1])), timeout=15)
        except (OSError, ValueError):
            self.server.record("connect_failed", target)
            self.send_error(502, "upstream connection failed")
            return
        self.server.record("allowed", target)
        self.send_response(200, "Connection Established")
        self.end_headers()
        self.connection.setblocking(True)
        upstream.setblocking(True)

        def relay(source, destination):
            try:
                while True:
                    data = source.recv(65536)
                    if not data:
                        break
                    destination.sendall(data)
            except OSError:
                pass
            finally:
                try:
                    destination.shutdown(socket.SHUT_WR)
                except OSError:
                    pass

        downstream = threading.Thread(target=relay, args=(upstream, self.connection))
        downstream.daemon = True
        downstream.start()
        relay(self.connection, upstream)
        downstream.join(timeout=5)
        upstream.close()
        self.close_connection = True

    def log_message(self, format, *args):
        return


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port-file", required=True)
    parser.add_argument("--log", required=True)
    args = parser.parse_args()
    server = ConnectProxy(("127.0.0.1", 0), Handler, args.log)
    with open(args.port_file, "w", encoding="utf-8") as handle:
        handle.write(str(server.server_address[1]))
    try:
        server.serve_forever()
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
