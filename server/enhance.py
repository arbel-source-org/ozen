"""Light noise cleaning for far-away speech, mixed half and half with the
original.

GTCRN (MIT, github.com/Xiaobin-Rong/gtcrn) is a 48 k parameter speech
enhancer that runs on the CPU in about a thirteenth of real time. Fully
cleaned audio made Whisper worse everywhere (conversation 8.3 -> 10.3 %
words wrong, far away 21.9 -> 27.6 %); half cleaned, half original helped
far-away lectures 21.4 -> 19.4 % without hurting clean conversation
(bench_gtcrn.py / bench_gtcrn2.py on the home computer, 2026-09-27).

Works on the stream as it arrives: every 256 new samples make one frame,
and the output lags the input by 256 samples (16 ms).
"""

import numpy as np
import onnxruntime

HOP = 256
N_FFT = 512
WINDOW = np.sqrt(0.5 - 0.5 * np.cos(2 * np.pi * np.arange(N_FFT) / N_FFT)).astype(np.float32)


class StreamingEnhancer:
    def __init__(self, model_path, mix=0.5):
        self.session = onnxruntime.InferenceSession(model_path, None, providers=["CPUExecutionProvider"])
        self.mix = mix
        self.conv_cache = np.zeros([2, 1, 16, 16, 33], np.float32)
        self.tra_cache = np.zeros([2, 3, 1, 1, 16], np.float32)
        self.inter_cache = np.zeros([2, 1, 33, 16], np.float32)
        self.history = np.zeros(N_FFT, np.float32)
        self.pending = np.zeros(0, np.float32)
        self.overlap = np.zeros(HOP, np.float32)
        self.delayed = np.zeros(HOP, np.float32)

    def process(self, samples):
        """Takes any number of new samples; returns as many as are ready."""
        self.pending = np.concatenate([self.pending, samples.astype(np.float32)])
        out = []
        while len(self.pending) >= HOP:
            hop, self.pending = self.pending[:HOP], self.pending[HOP:]
            self.history = np.concatenate([self.history[HOP:], hop])
            spectrum = np.fft.rfft(self.history * WINDOW)
            frame = np.stack([spectrum.real, spectrum.imag], -1)[None, :, None, :].astype(np.float32)
            enhanced, self.conv_cache, self.tra_cache, self.inter_cache = self.session.run([], {
                "mix": frame, "conv_cache": self.conv_cache,
                "tra_cache": self.tra_cache, "inter_cache": self.inter_cache})
            e = enhanced[0, :, 0, :]
            wave = np.fft.irfft(e[:, 0] + 1j * e[:, 1], n=N_FFT).astype(np.float32) * WINDOW
            ready = self.overlap + wave[:HOP]
            self.overlap = wave[HOP:]
            # The original, delayed by the same hop, so the two line up.
            original, self.delayed = self.delayed, hop
            out.append(self.mix * ready + (1 - self.mix) * original)
        return np.concatenate(out) if out else np.zeros(0, np.float32)
