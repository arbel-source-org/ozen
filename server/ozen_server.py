"""Ozen home server: live Hebrew captions from a GPU on the home network.

The phone streams its microphone here as 16 kHz mono PCM16 over one
WebSocket and gets back the words as they form, then the final line for
each utterance. The rules mirror the phone's own Whisper engine
(Sources/OzenPlatform/WhisperKitEngine.swift) so a line looks the same
whichever does the work: speech detection decides where an utterance
starts and ends, a 0.7 s pause ends it, 28 s is the most one pass hears
(cut at the quietest moment of the last 2 s), and while someone is still
talking the utterance is decoded again every `live_interval` seconds.
A GPU makes those passes fast enough to run far more often than a
phone can, and leaves room for what the phone can't afford.

Protocol, version 1. Text frames are JSON, binary frames are audio.
  phone -> server
    {"type": "hello", "version": 1, "token": "...", "language": "he",
     "vocabulary": ["Ruti", ...], "purpose": "check" | "captions",
     "client": "Ozen 0.2.36 (36), iOS 18.2"}  first frame, required
    <binary>                                  PCM16 little-endian, 16 kHz, mono
    {"type": "vocabulary", "terms": [...]}    the names list changed
    {"type": "end"}                           no more audio; finish the line
    {"type": "report", "text": "..."}         a diagnostics report to keep
                                              in reports/ (answered with
                                              {"type": "report_saved"})
  server -> phone
    {"type": "ready", "model": "...", "version": 1}
    {"type": "error", "code": "unauthorized" | "bad_request" | "busy", "detail": "..."}
    {"type": "text", "utterance": 7, "text": "...", "final": false,
     "confidence": 0.93, "end_s": 12.4,
     "segments": [{"text": "...", "no_speech": 0.02, "logprob": -0.3, "compression": 1.4}]}
  `end_s` is where in the session's audio the pass ended, in seconds, so
  a client can measure how long after the words were said they arrived.
  `segments` is every piece of the pass with Whisper's own numbers, so the
  phone can run its hallucination checks (WhisperResultFilter) on them.
"""
import argparse
import asyncio
import hmac
import json
import logging
import math
import os
import re
import time

import numpy as np
import websockets
from faster_whisper import WhisperModel
from faster_whisper.vad import VadOptions, get_speech_timestamps

RATE = 16_000
PROTOCOL_VERSION = 1
# Direction marks the ivrit.ai model puts at some line starts; they hide a
# name from the phone's alerts (see HebrewText.directionMarks).
DIRECTION_MARKS = re.compile("[\u200e\u200f\u202a-\u202e\u2066-\u2069\u061c]")
log = logging.getLogger("ozen")


class EnergyVoiceDetector:
    """Port of Sources/OzenKit/EnergyVoiceDetector.swift, same constants."""

    def __init__(self, ratio=2.5, steady_ratio=2.0):
        self.absolute = 0.001
        self.ratio = ratio
        self.steady_ratio = steady_ratio
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


SPEECH_OPTIONS = VadOptions(min_silence_duration_ms=100, speech_pad_ms=0)


MIN_VOICE_SECONDS = 0.2


def voice_samples(audio):
    """How many samples of `audio` the Silero voice detector hears as a voice.

    The energy detector that cuts lines passes a pot put down or a
    running tap as loudly as a word, and the ivrit.ai models turn that
    into confident Hebrew. A line with almost no voice in it is dropped
    before the model sees it (measured in accuracy/bench_gate.py)."""
    stamps = get_speech_timestamps(audio, SPEECH_OPTIONS)
    return sum(t["end"] - t["start"] for t in stamps)


def lacks_voice(audio, gate):
    """Under `gate` of the line is voice, and not even a short word's worth.

    The share alone would drop a sentence that clatter kept the line open
    around for half a minute; household noise measured zero voice."""
    voiced = voice_samples(audio)
    return voiced / max(len(audio), 1) < gate and voiced < MIN_VOICE_SECONDS * RATE


def speech_gain(audio, target_peak=0.5, maximum_gain=100.0):
    """Port of Sources/OzenKit/SpeechGain.swift: a voice across the room,
    brought up to a common level, gave fewer mistakes (51.3 -> 49.6% of
    words wrong; 86.5 -> 84.9% 8 dB quieter) and changed nothing up close."""
    magnitudes = np.abs(audio[::4])
    magnitudes = np.sort(magnitudes[np.isfinite(magnitudes)])
    if len(magnitudes) == 0:
        return audio
    loud = magnitudes[min(len(magnitudes) - 1, int(len(magnitudes) * 0.999))]
    if loud <= 0:
        return audio
    gain = min(max(target_peak / loud, 1.0), maximum_gain)
    if gain <= 1:
        return audio
    return np.clip(audio * gain, -1, 1).astype(np.float32)


class Transcriber:
    """The models on the GPU, shared by every connection, one pass at a time.

    `final_model`, when given, writes each finished line while `model`
    keeps up with the live ones. On the owner's 2080 Ti the full
    large-v3 made ~15% fewer mistakes than Turbo with a TV loud in the
    room or the speaker across it (36.7% -> 31.1%, 49.3% -> 45.9%) and
    the same in a quiet one, at four times the cost: worth it once per
    line, not three times a second."""

    def __init__(self, model, device, compute_type, beam, context, final_model=None, speech_gate=0.0):
        self.speech_gate = speech_gate
        self.name = model if not final_model else f"{model} + {final_model}"
        self.model = WhisperModel(model, device=device, compute_type=compute_type)
        self.final_model = WhisperModel(final_model, device=device, compute_type=compute_type) if final_model else self.model
        self.beam = beam
        self.context = context
        self.lock = asyncio.Lock()
        self.failures = 0
        self.failures_before_exit = 3

    async def transcribe(self, audio, language, prompt, final):
        async with self.lock:
            try:
                result = await asyncio.to_thread(self._run, audio, language, prompt, final)
            except Exception:
                self.failures += 1
                if self.failures >= self.failures_before_exit:
                    # A broken CUDA context fails every pass from here on while
                    # the process looks alive; exiting lets run.cmd start a
                    # fresh one instead of every phone staying on its own model.
                    log.critical("%d passes failed in a row; exiting to restart", self.failures)
                    logging.shutdown()
                    os._exit(3)
                raise
            self.failures = 0
            return result

    def _run(self, audio, language, prompt, final):
        if self.speech_gate and lacks_voice(audio, self.speech_gate):
            return "", None, []
        model = self.final_model if final else self.model
        segments, _ = model.transcribe(
            speech_gain(audio), language=language, task="transcribe",
            beam_size=self.beam if final else 1,
            temperature=[0.0, 0.2, 0.4] if final else 0.0,
            condition_on_previous_text=False, without_timestamps=True,
            initial_prompt=prompt or None, vad_filter=False,
            compression_ratio_threshold=2.4, log_prob_threshold=-1.0,
            no_speech_threshold=0.6)
        kept, logprobs, pieces = [], [], []
        for s in segments:
            piece = DIRECTION_MARKS.sub("", s.text).strip()
            if piece:
                pieces.append({"text": piece, "no_speech": round(s.no_speech_prob, 4),
                               "logprob": round(s.avg_logprob, 4), "compression": round(s.compression_ratio, 3)})
            if s.no_speech_prob > 0.6 and s.avg_logprob < -1.0:
                continue
            if s.compression_ratio > 2.4:
                continue
            t = s.text.strip()
            if t:
                kept.append(t)
                logprobs.append(s.avg_logprob)
        text = DIRECTION_MARKS.sub("", " ".join(kept)).strip()
        confidence = None
        if logprobs:
            confidence = min(max(math.exp(sum(logprobs) / len(logprobs)), 0.0), 1.0)
        return text, confidence, pieces


class Session:
    pause = 0.7  # same as the phone (WhisperKitEngine.pauseSeconds), measured there
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
        # A fifth lower than the default, as the phone cuts for Whisper
        # (EnergyVoiceDetector.forWhisperLines, measured there).
        self.detector = EnergyVoiceDetector(ratio=2.0, steady_ratio=1.6)
        self.buf = np.zeros(0, dtype=np.float32)
        self.offset = 0
        self.last_speech_end = None
        self.finished = False
        self.samples_at_last_pass = 0
        self.utterance = 0
        self.previous_text = ""
        self.changed = asyncio.Event()
        self.lines = 0
        self.empty_finals = 0
        self.final_seconds = []

    def add_audio(self, pcm16: bytes):
        chunk = np.frombuffer(pcm16, dtype="<i2").astype(np.float32) / 32768.0
        # The phone sends whatever it has; the detector sees chunks of the
        # size it was tuned on (about 43 ms).
        step = 688
        start = len(self.buf)
        self.buf = np.concatenate([self.buf, chunk])
        for i in range(0, len(chunk), step):
            piece = chunk[i:i + step]
            if self.detector.is_speech(piece):
                self.last_speech_end = start + i + len(piece)
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
            # Cleared before looking, so audio that lands between the look
            # and the wait still wakes it.
            self.changed.clear()
            total = len(self.buf)
            end_speech = self.last_speech_end
            if end_speech is None:
                if total > keep:
                    self.buf = self.buf[total - keep:]
                    self.offset += total - keep
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
            started = time.monotonic()
            text, confidence, pieces = await self.t.transcribe(window.copy(), self.language, self.prompt(), final)
            if final:
                self.final_seconds.append(time.monotonic() - started)
                if text:
                    self.lines += 1
                else:
                    self.empty_finals += 1
            if text or final:
                await self.ws.send(json.dumps({
                    "type": "text", "utterance": self.utterance, "text": text,
                    "final": final, "confidence": confidence, "segments": pieces,
                    "end_s": round((self.offset + len(window)) / R, 3)}, ensure_ascii=False))
            if final:
                if text:
                    self.previous_text = (self.previous_text + " " + text).strip()[-400:]
                used = len(window)
                self.buf = self.buf[used:]
                self.offset += used
                if self.last_speech_end is not None:
                    self.last_speech_end = self.last_speech_end - used if self.last_speech_end > used else None
                self.utterance += 1
                self.samples_at_last_pass = 0
                if self.finished and len(self.buf) == 0:
                    return

    def summary(self):
        minutes = (self.offset + len(self.buf)) / RATE / 60
        if not self.final_seconds:
            return f"{minutes:.1f} min of audio, no lines"
        median = sorted(self.final_seconds)[len(self.final_seconds) // 2]
        return (f"{minutes:.1f} min of audio, {self.lines} lines, {self.empty_finals} finished empty, "
                f"finished-line pass median {median:.2f} s, worst {max(self.final_seconds):.2f} s")

    async def _wait(self):
        try:
            await asyncio.wait_for(self.changed.wait(), timeout=0.05)
        except asyncio.TimeoutError:
            pass


REPORTS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "reports")
MAX_REPORT_CHARS = 1_000_000


def save_report(text, client):
    """A diagnostics report the phone sent (Settings, Diagnostics), kept
    next to the server for whoever looks after the phone. Older ones stay;
    only the newest 50 are kept."""
    os.makedirs(REPORTS_DIR, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    name, n = stamp + ".txt", 1
    while os.path.exists(os.path.join(REPORTS_DIR, name)):
        n += 1
        name = f"{stamp}-{n}.txt"
    with open(os.path.join(REPORTS_DIR, name), "w", encoding="utf-8") as f:
        f.write(f"from: {client or 'unknown app'}\n\n")
        f.write(text[:MAX_REPORT_CHARS])
    reports = sorted(n for n in os.listdir(REPORTS_DIR) if n.endswith(".txt"))
    for old in reports[:-50]:
        os.remove(os.path.join(REPORTS_DIR, old))
    return name


async def handle(ws, transcriber, token, live_interval):
    peer = ws.remote_address
    try:
        hello = json.loads(await asyncio.wait_for(ws.recv(), timeout=10))
    except Exception:
        hello = None
    if not isinstance(hello, dict):
        await ws.send(json.dumps({"type": "error", "code": "bad_request", "detail": "hello expected"}))
        return
    if hello.get("type") != "hello" or not hmac.compare_digest(str(hello.get("token", "")), token):
        log.warning("refused %s", peer)
        await ws.send(json.dumps({"type": "error", "code": "unauthorized", "detail": ""}))
        return
    session = Session(ws, transcriber, hello.get("language", "he"),
                      [str(v) for v in hello.get("vocabulary", [])][:200], live_interval)
    await ws.send(json.dumps({"type": "ready", "model": transcriber.name, "version": PROTOCOL_VERSION}))
    purpose = str(hello.get("purpose", "captions"))[:20]
    client = str(hello.get("client", ""))[:80]
    log.info("session from %s: %s, %s", peer, purpose, client or "unknown app")
    worker = asyncio.create_task(session.run())

    # A pass that fails (a CUDA error, say) must end the connection: an
    # open socket that never sends text again would keep the phone waiting
    # instead of switching to its own model.
    def worker_done(task):
        if not task.cancelled() and task.exception() is not None:
            log.error("session from %s failed: %r", peer, task.exception())
            asyncio.ensure_future(ws.close(code=1011, reason="transcription failed"))

    worker.add_done_callback(worker_done)
    try:
        async for message in ws:
            if isinstance(message, bytes):
                session.add_audio(message)
                continue
            try:
                msg = json.loads(message)
            except ValueError:
                continue
            if not isinstance(msg, dict):
                continue
            if msg.get("type") == "vocabulary":
                session.vocabulary = [str(v) for v in msg.get("terms", [])][:200]
            elif msg.get("type") == "report":
                name = save_report(str(msg.get("text", "")), client)
                log.info("report from %s saved as %s", peer, name)
                await ws.send(json.dumps({"type": "report_saved", "name": name}))
            elif msg.get("type") == "end":
                session.finished = True
                session.changed.set()
                break
        # A phone that only checked whether the server is there hangs up
        # without "end"; its worker would otherwise wait for audio forever.
        if session.finished:
            await worker
    except websockets.ConnectionClosed:
        pass
    except Exception as error:
        log.error("session from %s ended with %r", peer, error)
    finally:
        worker.cancel()
        log.info("session from %s ended: %s", peer, session.summary())


async def main():
    p = argparse.ArgumentParser()
    p.add_argument("--host", default="0.0.0.0")
    p.add_argument("--port", type=int, default=8765)
    p.add_argument("--model", default="ivrit-ai/whisper-large-v3-turbo-ct2")
    p.add_argument("--device", default="cuda")
    p.add_argument("--compute-type", default="float16")
    # Finished lines only; live passes stay greedy. Measured on the 2080 Ti
    # with large-v3 for finished lines: conversation WER 8.9 -> 8.3%,
    # lectures 12.8 -> 12.7%, about 0.15 s more per finished line.
    p.add_argument("--beam", type=int, default=5)
    p.add_argument("--final-model", default="",
                   help="a stronger model for finished lines only, e.g. ivrit-ai/whisper-large-v3-ct2")
    p.add_argument("--context", action="store_true")
    p.add_argument("--speech-gate", type=float, default=0.05,
                   help="skip a line when less than this share of it is a voice; 0 turns it off")
    p.add_argument("--live-interval", type=float, default=0.3)
    args = p.parse_args()
    token = os.environ.get("OZEN_TOKEN")
    if not token:
        raise SystemExit("set OZEN_TOKEN to the pairing code the phone will send")
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")
    transcriber = Transcriber(args.model, args.device, args.compute_type, args.beam, args.context, args.final_model or None,
                              args.speech_gate)
    # Warm the model so the first sentence isn't slow.
    await transcriber.transcribe(np.zeros(RATE, dtype=np.float32), "he", None, False)
    await transcriber.transcribe(np.zeros(RATE, dtype=np.float32), "he", None, True)
    async with websockets.serve(lambda ws: handle(ws, transcriber, token, args.live_interval),
                                args.host, args.port, max_size=2**22, ping_interval=10, ping_timeout=20):
        log.info("listening on %s:%d with %s", args.host, args.port, transcriber.name)
        await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(main())
