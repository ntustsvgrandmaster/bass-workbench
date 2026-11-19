"""Compare chord context against cached evidence, without opening or writing a project."""

import argparse
from itertools import groupby
import json
from pathlib import Path
from statistics import median
import sys
from time import perf_counter

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "worker"))
from analysis import rank_chord_templates
from harmony_context import contextualize, margins


def labels(rows):
    return [(row["root"], row["chord"]) for row in rows]


def evaluate_labeled(regions, predictions):
    pairs = list(zip(regions, predictions, strict=True))
    root_examples = [(region, row) for region, row in pairs if region["root"] is not None]
    chord_examples = [(region, row) for region, row in pairs if region["chord"] is not None]
    no_chord = [row for region, row in pairs if region["root"] is None]
    correct_root = sum(region["root"] == row["root"] for region, row in root_examples)
    correct_root_with_quality = sum(region["root"] == row["root"] for region, row in chord_examples)
    correct_chord = sum(region["chord"] == row["chord"] for region, row in chord_examples)
    return {
        "rootCorrect": correct_root,
        "rootAnswered": sum(row["root"] is not None for _, row in root_examples),
        "rootExamples": len(root_examples),
        "qualityGivenCorrectRoot": [correct_chord, correct_root_with_quality],
        "chordCorrect": correct_chord,
        "chordAnswered": sum(row["chord"] is not None for _, row in chord_examples),
        "chordExamples": len(chord_examples),
        "noChordFalseRoot": sum(row["root"] is not None for row in no_chord),
        "noChordFalseChord": sum(row["chord"] is not None for row in no_chord),
        "noChordExamples": len(no_chord),
    }


def risk_coverage(regions, predictions):
    root, chord = [], []
    for region, row in zip(regions, predictions, strict=True):
        if region["root"] is None or not row["candidates"]:
            continue
        context = row.get("context")
        if context:
            root_score, quality_score = context["rootMargin"], context["qualityMargin"]
            root_correct = context["candidateRoot"] == region["root"]
            chord_correct = context["candidate"] == region["chord"]
        else:
            _, candidates = rank_chord_templates(row["chroma"])
            root_score, quality_score = margins(candidates, lambda x: x["score"])
            root_correct = candidates[0]["root"] == region["root"]
            chord_correct = candidates[0]["symbol"] == region["chord"]
        root.append((root_score, root_correct))
        if region["chord"] is not None:
            chord.append((min(root_score, quality_score), chord_correct))

    def points(items, label):
        total = sum(row[label] is not None for row in regions)
        # Collapse identical scores so the result does not depend on input order.
        result = []
        count = errors = 0
        for _, tied in groupby(sorted(items, key=lambda row: row[0], reverse=True), key=lambda row: row[0]):
            for _, correct in tied:
                count += 1
                errors += not correct
            result.append({"coverage": count / total, "risk": errors / count})
        return result

    return {"root": points(root, "root"), "chord": points(chord, "chord")}


def compare(groups, repeat=3):
    regions = [region for group in groups for region in group]
    baseline = [region["result"] for region in regions]
    labeled = all("chord" in region for region in regions)
    output = {}
    for name in ("template", "key", "key+neighbors"):
        predictions = baseline
        mode = {}
        if name != "template":
            times = []
            for _ in range(repeat):
                begin = perf_counter()
                passes = [contextualize(group, use_neighbors=name == "key+neighbors") for group in groups]
                times.append(perf_counter() - begin)
            predictions = [row for rows, _ in passes for row in rows]
            mode["seconds"] = times
            mode["medianSeconds"] = median(times)
            mode["keys"] = [key.name if key else None for _, key in passes]
        mode["changes"] = [
            {"index": index, "start": region["start"], "before": before, "after": after,
             "reference": region.get("chord")}
            for index, (region, before, after) in enumerate(zip(regions, labels(baseline), labels(predictions), strict=True))
            if before != after
        ]
        if labeled:
            mode["metrics"] = evaluate_labeled(regions, predictions)
            mode["riskCoverage"] = risk_coverage(regions, predictions)
        output[name] = mode
    return output


def load_groups(payload):
    if isinstance(payload, dict):
        return payload.get("tracks") or [payload["results"]]
    # Legacy synthetic captures are separate 1.5-second regions grouped by detuning.
    # There is no composed progression, so leave a gap to disable adjacent-chord bonuses.
    return [
        [dict(row, start=index * 2.0, end=index * 2.0 + 1.5) for index, row in enumerate(group)]
        for _, group in groupby(payload, key=lambda row: row["cents"])
    ]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", type=Path)
    args = parser.parse_args()
    result = compare(load_groups(json.loads(args.capture.read_text())))
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
