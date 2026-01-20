#!/usr/bin/env python3
"""
Mock IMDS server for integration tests.
Supports both IMDSv1 (GET) and IMDSv2 (PUT for token, GET with token header).
"""

import http.server
import os
import sys
from pathlib import Path

IMDS_ROOT = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("/tmp/imds")
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 80
HOST = sys.argv[3] if len(sys.argv) > 3 else "169.254.169.254"
TOKEN = "mock-imds-token-12345"


class IMDSHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        # Log to stderr
        print(f"IMDS: {format % args}", file=sys.stderr)

    def do_PUT(self):
        """Handle IMDSv2 token request."""
        if self.path == "/latest/api/token":
            token_bytes = TOKEN.encode()
            print(f"IMDS: Returning token ({len(token_bytes)} bytes): {TOKEN}", file=sys.stderr)
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(token_bytes)))
            self.send_header("X-aws-ec2-metadata-token-ttl-seconds", "21600")
            self.end_headers()
            self.wfile.write(token_bytes)
            self.wfile.flush()
        else:
            self.send_error(404)

    def do_GET(self):
        """Handle metadata requests."""
        # Map URL path to file
        file_path = IMDS_ROOT / self.path.lstrip("/")

        # Check for index.html if path is a directory
        if file_path.is_dir():
            file_path = file_path / "index.html"

        if file_path.is_file():
            content = file_path.read_text()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(content)))
            self.end_headers()
            self.wfile.write(content.encode())
        else:
            self.send_error(404)


if __name__ == "__main__":
    server = http.server.HTTPServer((HOST, PORT), IMDSHandler)
    print(f"Mock IMDS server listening on {HOST}:{PORT}", file=sys.stderr)
    server.serve_forever()
