"""Experimental second pass over cached chord regions.

Template scores remain acoustic similarities. Context scores are kept separately.
"""

from dataclasses import dataclass

import numpy as np

from analysis import PITCH_NAMES, rank_chord_templates


# Krumhansl–Kessler major/minor key profiles, rotated to each tonic.
KEY_PROFILES = (
    (6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88),
    (6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17),
)
KEY_MATRIX = np.array([np.roll(profile, tonic) for profile in KEY_PROFILES for tonic in range(12)])
KEY_MATRIX -= KEY_MATRIX.mean(axis=1, keepdims=True)
KEY_MATRIX /= np.linalg.norm(KEY_MATRIX, axis=1, keepdims=True)
SCALES = ({0, 2, 4, 5, 7, 9, 11}, {0, 2, 3, 5, 7, 8, 10})
COMMON_ROOT_MOVES = (
    {(2, 7), (5, 7), (5, 0), (7, 0), (9, 2), (9, 5)},
    {(2, 7), (5, 7), (5, 0), (7, 0), (8, 5)},
)


@dataclass(frozen=True)
class Key:
    tonic: int
    minor: bool
    margin: float

    @property
    def name(self):
        return PITCH_NAMES[self.tonic] + (" minor" if self.minor else " major")


def estimate_key(chroma, duration):
    active = np.linalg.norm(chroma, axis=1) > 1e-8
    if active.sum() < 3:
        return None
    aggregate = (chroma[active] * np.minimum(duration[active, None], 8)).sum(axis=0)
    aggregate -= aggregate.mean()
    norm = np.linalg.norm(aggregate)
    if norm < 1e-8:
        return None
    scores = KEY_MATRIX @ (aggregate / norm)
    first, second = np.argsort(scores)[-2:][::-1]
    margin = float(scores[first] - scores[second])
    if scores[first] < 0.55 or margin < 0.035:
        return None
    return Key(int(first % 12), bool(first >= 12), margin)


def key_bonus(candidate, key):
    if key is None:
        return 0.0
    degree = (candidate["root"] - key.tonic) % 12
    third = 4 if candidate["quality"] == "maj" else 3
    degrees = {degree, (degree + third) % 12, (degree + 7) % 12}
    return 0.025 * min(1, key.margin / 0.12) if degrees <= SCALES[key.minor] else 0.0


def transition_bonus(left, right, key):
    if left["symbol"] == right["symbol"]:
        return 0.008
    if left["quality"] == "maj" and (right["root"] - left["root"]) % 12 == 5:
        return 0.026
    if key is not None:
        pair = ((left["root"] - key.tonic) % 12, (right["root"] - key.tonic) % 12)
        if pair in COMMON_ROOT_MOVES[key.minor] and key_bonus(left, key) and key_bonus(right, key):
            return 0.016
    return 0.0


def margins(ranked, score):
    best = ranked[0]
    other_root = next(x for x in ranked if x["root"] != best["root"])
    other_quality = next(x for x in ranked[1:] if x["root"] == best["root"])
    return score(best) - score(other_root), score(best) - score(other_quality)


def contextualize(regions, use_neighbors=True):
    """Return evidence copies for ordered, nonoverlapping regions in master seconds."""
    if not regions:
        return [], None
    evidence = [region["result"] for region in regions]
    original = [rank_chord_templates(row["chroma"]) if row["candidates"] else (np.zeros(12), [])
                for row in evidence]
    chroma = np.array([normalized for normalized, _ in original])
    duration = np.array([row["end"] - row["start"] for row in regions])
    global_key = estimate_key(chroma, duration)
    # Neighbors are frozen acoustic labels so guesses cannot reinforce each other.
    reliable = []
    for row, (_, candidates) in zip(evidence, original):
        confidence = margins(candidates, lambda x: x["score"]) if candidates else (0, 0)
        reliable.append(candidates[0] if row["chord"] and confidence[0] >= 0.07 and confidence[1] >= 0.09 else None)

    output = []
    for i, (row, (c, candidates)) in enumerate(zip(evidence, original)):
        result = dict(row)
        output.append(result)
        if not candidates or reliable[i] is not None:
            continue
        nearby = slice(max(0, i - 4), i + 5)
        local_key = estimate_key(chroma[nearby], duration[nearby])
        key = global_key
        if local_key is not None and local_key.margin >= 0.10:
            key = local_key
        previous = following = None
        if use_neighbors and i > 0 and abs(regions[i]["start"] - regions[i - 1]["end"]) < 0.025:
            previous = reliable[i - 1]
        if use_neighbors and i + 1 < len(regions) and abs(regions[i + 1]["start"] - regions[i]["end"]) < 0.025:
            following = reliable[i + 1]
        raw_top = candidates[0]["score"]

        def score(candidate):
            base = candidate["score"]
            if base < max(0.70, raw_top - 0.05) or len(candidate["support"]) < 2:
                return base
            return (base + key_bonus(candidate, key)
                    + (transition_bonus(previous, candidate, key) if previous else 0)
                    + (transition_bonus(candidate, following, key) if following else 0))

        scores = {candidate["symbol"]: score(candidate) for candidate in candidates}

        def contextual_score(candidate):
            return scores[candidate["symbol"]]

        ranked = sorted(candidates, key=contextual_score, reverse=True)
        best = ranked[0]
        root_margin, quality_margin = margins(ranked, contextual_score)
        result["context"] = dict(key=key.name if key else None, candidate=best["symbol"], candidateRoot=best["root"],
                                 rootMargin=root_margin, qualityMargin=quality_margin)
        if root_margin < 0.045 or best["score"] < 0.70 or len(best["support"]) < 2:
            continue
        third = (best["root"] + (4 if best["quality"] == "maj" else 3)) % 12
        chord = best["symbol"] if quality_margin >= 0.06 and c[third] >= 0.25 * c.max() else None
        if chord is None and row["chord"] is not None:
            continue
        result.update(root=best["root"], chord=chord)
    return output, global_key
