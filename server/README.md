# Ozen home server

Runs the same Hebrew speech model as the phone (ivrit.ai's Whisper Turbo) on
a computer with an NVIDIA graphics card, and captions the phone's microphone
over the network. The phone keeps its own model as a fallback: when this
server can't be reached, captions carry on from the phone by themselves.

Measured on an RTX 2080 Ti: the first words of a line appear about 0.15 s
behind the speaker, and the finished line is on the phone about 1 s after it
was said (0.7 s of that is the quiet the server waits for before it calls a
line finished).

## Running it on Windows

No WSL needed. In PowerShell as administrator, from this folder:

```
powershell -ExecutionPolicy Bypass -File setup-windows.ps1
```

It installs its own Python and everything else into `C:\ozen`, makes a
pairing code once (`C:\ozen\pairing-code`), and registers a task that starts
the server when Windows starts, before anyone logs in, and restarts it if it
stops (also when three passes in a row fail, as after a graphics-driver
fault). Running it again updates the server and keeps the code. The log is
`C:\ozen\server.log`.

## Running it on Linux

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

With a graphics card of 8 GB or more, add `--final-model
ivrit-ai/whisper-large-v3-ct2` to the start command (in `run.sh`, or `run.cmd`
on Windows): the fast model keeps writing the live words and the full one
writes each finished line. On a 2080 Ti that cut mistakes by about 15% with a
TV loud in the room or the speaker across it, for about 0.4 s more per
finished line.

A line in which a voice detector hears almost no voice (under 5% of it) is
skipped before the model sees it: kitchen clatter and a TV room hum turned
into about ten invented lines a minute, and none with the check, with no
change on real speech. `--speech-gate 0` turns it off.

The first start downloads the model (about 1.6 GB, 3 GB more for the full one). The pairing code goes
into the phone: Settings, Engine, Home computer.

## Pairing the phone

Both setup scripts end by making `pairing.html` next to the server: a QR code
with the address and code in it. Open the iPhone's Camera, point it at the
code, tap the Ozen link, and confirm. To make it again, or for a different
address: `python pairing.py --address wss://<computer>.<tailnet>.ts.net`.

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
