import sys
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


if __name__ == "__main__":
    unittest.main()
