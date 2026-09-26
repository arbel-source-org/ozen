"""Ozen home server: live Hebrew captions from a GPU on the home network.

The phone streams its microphone here as 16 kHz mono PCM16 over one
WebSocket and gets back the words as they form, then the final line for
each utterance. The rules mirror the phone's own Whisper engine
(Sources/OzenPlatform/WhisperKitEngine.swift) so a line looks the same
whichever does the work: speech detection decides where an utterance
starts and ends, a 1 s pause ends it, 28 s is the most one pass hears
(cut at the quietest moment of the last 2 s), and while someone is still
talking the utterance is decoded again every `live_interval` seconds.
A GPU makes those passes fast enough to run far more often than a
phone can, and leaves room for what the phone can't afford.

Protocol, version 1. Text frames are JSON, binary frames are audio.
  phone -> server
    {"type": "hello", "version": 1, "token": "...", "language": "he",
     "vocabulary": ["Ruti", ...]}            first frame, required
    <binary>                                  PCM16 little-endian, 16 kHz, mono
    {"type": "vocabulary", "terms": [...]}    the names list changed
    {"type": "end"}                           no more audio; finish the line
  server -> phone
    {"type": "ready", "model": "...", "version": 1}
    {"type": "error", "code": "unauthorized" | "bad_request" | "busy", "detail": "..."}
    {"type": "text", "utterance": 7, "text": "...", "final": false,
     "confidence": 0.93}
"""
import argparse
import asyncio
import hmac
import json
import logging
import math
import os
import time

import numpy as np
import websockets
from faster_whisper import WhisperModel

RATE = 16_000
PROTOCOL_VERSION = 1
log = logging.getLogger("ozen")


class EnergyVoiceDetector:
    """Port of Sources/OzenKit/EnergyVoiceDetector.swift, same constants."""

    def __init__(self):
        self.absolute = 0.001
        self.ratio = 2.5
        self.steady_ratio = 2.0
        self.swing_rate = 0.02
        self.fall = 0.3
        self.rise = 0.02
        self.max_floor = 0.02
        self.floor = 0.0004
        self.window = 48_000
        self.recent_rise = 0.05
        self.swing = 2.0
        self.recent = []
        self.recent_samples = 0

    def _ratio_now(self):
        steady = 20 * math.log10(self.steady_ratio)
        swinging = 20 * math.log10(max(self.ratio, self.steady_ratio))
        db = min(max(steady + self.swing, steady), swinging)
        return 10 ** (db / 20)

    def threshold(self):
        return max(self.absolute, self.floor * self._ratio_now())

    def is_speech(self, chunk):
        level = float(np.sqrt(np.mean(np.square(chunk)))) if len(chunk) else 0.0
        if not math.isfinite(level):
            return False
        self._follow_recent(level, len(chunk))
        speech = level > self.threshold()
        if not speech:
            if level < self.floor:
                self.floor += (level - self.floor) * self.fall
            else:
                self.floor += (level - self.floor) * self.rise
            self.floor = min(self.floor, self.max_floor)
        return speech

    def _follow_recent(self, level, n):
        if n <= 0:
            return
        self.recent.append((level, n))
        self.recent_samples += n
        while self.recent and self.recent_samples - self.recent[0][1] >= self.window:
            self.recent_samples -= self.recent.pop(0)[1]
        if self.recent_samples < self.window:
            return
        levels = sorted(l for l, _ in self.recent)
        quietest = levels[0]
        if quietest > 0 and len(levels) >= 5:
            swing = 20 * math.log10(levels[len(levels) // 5] / quietest)
            self.swing += (swing - self.swing) * self.swing_rate
        if quietest > self.floor:
            self.floor += (quietest - self.floor) * self.recent_rise
            self.floor = min(self.floor, self.max_floor)


def quietest_point(samples, end, look_back, frame):
    """Port of UtteranceCut.quietestPoint."""
    end = min(max(end, 0), len(samples))
    start = max(0, end - max(look_back, 0))
    if frame <= 1 or end - start < frame:
        return end
    step = frame // 2
    best, best_energy, i = end, math.inf, start
    while i + frame <= end:
        e = float(np.sum(np.square(samples[i:i + frame])))
        if e <= best_energy:
            best_energy, best = e, i + step
        i += step
    return best


class Transcriber:
    """One model on the GPU, shared by every connection, one pass at a time."""

    def __init__(self, model, device, compute_type, beam, context):
        self.name = model
        self.model = WhisperModel(model, device=device, compute_type=compute_type)
        self.beam = beam
        self.context = context
        self.lock = asyncio.Lock()

    async def transcribe(self, audio, language, prompt, final):
        async with self.lock:
            return await asyncio.to_thread(self._run, audio, language, prompt, final)

    def _run(self, audio, language, prompt, final):
        segments, _ = self.model.transcribe(
            audio, language=language, task="transcribe",
            beam_size=self.beam if final else 1,
            temperature=[0.0, 0.2, 0.4] if final else 0.0,
            condition_on_previous_text=False, without_timestamps=True,
            initial_prompt=prompt or None, vad_filter=False,
            compression_ratio_threshold=2.4, log_prob_threshold=-1.0,
            no_speech_threshold=0.6)
        kept, logprobs = [], []
        for s in segments:
            if s.no_speech_prob > 0.6 and s.avg_logprob < -1.0:
                continue
            if s.compression_ratio > 2.4:
                continue
            t = s.text.strip()
            if t:
                kept.append(t)
                logprobs.append(s.avg_logprob)
        text = " ".join(kept).strip()
        confidence = None
        if logprobs:
            confidence = min(max(math.exp(sum(logprobs) / len(logprobs)), 0.0), 1.0)
        return text, confidence


class Session:
    pause = 1.0
    trailing_pad = 0.3
    leading_keep = 0.5
    max_utterance = 28.0
    cut_look_back = 2.0
    cut_frame = 0.05

    def __init__(self, ws, transcriber, language, vocabulary, live_interval):
        self.ws = ws
        self.t = transcriber
        self.language = language
        self.vocabulary = vocabulary
        self.live_interval = live_interval
        self.detector = EnergyVoiceDetector()
        self.buf = np.zeros(0, dtype=np.float32)
        self.last_speech_end = None
        self.finished = False
        self.samples_at_last_pass = 0
        self.utterance = 0
        self.previous_text = ""
        self.changed = asyncio.Event()

    def add_audio(self, pcm16: bytes):
        chunk = np.frombuffer(pcm16, dtype="<i2").astype(np.float32) / 32768.0
        # The phone sends whatever it has; the detector sees chunks of the
        # size it was tuned on (about 43 ms).
        step = 688
        for i in range(0, len(chunk), step):
            piece = chunk[i:i + step]
            self.buf = np.concatenate([self.buf, piece])
            if self.detector.is_speech(piece):
                self.last_speech_end = len(self.buf)
        self.changed.set()

    def prompt(self):
        parts = []
        if self.vocabulary:
            parts.append(", ".join(self.vocabulary) + ".")
        if self.t.context and self.previous_text:
            parts.append(self.previous_text[-200:])
        return " ".join(parts) or None

    async def run(self):
        R = RATE
        pause, pad, keep = int(self.pause * R), int(self.trailing_pad * R), int(self.leading_keep * R)
        max_s = int(self.max_utterance * R)
        while True:
            total = len(self.buf)
            end_speech = self.last_speech_end
            if end_speech is None:
                if total > keep:
                    self.buf = self.buf[total - keep:]
                if self.finished:
                    return
                await self._wait()
                continue
            pause_reached = total - end_speech >= pause
            too_long = total >= max_s
            final = pause_reached or too_long or self.finished
            if not final and total - self.samples_at_last_pass < int(self.live_interval * R):
                await self._wait()
                continue
            if not final:
                window = self.buf[:total]
            else:
                end = min(total, end_speech + pad)
                window = self.buf[:end]
                if too_long and not pause_reached and not self.finished:
                    cut = quietest_point(window, len(window), int(self.cut_look_back * R), int(self.cut_frame * R))
                    window = window[:cut]
            self.samples_at_last_pass = total
            text, confidence = await self.t.transcribe(window.copy(), self.language, self.prompt(), final)
            if text or final:
                await self.ws.send(json.dumps({
                    "type": "text", "utterance": self.utterance, "text": text,
                    "final": final, "confidence": confidence}, ensure_ascii=False))
            if final:
                if text:
                    self.previous_text = (self.previous_text + " " + text).strip()[-400:]
                used = len(window)
                self.buf = self.buf[used:]
                if self.last_speech_end is not None:
                    self.last_speech_end = self.last_speech_end - used if self.last_speech_end > used else None
                self.utterance += 1
                self.samples_at_last_pass = 0
                if self.finished and len(self.buf) == 0:
                    return

    async def _wait(self):
        self.changed.clear()
        try:
            await asyncio.wait_for(self.changed.wait(), timeout=0.05)
        except asyncio.TimeoutError:
            pass


async def handle(ws, transcriber, token, live_interval):
    peer = ws.remote_address
    try:
        hello = json.loads(await asyncio.wait_for(ws.recv(), timeout=10))
    except Exception:
        await ws.send(json.dumps({"type": "error", "code": "bad_request", "detail": "hello expected"}))
        return
    if hello.get("type") != "hello" or not hmac.compare_digest(str(hello.get("token", "")), token):
        log.warning("refused %s", peer)
        await ws.send(json.dumps({"type": "error", "code": "unauthorized", "detail": ""}))
        return
    session = Session(ws, transcriber, hello.get("language", "he"),
                      [str(v) for v in hello.get("vocabulary", [])][:200], live_interval)
    await ws.send(json.dumps({"type": "ready", "model": transcriber.name, "version": PROTOCOL_VERSION}))
    log.info("session from %s", peer)
    worker = asyncio.create_task(session.run())
    try:
        async for message in ws:
            if isinstance(message, bytes):
                session.add_audio(message)
                continue
            msg = json.loads(message)
            if msg.get("type") == "vocabulary":
                session.vocabulary = [str(v) for v in msg.get("terms", [])][:200]
            elif msg.get("type") == "end":
                session.finished = True
                session.changed.set()
                break
        await worker
    except websockets.ConnectionClosed:
        pass
    finally:
        worker.cancel()
        log.info("session from %s ended", peer)


async def main():
    p = argparse.ArgumentParser()
    p.add_argument("--host", default="0.0.0.0")
    p.add_argument("--port", type=int, default=8765)
    p.add_argument("--model", default="ivrit-ai/whisper-large-v3-turbo-ct2")
    p.add_argument("--device", default="cuda")
    p.add_argument("--compute-type", default="float16")
    p.add_argument("--beam", type=int, default=1)
    p.add_argument("--context", action="store_true")
    p.add_argument("--live-interval", type=float, default=0.3)
    args = p.parse_args()
    token = os.environ.get("OZEN_TOKEN")
    if not token:
        raise SystemExit("set OZEN_TOKEN to the pairing code the phone will send")
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")
    transcriber = Transcriber(args.model, args.device, args.compute_type, args.beam, args.context)
    # Warm the model so the first sentence isn't slow.
    await transcriber.transcribe(np.zeros(RATE, dtype=np.float32), "he", None, True)
    async with websockets.serve(lambda ws: handle(ws, transcriber, token, args.live_interval),
                                args.host, args.port, max_size=2**22, ping_interval=10, ping_timeout=20):
        log.info("listening on %s:%d with %s", args.host, args.port, args.model)
        await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(main())
