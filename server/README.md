# Ozen home server

Runs the same Hebrew speech model as the phone (ivrit.ai's Whisper Turbo) on
a computer with an NVIDIA graphics card, and captions the phone's microphone
over the network. The phone keeps its own model as a fallback: when this
server can't be reached, captions carry on from the phone by themselves.

Measured on an RTX 2080 Ti: about 40 times faster than real time, around
0.2 s per sentence.

## Running it

Linux, or Windows through WSL (Ubuntu). On Windows the normal NVIDIA driver
already gives WSL the graphics card; install nothing else from NVIDIA.

```
python3 -m venv ~/ozen-server && . ~/ozen-server/bin/activate
pip install -r requirements.txt nvidia-cublas-cu12 nvidia-cudnn-cu12==9.*
export LD_LIBRARY_PATH=$(python3 -c 'import os, nvidia.cublas.lib, nvidia.cudnn.lib; print(os.path.dirname(nvidia.cublas.lib.__file__) + ":" + os.path.dirname(nvidia.cudnn.lib.__file__))')
export OZEN_TOKEN=$(python3 -c 'import secrets; print(secrets.token_urlsafe(12))')
echo "pairing code: $OZEN_TOKEN"
python3 ozen_server.py
```

The first start downloads the model (about 1.6 GB). The pairing code goes
into the phone: Settings, Engine, Home computer.

## Reaching it from the phone

- **Same Wi-Fi:** the computer's address, for example `192.168.1.20`.
- **From anywhere, no app on the phone:** Tailscale Funnel gives the
  server a public `wss://` address with a real certificate:
  `tailscale funnel 8765`, then enter `wss://<computer>.<tailnet>.ts.net`
  in the phone. Only someone with the pairing code gets captions.

## Checking it

```
python3 try_server.py ws://localhost:8765 "$OZEN_TOKEN" some-hebrew-16k.wav
```

prints each finished line and how long after it was said it arrived.
