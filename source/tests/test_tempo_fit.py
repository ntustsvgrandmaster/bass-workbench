import math
from pathlib import Path
import sys
import unittest
import numpy as np
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'worker'))
from tempo import quantize_tempo, fit_continuous_tempo, evaluate_fit, select_tempo_candidate, match_observations


class TempoFitTests(unittest.TestCase):
    def test_quantization_and_half_up(self):
        for raw, expected in [(191.04, 191), (191.1, 191), (191.4, 191.5), (191.5, 191.5), (191.75, 192), (20, 20), (400, 400)]:
            self.assertEqual(quantize_tempo(raw), expected)
        for raw in [None, math.nan, math.inf, 19.99, 400.01]:
            with self.assertRaises(ValueError):
                quantize_tempo(raw)

    def test_slope_intercept_missing_beats_and_offset(self):
        indices = np.delete(np.arange(160), [3, 17, 22, 50])
        times = 1.234 + indices * 60 / 120.5
        times[30] += .12
        bpm = fit_continuous_tempo(times, indices)
        self.assertAlmostEqual(bpm, 120.5, places=7)
        fit = evaluate_fit(times, indices, bpm)
        shifted = evaluate_fit(times + 5, indices, bpm)
        self.assertAlmostEqual(fit['intercept'], 1.234, places=7)
        self.assertAlmostEqual(shifted['intercept'], 6.234, places=7)
        self.assertGreater(fit['maxMs'], 100)
        self.assertEqual(fit['status'], 'poor')  # P95 cannot hide a large individual error.

    def test_prefer_quantized_even_if_float_fits_better(self):
        indices = np.arange(20)
        times = .8 + indices * 60 / 120.04
        chosen = select_tempo_candidate(times, indices, 120.04)
        self.assertEqual(chosen['bpm'], 120)
        self.assertFalse(chosen['usedFloat'])
        self.assertGreater(chosen['quantizedFit']['p95Ms'], chosen['originalFit']['p95Ms'])

    def test_float_fallback_uses_own_refitted_intercept(self):
        indices = np.arange(170)
        times = .37 + indices * 60 / 120.22
        chosen = select_tempo_candidate(times, indices, 120.22)
        self.assertTrue(chosen['usedFloat'])
        self.assertEqual(chosen['bpm'], 120.22)
        self.assertAlmostEqual(chosen['fit']['intercept'], .37)
        self.assertNotAlmostEqual(chosen['quantizedFit']['intercept'], chosen['fit']['intercept'])
        self.assertEqual(chosen['fit']['status'], 'good')
        self.assertEqual(chosen['quantizedFit']['status'], 'poor')

    def test_residual_thresholds_and_insufficient_coverage(self):
        indices = np.arange(96)
        # Alternate signed error keeps the median phase and long-term drift at zero.
        for ms, status in [(20, 'good'), (20.01, 'borderline'), (30, 'borderline'), (30.01, 'poor')]:
            times = 1 + indices * .5 + np.where(indices % 2, ms, -ms) / 1000
            self.assertEqual(evaluate_fit(times, indices, 120)['status'], status)
        self.assertEqual(evaluate_fit([1, 2], [0, 2], 120)['status'], 'insufficient')
        self.assertEqual(evaluate_fit(1 + indices * .5, indices, 120, .4)['status'], 'insufficient')

    def test_observations_are_not_filled_in_by_tracker(self):
        times, indices = match_observations([1, 2, 3.5], np.arange(1, 4, .5), .05)
        self.assertEqual(times, [1, 2, 3.5])
        self.assertEqual(indices, [0, 2, 5])
        with self.assertRaises(ValueError):
            fit_continuous_tempo([1, math.nan], [0, 1])
