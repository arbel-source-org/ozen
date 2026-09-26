import argparse
import html
import io
import json
import os
import subprocess
import sys
import urllib.parse
import webbrowser

import qrcode
import qrcode.image.svg


def tailscale_address():
    try:
        out = subprocess.run(["tailscale", "status", "--json"], capture_output=True, text=True, timeout=20).stdout
        name = json.loads(out)["Self"]["DNSName"].rstrip(".")
    except (OSError, ValueError, KeyError, subprocess.SubprocessError):
        return None
    return f"wss://{name}" if name else None


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    p = argparse.ArgumentParser(description="Makes the QR code the phone scans to pair with this computer.")
    p.add_argument("--address", help="what the phone connects to, e.g. wss://pc.tailnet.ts.net or 192.168.1.20")
    p.add_argument("--code-file", default=os.path.join(here, "pairing-code"))
    p.add_argument("--out", default=os.path.join(here, "pairing.html"))
    p.add_argument("--no-open", action="store_true")
    args = p.parse_args()

    address = args.address or tailscale_address()
    if not address:
        sys.exit("Couldn't work out this computer's address; pass --address wss://... or --address 192.168.1.20")
    with open(args.code_file, encoding="utf-8") as f:
        code = f.read().strip()
    link = "ozen://pair?" + urllib.parse.urlencode({"address": address, "code": code})

    svg = io.BytesIO()
    qrcode.make(link, image_factory=qrcode.image.svg.SvgPathImage, box_size=12, border=2).save(svg)
    page = f"""<!doctype html><meta charset="utf-8"><title>Ozen pairing</title>
<style>body{{font:18px system-ui;text-align:center;margin:40px;background:#fff;color:#111}}svg{{width:360px;height:360px}}code{{font-size:16px}}</style>
<h1>Ozen: pair a phone with this computer</h1>
<p>Open the iPhone's Camera, point it at the code, and tap the Ozen link. Ozen asks before connecting.</p>
{svg.getvalue().decode()}
<p>Or type it into Ozen's Settings, Home computer:</p>
<p>Address: <code>{html.escape(address)}</code><br>Pairing code: <code>{html.escape(code)}</code></p>
<p>Anyone with this code can use this computer for captions. Keep it in the family.</p>"""
    with open(args.out, "w", encoding="utf-8") as f:
        f.write(page)
    print(f"Pairing page: {args.out}")
    print(f"Link: {link}")
    if not args.no_open:
        webbrowser.open("file://" + os.path.abspath(args.out))


if __name__ == "__main__":
    main()
