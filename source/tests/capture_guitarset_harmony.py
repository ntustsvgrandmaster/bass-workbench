"""Capture a retained worker's results for local GuitarSet WAV/JAMS pairs."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import sys

NOTE_INDEX = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}
MAJOR_QUALITIES = {"maj", "maj6", "maj7", "maj9", "7", "9"}
MINOR_QUALITIES = {"min", "min6", "min7", "min9"}


def reference(label, pitch_names):
    if label == "N":
        return None, None
    note, quality = label.split(":", 1)
    root = (NOTE_INDEX[note[0]] + note.count("#") - note.count("b")) % 12
    base_quality = re.split(r"[(/]", quality, maxsplit=1)[0]
    if base_quality in MAJOR_QUALITIES:
        return root, pitch_names[root]
    if base_quality in MINOR_QUALITIES:
        return root, pitch_names[root] + "m"
    return root, None


def capture(worker, input_dir, cache, mode):
    sys.path.insert(0, str(worker))
    import analysis

    tracks = []
    for wav in sorted(input_dir.glob("*.wav")):
        jams = json.loads(wav.with_suffix(".jams").read_text())
        annotations = [a for a in jams["annotations"] if a["namespace"] == "chord"]
        performed = next(a for a in annotations if "manual verification" in a["annotation_metadata"]["data_source"])
        audio, rate = analysis.sf.read(wav, dtype="float32")
        if rate != 22050:
            audio = analysis.librosa.resample(audio, orig_sr=rate, target_sr=22050, res_type="soxr_hq")
        pcm = cache / "pcm" / wav.name
        pcm.parent.mkdir(parents=True, exist_ok=True)
        analysis.sf.write(pcm, audio, 22050, subtype="FLOAT")
        asset = dict(path=str(pcm), hash=hashlib.sha256(pcm.read_bytes()).hexdigest(), offset=0, role="original")
        method = analysis.HARMONY_METHOD if mode == "r09" else analysis.SOURCE_HARMONY_METHOD
        rows = []
        for row in performed["data"]:
            start = row["time"]
            end = min(len(audio) / 22050, start + row["duration"])
            if end - start < 0.15:
                continue
            root, chord = reference(row["value"], analysis.PITCH_NAMES)
            result = analysis.harmony_job(dict(arrangement=asset, method=method, start=start, end=end,
                                               cache=str(cache / "features")))
            rows.append(dict(id=wav.stem, start=start, end=end, root=root, chord=chord,
                             annotation=row["value"], result=result))
        tracks.append(rows)
    if not tracks:
        raise ValueError("Expected at least one local WAV/JAMS pair.")
    return {"tracks": tracks}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("worker", type=Path)
    parser.add_argument("input", type=Path)
    parser.add_argument("cache", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--mode", choices=["r09", "fixed"], required=True)
    args = parser.parse_args()
    result = capture(args.worker.resolve(), args.input.resolve(), args.cache, args.mode)
    args.output.write_text(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main()
