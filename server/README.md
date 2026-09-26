# Ozen home server

Runs the same Hebrew speech model as the phone (ivrit.ai's Whisper Turbo) on
a computer with an NVIDIA graphics card, and captions the phone's microphone
over the network. The phone keeps its own model as a fallback: when this
server can't be reached, captions carry on from the phone by themselves.

Measured on an RTX 2080 Ti: a finished line is on the phone about 1 s after
it was said (most of that is the second of quiet the server waits for before
it calls a line finished) and the first words of a line appear about 0.2 s
behind the speaker.

## Running it

Linux, or Windows through WSL (Ubuntu). On Windows the normal NVIDIA driver
already gives WSL the graphics card; install nothing else from NVIDIA.

```
bash setup.sh
~/ozen-server/run.sh
```

`setup.sh` installs everything into `~/ozen-server`, makes a pairing code
once (kept in `~/ozen-server/pairing-code`, readable only by you) and prints
it. Running it again updates the server and keeps the code. `bash setup.sh
--cpu` sets up a copy without a graphics card, for trying it out only.

The first start downloads the model (about 1.6 GB). The pairing code goes
into the phone: Settings, Engine, Home computer.

## Reaching it from the phone

- **Same Wi-Fi:** the computer's address, for example `192.168.1.20`.
- **From anywhere, no app on the phone:** Tailscale Funnel gives the
  server a public `wss://` address with a real certificate:
  `tailscale funnel --bg 8765` (on Windows, in the Windows command prompt;
  WSL's port shows up on Windows' own localhost), then enter
  `wss://<computer>.<tailnet>.ts.net` in the phone. Only someone with the
  pairing code gets captions.

## Starting it with Windows

In the Windows command prompt, once:

```
schtasks /Create /TN "Ozen server" /SC ONLOGON /TR "wsl.exe -d Ubuntu -- bash -lc ~/ozen-server/run.sh"
```

It starts when you log in to Windows and stops when you log out.

## Checking it

```
cd ~/ozen-server && venv/bin/python try_server.py ws://localhost:8765 "$(cat pairing-code)" some-hebrew-16k.wav
```

prints each finished line and how long after it was said it arrived.
