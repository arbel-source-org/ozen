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


if __name__ == "__main__":
    unittest.main()
