import sys
import unittest
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "worker"))
from btc_song import STEP, first_bar_phase


class BTCBarPhaseTests(unittest.TestCase):
    def test_recovers_phase_with_missing_beats(self):
        bpm = 190
        beat = 60 / bpm
        start = .438
        downbeats = start + 4 * beat * np.arange(1, 22)
        beats = start + beat * np.arange(0, 88, 2)
        scores = np.zeros((400, 25))
        for i in range(len(scores)):
            root = int(np.floor((i * STEP - start) / (4 * beat))) % 2
            scores[i, root * 2] = 1
        timing = dict(bpm=bpm, beats=beats, downbeats=downbeats, start=0, end=29)
        self.assertAlmostEqual(first_bar_phase(timing, scores, 0), start, delta=.035)

    def test_requires_downbeats_and_chord_changes(self):
        timing = dict(bpm=120, beats=np.arange(.4, 20, .5), downbeats=[.4], start=0, end=20)
        scores = np.zeros((300, 25))
        scores[:, -1] = 1
        self.assertIsNone(first_bar_phase(timing, scores, 0))
        timing["downbeats"] = np.arange(.4, 20, 2)
        self.assertIsNone(first_bar_phase(timing, scores, 0))
