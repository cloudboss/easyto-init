#!/usr/bin/env python3
"""Tests for the mock IMDS server."""

import http.client
import json
import threading
import unittest
from http.server import HTTPServer
from pathlib import Path

# Set module globals before importing
import imds_server

# Override globals for testing
imds_server.SCENARIOS_DIR = Path(__file__).parent.parent / "scenarios"
imds_server.SCENARIO = "basic-boot"
imds_server.NIC_COUNT = 2
imds_server.MACS = imds_server.generate_macs(2)
imds_server.SPOT_TERMINATION_DELAY = 0


def start_server():
    """Start a test IMDS server on an ephemeral port."""
    server = HTTPServer(("127.0.0.1", 0), imds_server.IMDSHandler)
    port = server.server_address[1]
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server, port


class TestIMDSToken(unittest.TestCase):
    """Tests for PUT /latest/api/token (IMDSv2 token acquisition)."""

    @classmethod
    def setUpClass(cls):
        cls.server, cls.port = start_server()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def request(self, method, path, headers=None):
        c = http.client.HTTPConnection("127.0.0.1", self.port)
        c.request(method, path, headers=headers or {})
        r = c.getresponse()
        body = r.read()
        c.close()
        return r, body

    def test_put_token_success(self):
        r, body = self.request(
            "PUT", "/latest/api/token",
            {"X-aws-ec2-metadata-token-ttl-seconds": "21600"})
        self.assertEqual(r.status, 200)
        self.assertEqual(body.decode(), imds_server.TOKEN)
        self.assertEqual(
            r.getheader("Content-Length"), str(len(body)))

    def test_put_token_returns_ttl_header(self):
        r, _ = self.request(
            "PUT", "/latest/api/token",
            {"X-aws-ec2-metadata-token-ttl-seconds": "300"})
        self.assertEqual(r.status, 200)
        self.assertEqual(
            r.getheader("X-aws-ec2-metadata-token-ttl-seconds"), "300")

    def test_put_token_missing_ttl(self):
        r, _ = self.request("PUT", "/latest/api/token")
        self.assertEqual(r.status, 400)

    def test_put_token_invalid_ttl_zero(self):
        r, _ = self.request(
            "PUT", "/latest/api/token",
            {"X-aws-ec2-metadata-token-ttl-seconds": "0"})
        self.assertEqual(r.status, 400)

    def test_put_token_invalid_ttl_too_high(self):
        r, _ = self.request(
            "PUT", "/latest/api/token",
            {"X-aws-ec2-metadata-token-ttl-seconds": "21601"})
        self.assertEqual(r.status, 400)

    def test_put_token_invalid_ttl_not_a_number(self):
        r, _ = self.request(
            "PUT", "/latest/api/token",
            {"X-aws-ec2-metadata-token-ttl-seconds": "abc"})
        self.assertEqual(r.status, 400)

    def test_put_token_rejected_with_forwarded_for(self):
        r, _ = self.request(
            "PUT", "/latest/api/token",
            {"X-aws-ec2-metadata-token-ttl-seconds": "21600",
             "X-Forwarded-For": "1.2.3.4"})
        self.assertEqual(r.status, 403)

    def test_put_wrong_path(self):
        r, _ = self.request(
            "PUT", "/something/else",
            {"X-aws-ec2-metadata-token-ttl-seconds": "21600"})
        self.assertEqual(r.status, 404)


class TestIMDSGetAuth(unittest.TestCase):
    """Tests for GET authentication (token validation)."""

    @classmethod
    def setUpClass(cls):
        cls.server, cls.port = start_server()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def get(self, path, headers=None):
        c = http.client.HTTPConnection("127.0.0.1", self.port)
        c.request("GET", path, headers=headers or {})
        r = c.getresponse()
        body = r.read()
        c.close()
        return r, body

    def test_get_without_token_returns_401(self):
        r, _ = self.get("/latest/meta-data/instance-id")
        self.assertEqual(r.status, 401)

    def test_get_with_wrong_token_returns_401(self):
        r, _ = self.get(
            "/latest/meta-data/instance-id",
            {"X-aws-ec2-metadata-token": "wrong-token"})
        self.assertEqual(r.status, 401)

    def test_get_with_empty_token_returns_401(self):
        r, _ = self.get(
            "/latest/meta-data/instance-id",
            {"X-aws-ec2-metadata-token": ""})
        self.assertEqual(r.status, 401)

    def test_get_with_valid_token_returns_200(self):
        r, body = self.get(
            "/latest/meta-data/instance-id",
            {"X-aws-ec2-metadata-token": imds_server.TOKEN})
        self.assertEqual(r.status, 200)
        self.assertEqual(body.decode(), "i-test12345")


class TestIMDSMetadata(unittest.TestCase):
    """Tests for GET metadata endpoints (with valid token)."""

    @classmethod
    def setUpClass(cls):
        cls.server, cls.port = start_server()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def get(self, path):
        c = http.client.HTTPConnection("127.0.0.1", self.port)
        c.request("GET", path,
                  headers={"X-aws-ec2-metadata-token": imds_server.TOKEN})
        r = c.getresponse()
        body = r.read()
        c.close()
        return r, body

    def test_instance_id(self):
        r, body = self.get("/latest/meta-data/instance-id")
        self.assertEqual(r.status, 200)
        self.assertEqual(body.decode(), "i-test12345")

    def test_local_hostname(self):
        r, body = self.get("/latest/meta-data/local-hostname")
        self.assertEqual(r.status, 200)
        self.assertEqual(body.decode(), "test-host")

    def test_instance_type(self):
        r, body = self.get("/latest/meta-data/instance-type")
        self.assertEqual(r.status, 200)
        self.assertEqual(body.decode(), "t3.micro")

    def test_placement_az(self):
        r, body = self.get(
            "/latest/meta-data/placement/availability-zone")
        self.assertEqual(r.status, 200)
        self.assertEqual(body.decode(), "us-east-1a")

    def test_placement_region(self):
        r, body = self.get("/latest/meta-data/placement/region")
        self.assertEqual(r.status, 200)
        self.assertEqual(body.decode(), "us-east-1")

    def test_public_key(self):
        r, body = self.get(
            "/latest/meta-data/public-keys/0/openssh-key")
        self.assertEqual(r.status, 200)
        self.assertTrue(body.decode().startswith("ssh-rsa "))

    def test_unknown_metadata_returns_404(self):
        r, _ = self.get("/latest/meta-data/nonexistent")
        self.assertEqual(r.status, 404)

    def test_unknown_path_returns_404(self):
        r, _ = self.get("/something/else")
        self.assertEqual(r.status, 404)


class TestIMDSNetwork(unittest.TestCase):
    """Tests for network interface metadata."""

    @classmethod
    def setUpClass(cls):
        cls.server, cls.port = start_server()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def get(self, path):
        c = http.client.HTTPConnection("127.0.0.1", self.port)
        c.request("GET", path,
                  headers={"X-aws-ec2-metadata-token": imds_server.TOKEN})
        r = c.getresponse()
        body = r.read()
        c.close()
        return r, body

    def test_list_macs(self):
        r, body = self.get(
            "/latest/meta-data/network/interfaces/macs/")
        self.assertEqual(r.status, 200)
        lines = body.decode().strip().split("\n")
        self.assertEqual(len(lines), 2)
        for line in lines:
            self.assertTrue(line.endswith("/"))

    def test_device_number_first_nic(self):
        mac = imds_server.MACS[0]
        r, body = self.get(
            f"/latest/meta-data/network/interfaces/macs/"
            f"{mac}/device-number")
        self.assertEqual(r.status, 200)
        self.assertEqual(body.decode(), "0")

    def test_device_number_second_nic(self):
        mac = imds_server.MACS[1]
        r, body = self.get(
            f"/latest/meta-data/network/interfaces/macs/"
            f"{mac}/device-number")
        self.assertEqual(r.status, 200)
        self.assertEqual(body.decode(), "1")

    def test_unknown_mac_returns_404(self):
        r, _ = self.get(
            "/latest/meta-data/network/interfaces/macs/"
            "00:00:00:00:00:00/device-number")
        self.assertEqual(r.status, 404)

    def test_unknown_attribute_returns_404(self):
        mac = imds_server.MACS[0]
        r, _ = self.get(
            f"/latest/meta-data/network/interfaces/macs/"
            f"{mac}/nonexistent")
        self.assertEqual(r.status, 404)


class TestIMDSIam(unittest.TestCase):
    """Tests for IAM credential metadata."""

    @classmethod
    def setUpClass(cls):
        cls.server, cls.port = start_server()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def get(self, path):
        c = http.client.HTTPConnection("127.0.0.1", self.port)
        c.request("GET", path,
                  headers={"X-aws-ec2-metadata-token": imds_server.TOKEN})
        r = c.getresponse()
        body = r.read()
        c.close()
        return r, body

    def test_list_roles(self):
        r, body = self.get(
            "/latest/meta-data/iam/security-credentials/")
        self.assertEqual(r.status, 200)
        self.assertEqual(body.decode(), "test-instance-role")

    def test_get_credentials(self):
        r, body = self.get(
            "/latest/meta-data/iam/security-credentials/"
            "test-instance-role")
        self.assertEqual(r.status, 200)
        creds = json.loads(body)
        self.assertEqual(creds["Code"], "Success")
        self.assertIn("AccessKeyId", creds)
        self.assertIn("SecretAccessKey", creds)
        self.assertIn("Token", creds)
        self.assertIn("Expiration", creds)

    def test_unknown_role_returns_404(self):
        r, _ = self.get(
            "/latest/meta-data/iam/security-credentials/"
            "nonexistent-role")
        self.assertEqual(r.status, 404)


class TestIMDSUserData(unittest.TestCase):
    """Tests for user data endpoint."""

    @classmethod
    def setUpClass(cls):
        cls.server, cls.port = start_server()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def get(self, path):
        c = http.client.HTTPConnection("127.0.0.1", self.port)
        c.request("GET", path,
                  headers={"X-aws-ec2-metadata-token": imds_server.TOKEN})
        r = c.getresponse()
        body = r.read()
        c.close()
        return r, body

    def test_user_data_exists(self):
        r, body = self.get("/latest/user-data")
        self.assertEqual(r.status, 200)
        self.assertEqual(
            r.getheader("Content-Type"), "application/octet-stream")
        self.assertGreater(len(body), 0)

    def test_user_data_missing_scenario(self):
        old = imds_server.SCENARIO
        imds_server.SCENARIO = "nonexistent-scenario"
        try:
            r, _ = self.get("/latest/user-data")
            self.assertEqual(r.status, 404)
        finally:
            imds_server.SCENARIO = old


class TestIMDSInstanceIdentity(unittest.TestCase):
    """Tests for dynamic instance identity document."""

    @classmethod
    def setUpClass(cls):
        cls.server, cls.port = start_server()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def get(self, path):
        c = http.client.HTTPConnection("127.0.0.1", self.port)
        c.request("GET", path,
                  headers={"X-aws-ec2-metadata-token": imds_server.TOKEN})
        r = c.getresponse()
        body = r.read()
        c.close()
        return r, body

    def test_instance_identity_document(self):
        r, body = self.get(
            "/latest/dynamic/instance-identity/document")
        self.assertEqual(r.status, 200)
        self.assertEqual(r.getheader("Content-Type"), "application/json")
        doc = json.loads(body)
        self.assertEqual(doc["accountId"], "123456789012")
        self.assertEqual(doc["architecture"], "x86_64")
        self.assertEqual(doc["availabilityZone"], "us-east-1a")
        self.assertIsNone(doc["billingProducts"])
        self.assertIsNone(doc["devpayProductCodes"])
        self.assertIsNone(doc["marketplaceProductCodes"])
        self.assertEqual(doc["imageId"], "ami-test12345")
        self.assertEqual(doc["instanceId"], "i-test12345")
        self.assertEqual(doc["instanceType"], "t3.micro")
        self.assertIsNone(doc["kernelId"])
        self.assertEqual(doc["pendingTime"], "2024-01-01T00:00:00Z")
        self.assertEqual(doc["privateIp"], "10.0.2.15")
        self.assertIsNone(doc["ramdiskId"])
        self.assertEqual(doc["region"], "us-east-1")
        self.assertEqual(doc["version"], "2017-09-30")


class TestIMDSSpot(unittest.TestCase):
    """Tests for spot termination metadata."""

    @classmethod
    def setUpClass(cls):
        cls.server, cls.port = start_server()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def get(self, path):
        c = http.client.HTTPConnection("127.0.0.1", self.port)
        c.request("GET", path,
                  headers={"X-aws-ec2-metadata-token": imds_server.TOKEN})
        r = c.getresponse()
        body = r.read()
        c.close()
        return r, body

    def test_no_termination_returns_404(self):
        r, _ = self.get("/latest/meta-data/spot/instance-action")
        self.assertEqual(r.status, 404)

    def test_termination_after_delay(self):
        old = imds_server.SPOT_TERMINATION_DELAY
        old_start = imds_server.SERVER_START_TIME
        imds_server.SPOT_TERMINATION_DELAY = 1
        imds_server.SERVER_START_TIME = imds_server.time.time() - 2
        try:
            r, body = self.get(
                "/latest/meta-data/spot/instance-action")
            self.assertEqual(r.status, 200)
            data = json.loads(body)
            self.assertEqual(data["action"], "terminate")
            self.assertIn("time", data)
        finally:
            imds_server.SPOT_TERMINATION_DELAY = old
            imds_server.SERVER_START_TIME = old_start

    def test_termination_before_delay(self):
        old = imds_server.SPOT_TERMINATION_DELAY
        old_start = imds_server.SERVER_START_TIME
        imds_server.SPOT_TERMINATION_DELAY = 9999
        imds_server.SERVER_START_TIME = imds_server.time.time()
        try:
            r, _ = self.get(
                "/latest/meta-data/spot/instance-action")
            self.assertEqual(r.status, 404)
        finally:
            imds_server.SPOT_TERMINATION_DELAY = old
            imds_server.SERVER_START_TIME = old_start


if __name__ == "__main__":
    unittest.main()
