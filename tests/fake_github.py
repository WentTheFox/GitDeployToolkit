"""Stand-in for the two HTTP endpoints the toolkit talks to in tests.

POST /repos/<owner>/<repo>/deployments/<id>/statuses
    What git-deploy-webhook reports to. Each request body is appended as
    one line ("<path> <json>") to the file given as argv[2].
GET /logs/<name>
    What deploy.yml tails: serves files from the directory in argv[3],
    honouring "Range: bytes=N-" the way nginx does (206 / 416).

Usage: fake_github.py <port> <statuses-file> <logs-dir>
"""

import http.server
import os
import re
import sys

PORT, STATUSES, LOGS = int(sys.argv[1]), sys.argv[2], sys.argv[3]


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"])).decode()
        with open(STATUSES, "a") as f:
            f.write(f"{self.path} {body}\n")
        self.send_response(201)
        self.end_headers()
        self.wfile.write(b"{}")

    def do_GET(self):
        path = os.path.join(LOGS, os.path.basename(self.path))
        if not self.path.startswith("/logs/") or not os.path.isfile(path):
            self.send_response(404)
            self.end_headers()
            return
        with open(path, "rb") as f:
            data = f.read()
        m = re.match(r"bytes=(\d+)-$", self.headers.get("Range", ""))
        if m:
            start = int(m.group(1))
            if start >= len(data):
                self.send_response(416)
                self.end_headers()
                return
            self.send_response(206)
            self.end_headers()
            self.wfile.write(data[start:])
            return
        self.send_response(200)
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


http.server.HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
