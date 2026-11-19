import hashlib
import json
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

import numpy as np
import soundfile as sf

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "worker"))
from analysis import feature_job, harmony_job, chord_candidates, SOURCE_HARMONY_METHOD, TUNED_HARMONY_METHOD

class AnalysisTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.sr = 22050

    def tearDown(self):
        self.temporary.cleanup()

    def asset(self, y, name="source", role="bass"):
        path = self.root / f"{name}.wav"
        sf.write(path, y, self.sr, subtype="FLOAT")
        return dict(path=str(path), hash=hashlib.sha256(path.read_bytes()).hexdigest(), offset=0, role=role)

    def feature_request(self, asset, **updates):
        result = dict(asset=asset, start=0, end=3, minMIDI=23, maxMIDI=60, binsPerOctave=24, cache=str(self.root / "cache"))
        result.update(updates)
        return result

    def test_cqt_frequency_and_cache(self):
        t = np.arange(self.sr*3)/self.sr
        for pitch in [23, 28, 40]:
            f = 440*2**((pitch-69)/12)
            asset = self.asset(.2*np.sin(2*np.pi*f*t), str(pitch))
            request = self.feature_request(asset)
            first = feature_job(request)
            matrix = np.fromfile(first["binaryPath"], dtype="<f4").reshape(first["rows"], first["columns"])
            peak = int(np.median(matrix[:, 50:-50].argmax(axis=0)))
            self.assertLessEqual(abs(peak-(pitch-23)*2), 1)
            self.assertLess(float(matrix.max()), 3)  # no filter-length gain saturation
            second = feature_job(request)
            self.assertTrue(second["cacheHit"])
            self.assertEqual(first["cacheKey"], second["cacheKey"])
            before = hashlib.sha256(Path(asset["path"]).read_bytes()).hexdigest()
            Path(first["binaryPath"]).write_bytes(b"broken")
            recovered = feature_job(request)
            self.assertFalse(recovered["cacheHit"])
            self.assertEqual(before, hashlib.sha256(Path(asset["path"]).read_bytes()).hexdigest())

    def test_bass_stem_octave_with_strong_second_harmonic(self):
        t = np.arange(self.sr * 3) / self.sr
        for pitch in (23, 28, 40):
            f = 440 * 2 ** ((pitch - 69) / 12)
            signal = .08 * np.sin(2 * np.pi * f * t) + .25 * np.sin(4 * np.pi * f * t)
            bass = self.asset(signal, f"harmonics-{pitch}")
            data = feature_job(self.feature_request(bass))
            spectrum = np.fromfile(data["binaryPath"], dtype="<f4").reshape(data["rows"], data["columns"])
            peak = int(np.median(spectrum[:, 50:-50].argmax(axis=0)))
            self.assertEqual(23 + peak / 2, pitch + 12)
            result = harmony_job(dict(arrangement=bass, bass=bass, start=0, end=3))
            self.assertEqual(result["firstPitch"], pitch)
        pure = self.asset(.25 * np.sin(2 * np.pi * 82.4069 * t), "pure-e2")
        self.assertEqual(harmony_job(dict(arrangement=pure, bass=pure, start=0, end=3))["firstPitch"], 40)

    def test_bass_pitch_guide_backfills_cached_spectrum_with_offset(self):
        t = np.arange(self.sr * 3) / self.sr
        f = 41.2034
        bass = self.asset(.08 * np.sin(2 * np.pi * f * t) + .25 * np.sin(4 * np.pi * f * t))
        bass["offset"] = 0.45
        request = self.feature_request(bass)
        original = feature_job(request)
        binary = Path(original["binaryPath"]).read_bytes()
        upgraded = feature_job(dict(request, pitchGuide=True))
        self.assertTrue(upgraded["cacheHit"])
        self.assertEqual(original["cacheKey"], upgraded["cacheKey"])
        self.assertEqual(binary, Path(upgraded["binaryPath"]).read_bytes())
        trace = upgraded["pitchTrace"]
        self.assertGreater(len(trace), 20)
        self.assertGreaterEqual(trace[0]["time"], bass["offset"])
        self.assertLessEqual(trace[-1]["time"], request["end"])
        self.assertAlmostEqual(float(np.median([p["midi"] for p in trace])), 28, delta=.3)
        self.assertEqual(feature_job(request)["pitchTrace"], trace)

    def test_independent_first_note_and_root(self):
        t = np.arange(self.sr*3)/self.sr
        bass = self.asset(.17*np.sin(2*np.pi*82.4069*t), "bass")
        harmony = sum(.12*np.sin(2*np.pi*f*t) for f in [261.6256, 329.6276, 391.9954])
        arrangement = self.asset(harmony, "arrangement", "accompaniment")
        result = harmony_job(dict(arrangement=arrangement, bass=bass, start=0, end=3, timingRevision=4))
        self.assertEqual(result["firstPitch"], 40)  # E2
        self.assertEqual(result["root"], 0)          # C root, not E
        self.assertEqual(result["chord"], "C")
        self.assertEqual(result["timingRevision"], 4)
        self.assertNotEqual(result["arrangementSource"], result["bassSource"])
        request=dict(arrangement=arrangement,bass=bass,start=0,end=3,timingRevision=4,cache=str(self.root/"harmony-cache"))
        first=harmony_job(request)
        second=harmony_job(dict(request,timingRevision=5))
        self.assertFalse(first["cacheHit"]);self.assertTrue(second["cacheHit"])
        self.assertEqual(second["timingRevision"],5)
        self.assertEqual(first["root"],second["root"])
        cache_path=self.root/"harmony-cache"/f"harmony-{first['cacheKey']}.json"
        cache_path.write_text("broken")
        self.assertFalse(harmony_job(request)["cacheHit"])

    def test_first_note_survives_uncertain_root(self):
        t = np.arange(self.sr*3)/self.sr
        bass = self.asset(.2*np.sin(2*np.pi*41.2034*t), "bass")
        silence = self.asset(np.zeros(self.sr*3), "silence", "accompaniment")
        # Direct templates must abstain on a single pitch class or uniform evidence.
        _, root, chord, _ = chord_candidates(np.ones(12))
        self.assertIsNone(root);self.assertIsNone(chord)
        # Valid bass evidence must not be erased just because the arrangement is silent.
        result = harmony_job(dict(arrangement=silence, bass=bass, start=0, end=3))
        self.assertIsNone(result["root"])
        self.assertEqual(result["firstPitch"], 28)

    def test_silence_and_noise_do_not_force_first_note(self):
        for name, y in [("silence", np.zeros(self.sr*3)), ("noise", np.random.default_rng(7).normal(0,.04,self.sr*3))]:
            asset = self.asset(y, name, "original")
            result = harmony_job(dict(arrangement=asset, bass=asset, start=0, end=3))
            self.assertIsNone(result["firstPitch"])

    def test_major_minor(self):
        for root in [0, 2, 7, 11]:
            for quality, third in [("maj",4),("min",3)]:
                c = np.zeros(12);c[(root+np.array([0,third,7]))%12] = [1,.95,.8]
                candidates, inferred, _, _ = chord_candidates(c)
                self.assertEqual(inferred,root)
                self.assertEqual(candidates[0]["quality"],quality)

    def test_source_tiles_across_boundary_and_after_realigning(self):
        from harmony_features import CHUNK, HOP, chroma_chunk

        t = np.arange(CHUNK * HOP + self.sr * 2) / self.sr
        accompaniment = self.asset(sum(.08 * np.sin(2*np.pi*f*t) for f in (261.6256, 329.6276, 391.9954)),
                                   "harmony", "original")
        bass = self.asset(.2 * np.sin(2*np.pi*41.2034*t), "low")
        edge = CHUNK * HOP / self.sr
        cache = self.root / "tiles"
        request = dict(arrangement=accompaniment, bass=bass, start=edge-0.31, end=edge+0.41, cache=str(cache))
        before = harmony_job(request)
        after = harmony_job(dict(request, method=SOURCE_HARMONY_METHOD))
        np.testing.assert_allclose(before["chroma"], after["chroma"], atol=.012)
        self.assertEqual([x["symbol"] for x in before["candidates"][:2]],
                         [x["symbol"] for x in after["candidates"][:2]])
        self.assertEqual((after["chord"], after["firstPitch"]), ("C", 28))
        self.assertLess(abs(after["firstTime"]-before["firstTime"]), HOP/self.sr)
        with patch("harmony_features.librosa.decompose.hpss", side_effect=AssertionError("unexpected HPSS")):
            shifted = harmony_job(dict(request, method=SOURCE_HARMONY_METHOD, start=edge-0.27, end=edge+0.45))
            self.assertEqual((shifted["chord"], shifted["firstPitch"]), ("C", 28))
            tuned = harmony_job(dict(request, method=TUNED_HARMONY_METHOD))
            self.assertLessEqual(abs(tuned["tuningCents"]), 5)
            chroma_chunk(cache / "source-harmony", accompaniment["path"], accompaniment["hash"], 0, 0.0,
                         low_hz=100, high_hz=2000)

    def test_global_tuning_recovers_detuned_reference(self):
        t = np.arange(self.sr * 6) / self.sr
        tuning = 2**(.34/12)
        arrangement = self.asset(sum(.10*np.sin(2*np.pi*f*tuning*t) for f in (261.6256, 329.6276, 391.9954)),
                                 "detuned", "original")
        bass = self.asset(.22*np.sin(2*np.pi*41.2034*t), "bass")
        result = harmony_job(dict(arrangement=arrangement, bass=bass, start=1, end=3,
                                  cache=str(self.root / "tuned"), method=TUNED_HARMONY_METHOD))
        self.assertAlmostEqual(result["tuningCents"], 34, delta=5)
        self.assertEqual((result["chord"], result["firstPitch"]), ("C", 28))

if __name__ == "__main__":
    unittest.main(verbosity=2)
