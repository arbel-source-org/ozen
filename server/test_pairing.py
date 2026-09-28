import json
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


if __name__ == "__main__":
    unittest.main()
