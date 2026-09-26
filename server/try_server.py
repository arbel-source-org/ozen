"""Plays a recording to a running ozen_server.py the way the phone would
(in real time, 43 ms chunks) and reports what came back and how fast.

    python try_server.py ws://localhost:8765 CODE speech.wav [reference.txt]

For every finished line it prints how long after that line's last word
was sent the final text arrived. This includes the one second of quiet
the server waits for before it calls a line finished.
"""
import asyncio
import json
import sys
import time

import numpy as np
import soundfile as sf
import websockets

RATE = 16_000
CHUNK = 688


async def main(url, token, wav, reference=None):
    audio, rate = sf.read(wav, dtype="float32")
    if audio.ndim > 1:
        audio = audio.mean(1)
    if rate != RATE:
        raise SystemExit(f"{wav} is {rate} Hz; this needs 16 kHz mono")
    finals, first_words, delays = [], [], []
    live = 0
    async with websockets.connect(url, max_size=2**22) as ws:
        await ws.send(json.dumps({"type": "hello", "version": 1, "token": token, "language": "he", "vocabulary": []}))
        reply = json.loads(await ws.recv())
        if reply.get("type") != "ready":
            raise SystemExit(f"server refused: {reply}")
        print("connected:", reply.get("model"))
        start = time.monotonic()

        async def send():
            for i in range(0, len(audio), CHUNK):
                chunk = np.clip(audio[i:i + CHUNK], -1, 1)
                await ws.send((chunk * 32767).astype("<i2").tobytes())
                await asyncio.sleep(max(0.0, start + (i + CHUNK) / RATE - time.monotonic()))
            await ws.send(json.dumps({"type": "end"}))

        sender = asyncio.create_task(send())
        seen = set()
        async for message in ws:
            msg = json.loads(message)
            if msg.get("type") != "text":
                continue
            now = time.monotonic()
            lag = now - (start + msg.get("end_s", 0))
            if msg["utterance"] not in seen:
                seen.add(msg["utterance"])
                first_words.append(lag)
            if msg["final"]:
                finals.append(msg["text"])
                delays.append(lag)
                print(f"  [{len(finals):3d}] {lag:5.2f}s  {msg['text']}")
            else:
                live += 1
        await sender

    print(f"\n{len(finals)} lines, {live} live updates")
    if delays:
        print(f"finished line on screen after it was said: median {np.median(delays):.2f}s, worst {max(delays):.2f}s")
        print(f"first words of a line on screen: median {np.median(first_words):.2f}s behind the audio")
    if reference:
        import jiwer
        ref = open(reference, encoding="utf-8").read()
        print(f"words wrong: {jiwer.wer(ref, ' '.join(finals)) * 100:.1f}%")


if __name__ == "__main__":
    asyncio.run(main(*sys.argv[1:5]))
