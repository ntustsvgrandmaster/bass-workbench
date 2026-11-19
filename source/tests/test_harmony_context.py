import sys
from pathlib import Path
import unittest

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "worker"))
from analysis import PITCH_NAMES, chord_candidates
from harmony_context import contextualize, estimate_key


def region(index, root=None, minor=False, weights=(1.0, 0.8, 0.75), extra=None):
    chroma = np.zeros(12)
    symbol = None
    if root is not None:
        pitches = (root, (root + (3 if minor else 4)) % 12, (root + 7) % 12)
        chroma[list(pitches)] = weights
        symbol = PITCH_NAMES[root] + ("m" if minor else "")
    if extra:
        for pitch, weight in extra.items():
            chroma[pitch] = weight
    candidates, predicted_root, chord, margin = chord_candidates(chroma)
    return dict(start=index, end=index + 1, root=root, chord=symbol,
                result=dict(chroma=chroma.tolist(), candidates=candidates, root=predicted_root,
                            chord=chord, rootMargin=margin, firstPitch=28))


class HarmonyContextTests(unittest.TestCase):
    def test_key_uses_pitch_class_profiles_and_abstains_on_uniform_input(self):
        rows = [region(i, root, minor) for i, (root, minor) in enumerate([
            (0, False), (0, False), (5, False), (7, False), (0, False), (9, True),
            (2, True), (7, False), (0, False),
        ])]
        chroma = np.array([row["result"]["chroma"] for row in rows])
        self.assertEqual(estimate_key(chroma, np.ones(len(rows))).name, "C major")
        self.assertEqual(estimate_key(np.roll(chroma, 2, axis=1), np.ones(len(rows))).name, "D major")
        self.assertIsNone(estimate_key(np.ones((5, 12)), np.ones(5)))

    def test_preserves_silence_and_supported_borrowed_chord(self):
        rows = [region(0, 0), region(1, 5), region(2, 5, True),
                region(3), region(4, 7), region(5, 0)]
        output, _ = contextualize(rows)
        self.assertEqual(output[2]["chord"], "Fm")
        self.assertIsNone(output[3]["root"])
        self.assertIsNone(output[3]["chord"])
        self.assertEqual(output[2]["firstPitch"], 28)
        self.assertEqual(output[2]["candidates"], rows[2]["result"]["candidates"])

    def test_neighbor_can_resolve_close_root_without_mutating_evidence(self):
        rows = [region(0, 2, True), region(1, 7, weights=(1, .73, .65), extra={9: .8, 5: .85}),
                region(2, 0)]
        key_only, _ = contextualize(rows, use_neighbors=False)
        context, _ = contextualize(rows)
        self.assertIsNone(key_only[1]["root"])
        self.assertEqual(context[1]["chord"], "G")
        self.assertIsNone(rows[1]["result"]["root"])
        self.assertNotIn("context", rows[1]["result"])

        rows[0]["end"] = .5
        rows[2]["start"] = 2.5
        after_gap, _ = contextualize(rows)
        self.assertEqual(after_gap[1]["root"], key_only[1]["root"])


if __name__ == "__main__":
    unittest.main()
