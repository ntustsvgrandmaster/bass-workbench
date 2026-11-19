"""Profile a retained worker against a read-only, constant-tempo project."""

import argparse
from collections import defaultdict
import json
from pathlib import Path
import resource
import sqlite3
import sys
from time import perf_counter


def load_project(path):
    with sqlite3.connect((path / "project.sqlite").as_uri() + "?mode=ro", uri=True) as database:
        project = json.loads(database.execute("SELECT json FROM project").fetchone()[0])
    context = next(row for row in project["scoreContexts"] if row["id"] == project["activeContextID"])

    def audio_source(role):
        asset = next(row for row in project["assets"] if row["role"] == role)
        request = dict(path=str(path / asset["pcmPath"]), hash=asset["hash"],
                       offset=asset["offset"], role=role)
        return request, asset["duration"] + asset["offset"]

    return context, audio_source("original"), audio_source("bass")


class Profiler:
    def __init__(self):
        self.seconds = defaultdict(float)
        self.calls = defaultdict(int)
        self.children = []

    def hook(self, owner, name, stage):
        original = getattr(owner, name)

        def timed(*args, **kwargs):
            begin = perf_counter()
            self.children.append(0.0)
            try:
                return original(*args, **kwargs)
            finally:
                elapsed = perf_counter() - begin
                self.seconds[stage] += elapsed - self.children.pop()
                self.calls[stage] += 1
                if self.children:
                    self.children[-1] += elapsed

        setattr(owner, name, timed)


def profile(worker, project, cache, mode, shift):
    sys.path.insert(0, str(worker))
    import analysis

    timer = Profiler()
    timer.hook(analysis.sf, "read", "PCM read")
    timer.hook(analysis.librosa, "resample", "resample")
    timer.hook(analysis.librosa, "stft", "STFT")
    timer.hook(analysis.librosa.decompose, "hpss", "HPSS")
    timer.hook(analysis.librosa, "cqt", "CQT")
    timer.hook(analysis.librosa, "pyin", "pYIN")
    timer.hook(analysis.librosa.feature, "chroma_stft", "chroma")
    timer.hook(analysis, "chord_candidates", "templates")
    timer.hook(analysis, "write_json", "region cache writes")
    method = analysis.HARMONY_METHOD
    if mode == "fixed":
        import harmony_features

        method = analysis.SOURCE_HARMONY_METHOD
        timer.hook(harmony_features.np, "savez_compressed", "tile cache writes")
        timer.hook(harmony_features.np, "load", "tile open")
        timer.hook(harmony_features, "summarize_bass", "bass candidate")

    context, (original, duration), (bass, bass_end) = load_project(project)
    timing = context["timing"]
    if timing["anchors"]:
        raise ValueError("This benchmark supports a constant-tempo grid without anchors.")
    scale = 60 / timing["bpm"]
    bias = timing.get("biasSeconds", 0) + shift
    parts = []
    for region in sorted(context["regions"], key=lambda row: row["startBeat"]):
        start = max(0, region["startBeat"] * scale + bias)
        end = min(duration, region["endBeat"] * scale + bias)
        if end - start >= 0.15 and start >= max(0, bass["offset"]) and end <= bass_end:
            parts.append((region["id"], start, end))

    for path in {original["path"], bass["path"]}:
        with open(path, "rb") as pcm:
            while pcm.read(1024 * 1024):
                pass

    results = []
    begin = perf_counter()
    for region_id, start, end in parts:
        result = analysis.harmony_job(dict(
            arrangement=original, bass=bass, method=method, start=start, end=end,
            timingRevision=timing["revision"], cache=str(cache),
        ))
        results.append(dict(id=region_id, result=result, start=start, end=end))
    seconds = perf_counter() - begin
    # ru_maxrss uses bytes on macOS and KiB on Linux.
    rss_divisor = 2**20 if sys.platform == "darwin" else 1024
    return dict(summary=dict(
        stages=dict(timer.seconds), osPcmPreRead=True, mode=mode, shift=shift,
        count=len(parts), seconds=seconds, rssMiB=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / rss_divisor,
        reads=timer.calls["PCM read"], cacheHits=sum(row["result"]["cacheHit"] for row in results),
        cacheMiB=sum(path.stat().st_size for path in cache.rglob("*") if path.is_file()) / 2**20,
    ), results=results)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("worker", type=Path)
    parser.add_argument("project", type=Path)
    parser.add_argument("cache", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--mode", choices=["r09", "fixed"], required=True)
    parser.add_argument("--shift", type=float, default=0.0)
    args = parser.parse_args()
    result = profile(args.worker.resolve(), args.project.resolve(), args.cache, args.mode, args.shift)
    args.output.write_text(json.dumps(result, ensure_ascii=False))
    print(json.dumps(result["summary"]))


if __name__ == "__main__":
    main()
