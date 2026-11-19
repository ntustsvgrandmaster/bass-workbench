import hashlib
import math
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

import numpy as np
import soundfile as sf

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "worker"))
import analysis


class TempoTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.sr = 22050

    def tearDown(self):
        self.temporary.cleanup()

    def asset(self, audio, offset=0):
        path = self.root / "clicks.wav"
        sf.write(path, audio, self.sr, subtype="FLOAT")
        return dict(path=str(path), hash=hashlib.sha256(path.read_bytes()).hexdigest(), offset=offset)

    def clicks(self, bpm, duration=16):
        audio = np.zeros(int(duration * self.sr), dtype=np.float32)
        pulse = .6 * np.hanning(120) * np.sin(2 * np.pi * 1500 * np.arange(120) / self.sr)
        for second in np.arange(.5, duration - .1, 60 / bpm):
            first = int(second * self.sr)
            audio[first:first + len(pulse)] += pulse
        return audio

    def test_regular_clicks_and_half_double_candidates(self):
        for bpm in [90, 120, 150]:
            result = analysis.tempo_job(dict(asset=self.asset(self.clicks(bpm))))
            self.assertIsNotNone(result["bpm"])
            self.assertLess(abs(result["bpm"] - bpm), 3)
            self.assertGreater(len(result["beats"]), 8)
            self.assertEqual(len(result["alternatives"]), 3)
            self.assertTrue(all(math.isfinite(t) and 0 <= t < 16 for t in result["beats"]))
            self.assertNotIn("meter", result)  # A pulse is never an inferred downbeat or meter.

    def test_silence_sustained_tone_and_short_audio_abstain(self):
        for audio in [np.zeros(self.sr * 12), .1 * np.sin(2 * np.pi * 220 * np.arange(self.sr * 12) / self.sr),
                      self.clicks(120, duration=3)]:
            result = analysis.tempo_job(dict(asset=self.asset(audio)))
            self.assertIsNone(result["bpm"])
            self.assertEqual(result["beats"], [])
            self.assertTrue(result["warnings"])

    def test_offsets_use_master_time_and_preserve_original(self):
        audio = self.clicks(120)
        asset = self.asset(audio, offset=5)
        before = Path(asset["path"]).read_bytes()
        result = analysis.tempo_job(dict(asset=asset))
        self.assertEqual(result["start"], 5)
        self.assertEqual(result["end"], 21)
        self.assertTrue(all(5 <= t < 21 for t in result["beats"]))
        self.assertEqual(before, Path(asset["path"]).read_bytes())

    def test_half_integer_and_float_fallback_against_known_onsets(self):
        for truth, floating in [(120.5, False), (120.22, True)]:
            result = analysis.tempo_job(dict(asset=self.asset(self.clicks(truth, duration=90))))
            primary = next(c for c in result['candidates'] if c['multiplier'] == 1)
            self.assertLess(abs(result['bpm'] - truth), .02)
            self.assertEqual(primary['usedFloat'], floating)
            self.assertLess(primary['fit']['p95Ms'], 20)
            # Compare raw observed times to independent, sample-generated click truth.
            true_times = np.arange(.5, 89.9, 60 / truth)
            errors = [min(abs(true_times - t)) for t in result['beats']]
            self.assertLess(np.percentile(errors, 95), .025)
            if floating:
                self.assertGreater(primary['quantizedFit']['p95Ms'], 30)
                self.assertNotEqual(primary['fit']['intercept'], primary['quantizedFit']['intercept'])

    def test_missing_onsets_and_nonconstant_tempo_do_not_fake_a_good_grid(self):
        audio = self.clicks(120, duration=40)
        for second in np.arange(5, 35, 4):
            audio[int(second * self.sr):int((second + .6) * self.sr)] = 0
        result = analysis.tempo_job(dict(asset=self.asset(audio)))
        self.assertLess(abs(result['bpm'] - 120), .1)
        varying = np.zeros(self.sr * 40, dtype=np.float32)
        second, n = .5, 0
        while second < 39.8:
            first = int(second * self.sr)
            varying[first:first+120] = .6 * np.hanning(120) * np.sin(2 * np.pi * 1500 * np.arange(120) / self.sr)
            second += .42 + .16 * second / 40
            n += 1
        result = analysis.tempo_job(dict(asset=self.asset(varying)))
        if result['bpm'] is not None:
            primary = next(c for c in result['candidates'] if c['multiplier'] == 1)
            self.assertNotIn(primary['fit']['status'], ['good', 'borderline'])

    def test_bounded_read_and_invalid_offset(self):
        asset = self.asset(self.clicks(120, duration=100))
        with patch.object(analysis, "read_region", wraps=analysis.read_region) as read:
            result = analysis.tempo_job(dict(asset=asset))
            self.assertEqual(result["end"] - result["start"], 90)
            read.assert_called_once_with(asset, 0.0, 90.0, padding=0)
        with self.assertRaises(ValueError):
            analysis.tempo_job(dict(asset=dict(asset, offset=float("nan"))))


if __name__ == "__main__":
    unittest.main(verbosity=2)
