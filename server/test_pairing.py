import io
import json
import os
import tempfile
import unittest
from unittest import mock

import pairing


class Done:
    def __init__(self, stdout):
        self.stdout = stdout


class TailscaleAddress(unittest.TestCase):
    def test_a_fresh_install_is_found_by_its_full_path(self):
        def run(command, **_):
            if command[0] == "tailscale":
                raise FileNotFoundError("not on PATH yet")
            return Done(json.dumps({"Self": {"DNSName": "desktop.tail0example.ts.net."}}))

        with mock.patch("subprocess.run", run):
            self.assertEqual(pairing.tailscale_address(), "wss://desktop.tail0example.ts.net")

    def test_no_tailscale_anywhere_gives_no_address(self):
        def run(command, **_):
            raise FileNotFoundError(command[0])

        with mock.patch("subprocess.run", run):
            self.assertIsNone(pairing.tailscale_address())


class PhoneAddress(unittest.TestCase):
    def test_the_funnel_https_address_becomes_wss(self):
        self.assertEqual(pairing.phone_address("https://pc.tail0example.ts.net"), "wss://pc.tail0example.ts.net")
        self.assertEqual(pairing.phone_address("HTTPS://pc.tail0example.ts.net"), "wss://pc.tail0example.ts.net")

    def test_other_addresses_are_left_alone(self):
        for address in ["wss://pc.tail0example.ts.net", "192.168.1.20", "ws://100.64.0.7:8765"]:
            self.assertEqual(pairing.phone_address(address), address)


class PairingPage(unittest.TestCase):
    def setUp(self):
        self.umask = os.umask(0o022)

    def tearDown(self):
        os.umask(self.umask)

    def make_page(self, folder):
        code = os.path.join(folder, "pairing-code")
        with open(code, "w", encoding="utf-8") as f:
            f.write("example-code-123\n")
        out = os.path.join(folder, "pairing.html")
        argv = ["pairing.py", "--address", "192.168.1.20", "--code-file", code, "--out", out, "--no-open"]
        with mock.patch("sys.argv", argv), mock.patch("sys.stdout", io.StringIO()):
            pairing.main()
        return out

    def test_the_page_holding_the_code_is_readable_only_by_its_owner(self):
        with tempfile.TemporaryDirectory() as folder:
            out = self.make_page(folder)
            self.assertEqual(os.stat(out).st_mode & 0o777, 0o600)
            with open(out, encoding="utf-8") as f:
                self.assertIn("example-code-123", f.read())

    def test_a_page_an_older_version_left_readable_is_closed(self):
        with tempfile.TemporaryDirectory() as folder:
            out = os.path.join(folder, "pairing.html")
            with open(out, "w", encoding="utf-8") as f:
                f.write("old page")
            os.chmod(out, 0o644)
            self.make_page(folder)
            self.assertEqual(os.stat(out).st_mode & 0o777, 0o600)

    def test_a_page_whose_permissions_cannot_be_changed_is_still_made(self):
        with tempfile.TemporaryDirectory() as folder, mock.patch("os.chmod", side_effect=PermissionError("locked")):
            out = self.make_page(folder)
            with open(out, encoding="utf-8") as f:
                self.assertIn("example-code-123", f.read())


class CodeFile(unittest.TestCase):
    def test_a_code_saved_again_by_notepad_loses_its_byte_order_mark(self):
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "pairing-code")
            with open(path, "w", encoding="utf-8-sig", newline="") as f:
                f.write("example-code-123\r\n")
            self.assertEqual(pairing.read_code(path), "example-code-123")


if __name__ == "__main__":
    unittest.main()
