#!/usr/bin/env python3
"""Exercise the app's real download task against small local HTTP fixtures."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import threading
import time

PAYLOAD = b"q" * (128 * 1024)


class Handler(BaseHTTPRequestHandler):
    retries = 0
    requests = []
    def log_message(self, *_):
        pass

    def do_GET(self):
        Handler.requests.append(self.path)
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


def check_application_upgrade(executable, server):
    with tempfile.TemporaryDirectory(prefix="rimeq-model-reuse-") as temporary:
        root = Path(temporary)
        app = root / "RimeQReuse.app"
        suite = "RimeQ.ModelReuse." + root.name
        unregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        try:
            before = len(Handler.requests)
            original_file = None
            for version, build, phase in [("0.3.1", "1", "download"), ("9.0.0", "2", "restore"), ("9.0.1", "3", "restore-disabled")]:
                # Replace only the application, keeping the same independent user data.
                if app.exists():
                    subprocess.run([unregister, "-u", str(app)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    shutil.rmtree(app)
                contents = app / "Contents"
                (contents / "MacOS").mkdir(parents=True)
                binary = contents / "MacOS/RimeQ"
                shutil.copy2(executable, binary)
                (contents / "Info.plist").write_bytes(plistlib.dumps({
                    "CFBundleIdentifier": "com.asmoyou.rimeq.ModelReuse." + root.name,
                    "CFBundleExecutable": "RimeQ", "CFBundlePackageType": "APPL",
                    "CFBundleShortVersionString": version, "CFBundleVersion": build,
                }))
                subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True, stdout=subprocess.DEVNULL)
                subprocess.run([str(binary), "--optional-model-reuse-smoke", str(root), server, phase], check=True)
                model = root / "models/wanxiang-lts-zh-hans.gram"
                identity = (model.stat().st_ino, model.stat().st_mtime_ns, model.read_bytes())
                if original_file is None:
                    original_file = identity
                    # Recreate a missing engine link after the first app is replaced.
                    (root / "rime/wanxiang-lts-zh-hans.gram").unlink()
                else:
                    assert identity == original_file, "application replacement rewrote the downloaded model"
            assert Handler.requests[before:] == ["/reuse-model"], "model restore unexpectedly accessed the network"
            print("PASS app replacement: 0.3.1 → 9.0.0 → 9.0.1; same model inode/content, restored link, preserved opt-out, one initial download only")
        finally:
            subprocess.run([unregister, "-u", str(app)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            subprocess.run(["defaults", "delete", suite], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        url = f"http://127.0.0.1:{server.server_port}"
        subprocess.run([sys.argv[1], "--optional-model-smoke", url], check=True)
        check_application_upgrade(sys.argv[1], url)
    finally:
        server.shutdown()
        server.server_close()
