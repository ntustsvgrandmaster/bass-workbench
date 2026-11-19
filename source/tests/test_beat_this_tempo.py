"""Optional backend's numerical tests must run without torch installed."""
import sys
import unittest
from pathlib import Path
import numpy as np
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'worker'))
from beat_this_tempo import beat_candidates

class OptionalTempoTests(unittest.TestCase):
    def test_regular_beats_keep_tempo_and_phase(self):
        c=beat_candidates(.44+np.arange(140)*60/190)
        self.assertEqual(c[0]['bpm'],190)
        self.assertEqual(c[0]['fit']['status'],'good')
        self.assertLess(abs(c[0]['fit']['intercept']-.44),1e-8)
    def test_mixed_metrical_levels_need_review(self):
        x=.44+np.arange(280)*60/190
        beats=np.concatenate([x[:190:2],x[190:]])
        c=beat_candidates(beats)
        self.assertTrue(any(abs(v['bpm']-190)<.1 for v in c))
        self.assertTrue(all(v['fit']['status']=='poor' for v in c))
    def test_first_beat_and_local_tempo_do_not_anchor_entire_grid(self):
        # Mixed half/full speed with 20 ms model resolution, small jitter,
        # and an early first detection. The old first-beat grid returned [].
        grid = 2.94 + np.r_[np.arange(0, 160, 2), np.arange(160, 275)] * 60 / 190
        jitter = np.random.default_rng(0).normal(0, .008, len(grid))
        beats = np.round((grid + jitter) / .02) * .02
        beats[0] -= .09
        candidates = beat_candidates(beats)
        by_bpm = {candidate['bpm']: candidate['fit']['status'] for candidate in candidates}
        self.assertEqual(by_bpm[190], 'poor')
        self.assertEqual(by_bpm[95], 'poor')
    def test_invalid_or_insufficient_stays_empty(self):
        for b in [[],[1,2,3],list(range(8))+[7],list(range(8))+[float('nan')]]:
            self.assertEqual(beat_candidates(b),[])
    def test_optional_import_is_lazy(self):
        self.assertNotIn('torch',sys.modules)
        self.assertNotIn('beat_this',sys.modules)

if __name__=='__main__': unittest.main()
