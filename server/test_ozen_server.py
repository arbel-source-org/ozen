import asyncio
import sys
import time
import types
import unittest

import numpy as np

fake = types.ModuleType("faster_whisper")
fake.WhisperModel = object
fake_vad = types.ModuleType("faster_whisper.vad")
fake_vad.VadOptions = lambda **kw: kw
fake_vad.get_speech_timestamps = lambda *a, **kw: []
sys.modules.setdefault("faster_whisper", fake)
sys.modules.setdefault("faster_whisper.vad", fake_vad)
sys.modules.setdefault("websockets", types.ModuleType("websockets"))
if not hasattr(sys.modules["websockets"], "ConnectionClosed"):
    sys.modules["websockets"].ConnectionClosed = type("ConnectionClosed", (Exception,), {})

import ozen_server as S


class Model:
    def __init__(self):
        self.beams = []

    def transcribe(self, audio, **kw):
        self.beams.append(kw["beam_size"])
        return [], None


class Beam(unittest.TestCase):
    def test_only_a_sensible_beam_from_the_phone_counts(self):
        self.assertEqual(S.requested_beam(2), 2)
        self.assertEqual(S.requested_beam(10), 10)
        for junk in (None, 0, 11, -1, "3", 2.5, True):
            self.assertIsNone(S.requested_beam(junk), junk)

    def test_finished_lines_use_the_phones_beam_and_live_passes_stay_greedy(self):
        t = S.Transcriber.__new__(S.Transcriber)
        t.model = t.final_model = Model()
        t.beam, t.context, t.speech_gate = 5, 0, 0.0
        audio = np.zeros(1600, dtype=np.float32)
        t._run(audio, "he", None, True, beam=2)
        t._run(audio, "he", None, True)
        t._run(audio, "he", None, False, beam=2)
        self.assertEqual(t.model.beams, [2, 5, 1])


class SlowGPU:
    """Stands in for the Transcriber: each pass takes a while, as on a GPU."""
    context = False

    def __init__(self, live_seconds):
        self.live_seconds = live_seconds
        self.passes = []

    async def transcribe(self, audio, language, prompt, final, hotwords=None, gate=True, beam=None):
        self.passes.append((time.monotonic(), final))
        await asyncio.sleep(0.05 if final else self.live_seconds)
        return ("שלום" if final else "של"), 0.9, []


class Socket:
    def __init__(self):
        self.sent = []

    async def send(self, text):
        self.sent.append(text)


def pcm(seconds, level):
    n = int(seconds * S.RATE)
    wave = level * np.sin(np.arange(n) * 2 * np.pi * 300 / S.RATE)
    return (wave * 32767).astype("<i2").tobytes()


class PauseEnd(unittest.TestCase):
    def play(self):
        gpu = SlowGPU(live_seconds=0.25)
        session = S.Session(Socket(), gpu, "he", [], live_interval=0.3)

        async def feed():
            worker = asyncio.create_task(session.run())
            for seconds, level in ((0.6, 0.0005), (1.5, 0.3), (1.6, 0.0005)):
                chunk = pcm(seconds, level)
                step = int(0.1 * S.RATE) * 2
                for i in range(0, len(chunk), step):
                    session.add_audio(chunk[i:i + step])
                    await asyncio.sleep(0.1)
            session.finished = True
            session.changed.set()
            await asyncio.wait_for(worker, 5)

        asyncio.run(feed())
        return gpu, session

    def test_no_live_pass_reads_only_silence_and_the_final_starts_at_the_pause(self):
        gpu, session = self.play()
        finals = [t for t, final in gpu.passes if final]
        self.assertEqual(len(finals), 1)
        speech_over = [t for t, final in gpu.passes if not final]
        # One live pass may read the last words; none may only reread them.
        after_last_words = [t for t in speech_over if t > finals[0] - 0.7]
        self.assertLessEqual(len(after_last_words), 1, gpu.passes)
        self.assertLess(session.final_lag_seconds[0], 0.15, session.final_lag_seconds)


class GoneSocket:
    remote_address = ("203.0.113.9", 4444)

    async def recv(self):
        raise S.websockets.ConnectionClosed()

    async def send(self, text):
        raise S.websockets.ConnectionClosed()


class HungUp(unittest.TestCase):
    def test_a_peer_that_hangs_up_before_the_hello_ends_quietly(self):
        asyncio.run(S.handle(GoneSocket(), None, "code", 1.0))


class HelloSocket:
    remote_address = ("203.0.113.9", 4444)

    def __init__(self, hello):
        self.hello = hello
        self.sent = []

    async def recv(self):
        return self.hello

    async def send(self, text):
        self.sent.append(text)


class WrongCode(unittest.TestCase):
    def test_the_refusal_never_repeats_either_code(self):
        guess = "guessed-code-123"
        ws = HelloSocket(S.json.dumps({"type": "hello", "token": guess}))
        with self.assertLogs(S.log, "WARNING"):
            asyncio.run(S.handle(ws, None, "real-code-456", 1.0))
        self.assertEqual(len(ws.sent), 1)
        self.assertIn("unauthorized", ws.sent[0])
        self.assertNotIn(guess, ws.sent[0])
        self.assertNotIn("real-code-456", ws.sent[0])


class WorkerEndings(unittest.TestCase):
    def test_a_phone_hanging_up_mid_send_is_not_a_failure(self):
        self.assertFalse(S.worker_failed(S.websockets.ConnectionClosed(None, None)))

    def test_a_real_error_still_counts(self):
        self.assertTrue(S.worker_failed(RuntimeError("CUDA failed")))

    def test_a_clean_finish_is_not_a_failure(self):
        self.assertFalse(S.worker_failed(None))


class ModelsThatWontLoad(unittest.TestCase):
    def test_the_log_says_why_and_the_restart_waits(self):
        from unittest import mock

        def broken(*args, **kwargs):
            raise RuntimeError("CUDA failed with error out of memory")

        with mock.patch.object(S, "Transcriber", broken), \
                mock.patch.object(S.time, "sleep") as sleep, \
                mock.patch.object(sys, "argv", ["ozen_server.py"]), \
                mock.patch.dict("os.environ", {"OZEN_TOKEN": "x"}), \
                self.assertLogs(S.log, "CRITICAL") as logged:
            with self.assertRaises(SystemExit):
                asyncio.run(S.main())
        sleep.assert_called_once_with(S.LOAD_RETRY_SECONDS)
        self.assertIn("out of memory", logged.output[0])
        self.assertIn("graphics card", logged.output[0])


class PromptBudget(unittest.TestCase):
    def test_the_names_at_the_top_are_the_ones_kept(self):
        terms = [f"name{i}" for i in range(100)]
        kept = S.front_terms(terms, lambda text: len(text.split()), 10)
        self.assertEqual(kept, terms[:10])

    def test_a_short_list_is_kept_whole(self):
        self.assertEqual(S.front_terms(["a", "b"], lambda text: len(text), 200), ["a", "b"])


if __name__ == "__main__":
    unittest.main()
