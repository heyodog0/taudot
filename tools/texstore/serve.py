"""Serve the local store over HTTP as R2 will: files/<sha512> (application/gzip, immutable) and images/NAME/rREV.

  uv run --no-project python -I tools/texstore/serve.py [PORT] [--log FILE] [--delay MS]

GET only, no directory listings. --log writes one line per request (to prove what a run fetched); --delay adds a
round trip's worth of latency to each request, to stand in for the network.
"""
import http.server
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import texstore as ts  # noqa: E402

LOG, DELAY = None, 0.0
KEY = re.compile(r"^/(files/[0-9a-f]{128}|images/[0-9A-Za-z._-]+/r\d+)$")


class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        m = KEY.match(self.path)
        p = os.path.join(ts.STORE, m.group(1)) if m else None
        if DELAY:
            time.sleep(DELAY)
        if not p or not os.path.isfile(p):
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            body = None
        else:
            with open(p, "rb") as f:
                body = f.read()
            self.send_response(200)
            files = m.group(1).startswith("files/")
            self.send_header("Content-Type", "application/gzip" if files else "text/plain")
            self.send_header("Cache-Control", "public, max-age=31536000, immutable" if files else "max-age=300")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        if LOG:
            with open(LOG, "a") as f:
                f.write(f"{time.time():.3f}\t{200 if body is not None else 404}\t{self.path}\n")

    def log_message(self, *a):
        pass


def main(a):
    global LOG, DELAY
    if "--log" in a:
        LOG = a[a.index("--log") + 1]
    if "--delay" in a:
        DELAY = float(a[a.index("--delay") + 1]) / 1000
    port = int(a[0]) if a and a[0].isdigit() else 8790
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", port), H)
    print(f"serving {ts.STORE} at http://127.0.0.1:{port}", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main(sys.argv[1:])
