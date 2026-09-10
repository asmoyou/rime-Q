#!/usr/bin/env python3
"""Exercise the app's real download task against small local HTTP fixtures."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import subprocess
import sys
import threading
import time

PAYLOAD = b"q" * (128 * 1024)


class Handler(BaseHTTPRequestHandler):
    retries = 0
    def log_message(self, *_):
        pass

    def do_GET(self):
        status = 200
        data = PAYLOAD
        if self.path == "/corrupt":
            data = b"x" * len(PAYLOAD)
        elif self.path == "/missing":
            status, data = 404, b"missing"
        elif self.path == "/oversize":
            data += b"x" * 65536
        elif self.path == "/retry":
            Handler.retries += 1
            if Handler.retries == 1:
                status, data = 503, b"unavailable"
        self.send_response(status)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        try:
            for offset in range(0, len(data), 2048):
                self.wfile.write(data[offset:offset + 2048])
                self.wfile.flush()
                if self.path == "/slow":
                    time.sleep(0.04)
        except (BrokenPipeError, ConnectionResetError):
            pass


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        subprocess.run([sys.argv[1], "--optional-model-smoke", f"http://127.0.0.1:{server.server_port}"], check=True)
    finally:
        server.shutdown()
        server.server_close()
