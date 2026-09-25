"""Stand-in for the two HTTP endpoints the toolkit talks to in tests.

POST /repos/<owner>/<repo>/deployments/<id>/statuses
    What git-deploy-webhook reports to. Each request body is appended as
    one line ("<path> <json> auth=<token>") to the file given as argv[2].
POST /repos/<owner>/<repo>/deployments
    What push mode creates deployments with. Recorded the same way, and
    answered with a new id (5000, 5001, ...) — or 422 like GitHub's "No ref
    found" when the ref is listed in <statuses-file>.unknown-refs.
GET /logs/<name>
    What deploy.yml tails: serves files from the directory in argv[3],
    honouring "Range: bytes=N-" the way nginx does (206 / 416).

Usage: fake_github.py <port> <statuses-file> <logs-dir>
"""

import http.server
import json
import os
import re
import sys

PORT, STATUSES, LOGS = int(sys.argv[1]), sys.argv[2], sys.argv[3]


class Handler(http.server.BaseHTTPRequestHandler):
    next_id = 5000

    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"])).decode()
        auth = self.headers.get("Authorization", "").removeprefix("Bearer ")
        with open(STATUSES, "a") as f:
            f.write(f"{self.path} {body} auth={auth}\n")
        if self.path.endswith("/deployments"):
            ref = json.loads(body)["ref"]
            unknown = STATUSES + ".unknown-refs"
            if os.path.exists(unknown) and ref in open(unknown).read().split():
                self.send_response(422)
                self.end_headers()
                self.wfile.write(json.dumps({"message": f"No ref found for: {ref}"}).encode())
                return
            dep_id, Handler.next_id = Handler.next_id, Handler.next_id + 1
            self.send_response(201)
            self.end_headers()
            self.wfile.write(json.dumps({"url": "x", "id": dep_id, "creator": {"id": 1}}).encode())
            return
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
