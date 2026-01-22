#!/usr/bin/env python3
"""
Host-side mock IMDS server for integration tests.
Runs on host, accessible from VM via QEMU's gateway (10.0.2.2).
"""

import http.server
import json
import sys
from pathlib import Path

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
SCENARIOS_DIR = Path(sys.argv[2]) if len(sys.argv) > 2 else Path("scenarios")
SCENARIO = sys.argv[3] if len(sys.argv) > 3 else "basic-boot"
NIC_COUNT = int(sys.argv[4]) if len(sys.argv) > 4 else 1
TOKEN = "mock-imds-token-12345"

# Generate MACs for each NIC (QEMU style: 52:54:00:12:34:XX)
def generate_macs(count):
    """Generate sequential MAC addresses starting from QEMU default."""
    macs = []
    for i in range(count):
        macs.append(f"52:54:00:12:34:{86 + i:02x}")
    return macs

MACS = generate_macs(NIC_COUNT)

# Static metadata responses
METADATA = {
    "instance-id": "i-test12345",
    "local-hostname": "test-host",
    "ami-id": "ami-test12345",
    "instance-type": "t3.micro",
    "placement/availability-zone": "us-east-1a",
    "placement/region": "us-east-1",
}

# Mock IAM role and credentials
IAM_ROLE = "test-instance-role"
IAM_CREDENTIALS = {
    "Code": "Success",
    "LastUpdated": "2024-01-01T00:00:00Z",
    "Type": "AWS-HMAC",
    "AccessKeyId": "ASIAIOSFODNN7EXAMPLE",
    "SecretAccessKey": "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
    "Token": "FwoGZXIvYXdzEBYaDM3fake0token1234567890==",
    "Expiration": "2099-12-31T23:59:59Z",
}


class IMDSHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print(f"IMDS: {fmt % args}", file=sys.stderr, flush=True)

    def do_PUT(self):
        """Handle IMDSv2 token request."""
        if self.path == "/latest/api/token":
            token_bytes = TOKEN.encode()
            print(f"IMDS: Returning token ({len(token_bytes)} bytes): {TOKEN}", file=sys.stderr, flush=True)
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(token_bytes)))
            self.send_header("X-aws-ec2-metadata-token-ttl-seconds", "21600")
            self.end_headers()
            self.wfile.write(token_bytes)
        else:
            self.send_error(404)

    def do_GET(self):
        """Handle metadata requests."""
        path = self.path.lstrip("/")

        # User data
        if path == "latest/user-data":
            user_data_file = SCENARIOS_DIR / SCENARIO / "user-data.yaml"
            if user_data_file.is_file():
                content = user_data_file.read_bytes()
                self.send_response(200)
                self.send_header("Content-Type", "text/plain")
                self.send_header("Content-Length", str(len(content)))
                self.end_headers()
                self.wfile.write(content)
            else:
                self.send_error(404)
            return

        # Strip latest/meta-data/ prefix
        if path.startswith("latest/meta-data/"):
            meta_path = path[len("latest/meta-data/"):]
        else:
            self.send_error(404)
            return

        # Network interface queries - respond to any MAC
        if meta_path.startswith("network/interfaces/macs/"):
            self._handle_network_metadata(meta_path)
            return

        # IAM credentials
        if meta_path.startswith("iam/"):
            self._handle_iam_metadata(meta_path)
            return

        # Static metadata
        if meta_path in METADATA:
            content = METADATA[meta_path].encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(content)))
            self.end_headers()
            self.wfile.write(content)
        else:
            self.send_error(404)

    def _handle_network_metadata(self, meta_path):
        """Handle network interface metadata queries."""
        parts = meta_path.split("/")
        # network/interfaces/macs/<mac>/...

        # List MACs: network/interfaces/macs/
        if meta_path == "network/interfaces/macs/" or meta_path == "network/interfaces/macs":
            # Return all configured MACs
            content = "\n".join(f"{mac}/" for mac in MACS).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(content)))
            self.end_headers()
            self.wfile.write(content)
            return

        if len(parts) >= 5:
            mac = parts[3]
            attr = "/".join(parts[4:])

            # Find device number for this MAC
            try:
                device_num = MACS.index(mac)
            except ValueError:
                # Unknown MAC - return 404
                self.send_error(404)
                return

            # Per-interface responses
            responses = {
                "device-number": str(device_num),
                "local-ipv4s": f"10.0.2.{15 + device_num}",
                "subnet-id": f"subnet-test{device_num}",
                "vpc-id": "vpc-test123",
            }

            if attr in responses:
                content = responses[attr].encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/plain")
                self.send_header("Content-Length", str(len(content)))
                self.end_headers()
                self.wfile.write(content)
                return

        self.send_error(404)

    def _handle_iam_metadata(self, meta_path):
        """Handle IAM credential metadata queries."""
        # iam/security-credentials/ - list roles
        if meta_path in ("iam/security-credentials/", "iam/security-credentials"):
            content = IAM_ROLE.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(content)))
            self.end_headers()
            self.wfile.write(content)
            return

        # iam/security-credentials/<role-name> - get credentials
        if meta_path == f"iam/security-credentials/{IAM_ROLE}":
            content = json.dumps(IAM_CREDENTIALS).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(content)))
            self.end_headers()
            self.wfile.write(content)
            return

        self.send_error(404)


if __name__ == "__main__":
    print(f"Mock IMDS server starting on 0.0.0.0:{PORT}", file=sys.stderr, flush=True)
    print(f"Scenarios dir: {SCENARIOS_DIR}", file=sys.stderr, flush=True)
    print(f"Current scenario: {SCENARIO}", file=sys.stderr, flush=True)
    print(f"NIC count: {NIC_COUNT}, MACs: {MACS}", file=sys.stderr, flush=True)

    server = http.server.HTTPServer(("0.0.0.0", PORT), IMDSHandler)
    server.serve_forever()
