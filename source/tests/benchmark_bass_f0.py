"""Local monophonic bass F0 benchmark. Pass a local WAV and an ignored output path."""
import argparse
from collections import defaultdict
from importlib.metadata import PackageNotFoundError
import importlib.metadata
import json
from pathlib import Path
import resource
import time

import librosa
import numpy as np
import soundfile as sf

SR = 16000
HOP = .01
CLIPS = [(5, 20), (22, 28), (90, 105), (180, 195)]
PITCHES = [23, 28, 33, 38, 43, 52]


def synthetic():
    rng = np.random.default_rng(20261109)
    pieces, notes = [], []
    t = np.arange(SR) / SR
    cases = ["pure", "second_harmonic", "weak_fundamental", "pluck", "vibrato"]
    for case in cases:
        for midi in PITCHES:
            pitch = midi + (.32 * np.sin(2 * np.pi * 5 * t) if case == "vibrato" else np.zeros_like(t))
            phase = np.cumsum(2 * np.pi * 440 * 2 ** ((pitch - 69) / 12) / SR)
            weights = {
                "pure": (.25, 0, 0),
                "second_harmonic": (.07, .28, .07),
                "weak_fundamental": (.008, .25, .12),
                "pluck": (.08, .24, .09),
                "vibrato": (.12, .21, .08),
            }[case]
            wave = sum(amp * np.sin((i + 1) * phase) for i, amp in enumerate(weights))
            if case == "pluck":
                wave = wave * np.exp(-2.2 * t) + .20 * np.exp(-85 * t) * rng.normal(size=len(t))
            wave *= np.minimum(1, t / .015) * np.minimum(1, (1 - t) / .025)
            start = len(pieces) * 1.4 / 2
            notes.append((start, midi, case))
            pieces.extend([wave, .003 * rng.normal(size=int(.4 * SR))])
    return np.concatenate(pieces).astype(np.float32), notes


def evaluator(name, checkpoint):
    if name == "stft":
        def evaluate(y):
            spectrum = np.abs(librosa.stft(y, n_fft=8192, win_length=2048, hop_length=160))
            frequencies = librosa.fft_frequencies(sr=SR, n_fft=8192)
            keep = (frequencies >= 28) & (frequencies <= 350)
            best = spectrum[keep].argmax(axis=0)
            rms = librosa.feature.rms(y=y, frame_length=2048, hop_length=160)[0]
            return np.arange(len(best)) * HOP, frequencies[keep][best], rms, rms >= .008
        return evaluate
    if name == "pyin":
        def evaluate(y):
            signal = librosa.resample(y, orig_sr=SR, target_sr=11025)
            f0, voiced, prob = librosa.pyin(signal, sr=11025, fmin=28, fmax=350,
                                           frame_length=2048, hop_length=256)
            return np.arange(len(f0)) * 256 / 11025, f0, prob, voiced
        return evaluate
    import torch
    torch.set_num_threads(2)
    torch.set_num_interop_threads(1)
    if name.startswith("crepe"):
        import torchcrepe
        model = name.split("-", 1)[1]
        def evaluate(y):
            f0, prob = torchcrepe.predict(torch.from_numpy(y[None]), SR, 160,
                                          31.7, 350., model=model, batch_size=256,
                                          device="cpu", return_periodicity=True)
            f0, prob = f0.numpy().ravel(), prob.numpy().ravel()
            return np.arange(len(f0)) * HOP, f0, prob, prob >= .21
        return evaluate
    if name == "pesto":
        import pesto
        model = pesto.load_model("mir-1k_g7", step_size=10., sampling_rate=SR).eval()
        @torch.inference_mode()
        def evaluate(y):
            f0, prob, *_ = model(torch.from_numpy(y), convert_to_freq=True, return_activations=False)
            f0, prob = f0.numpy().ravel(), prob.numpy().ravel()
            return np.arange(len(f0)) * HOP, f0, prob, prob >= .5
        return evaluate
    if name == "penn":
        import inspect
        import penn
        # Older PENN releases use their configured local weighted decoder.
        options = {"decoder": "viterbi"} if "decoder" in inspect.signature(penn.from_audio).parameters else {}
        hop = .02
        def evaluate(y):
            f0, prob = penn.from_audio(torch.from_numpy(y[None]), SR, hopsize=hop,
                                       fmin=31., fmax=350., checkpoint=checkpoint,
                                       batch_size=128, center="zero",
                                       interp_unvoiced_at=None, gpu=None, **options)
            f0, prob = f0.numpy().ravel(), prob.numpy().ravel()
            return np.arange(len(f0)) * hop, f0, prob, prob >= .065
        return evaluate
    raise ValueError(name)


def collect(predict, y):
    start = time.perf_counter()
    times, f0, conf, voiced = predict(y)
    elapsed = time.perf_counter() - start
    assert times.shape == f0.shape == conf.shape == voiced.shape
    voiced = voiced & np.isfinite(f0) & (f0 > 0)
    midi = np.full(f0.shape, np.nan)
    midi[voiced] = librosa.hz_to_midi(f0[voiced])
    return times, midi, elapsed


def metrics(midi, truth):
    voiced = np.isfinite(midi)
    error = (midi - truth) * 100
    return {
        "frames": len(midi),
        "coverage": float(voiced.mean()),
        "within_50c": float((np.abs(error) <= 50).mean()),
        "octave_50c": float((np.abs(np.abs(error) - 1200) <= 50).mean()),
        "median_abs_cents_when_voiced": float(np.median(np.abs(error[voiced]))) if voiced.any() else None,
    }


def score_grid(times, midi, duration):
    target = np.arange(0, duration, HOP)
    right = np.minimum(np.searchsorted(times, target), len(times) - 1)
    left = np.maximum(right - 1, 0)
    nearest = np.where(abs(times[left] - target) <= abs(times[right] - target), left, right)
    sampled = midi[nearest].copy()
    sampled[abs(times[nearest] - target) > .015] = np.nan
    return target, sampled


def series(times, midi):
    return [[round(float(t), 5), round(float(p), 4) if np.isfinite(p) else None]
            for t, p in zip(times, midi)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("method", choices=["stft", "pyin", "crepe-tiny", "crepe-full", "pesto", "penn"])
    parser.add_argument("--wav", type=Path)
    parser.add_argument("--checkpoint", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--clip", nargs=2, type=int, action="append", metavar=("START", "END"))
    parser.add_argument("--reference", type=Path, help="Optional local JSON of [start, end, MIDI] windows")
    args = parser.parse_args()
    if args.wav and not args.output:
        parser.error("--wav requires --output")
    if args.method == "penn" and not args.checkpoint:
        parser.error("PENN requires an explicit local --checkpoint")
    reference = json.loads(args.reference.read_text()) if args.reference else []
    np.random.seed(7)
    start = time.perf_counter()
    predict = evaluator(args.method, args.checkpoint)
    setup = time.perf_counter() - start
    # Warm imports, decoding and weight loading with generated audio.
    tone = np.sin(2 * np.pi * 41.2 * np.arange(2 * SR) / SR).astype(np.float32) * .2
    _, _, warmup = collect(predict, tone)
    if args.wav is None:
        print(json.dumps({"setup": setup, "synthetic_warmup": warmup}))
        return
    y, sr = sf.read(args.wav, dtype="float32")
    if y.ndim != 1 or sr != SR:
        raise ValueError("Use a common mono 16 kHz WAV")
    test, notes = synthetic()
    times, midi, synth_elapsed = collect(predict, test)
    times, midi = score_grid(times, midi, len(test) / SR)
    groups = defaultdict(lambda: ([], []))
    silent = []
    for start, pitch, case in notes:
        keep = (times >= start + .15) & (times < start + .85)
        t = times[keep] - start
        truth = pitch + (.32 * np.sin(2 * np.pi * 5 * t) if case == "vibrato" else np.zeros_like(t))
        for group in ("all", case, f"MIDI {pitch}"):
            groups[group][0].extend(midi[keep])
            groups[group][1].extend(truth)
        silent.extend(midi[(times >= start + 1.14) & (times < start + 1.29)])
    out = dict(method=args.method, setup=setup, warmup=warmup, synthetic_elapsed=synth_elapsed,
               synthetic={key: metrics(np.array(p), np.array(t)) for key, (p, t) in groups.items()},
               noise_false_voice=float(np.isfinite(silent).mean()), real=[])
    for start, end in args.clip or CLIPS:
        if end * SR > len(y):
            continue
        clip = y[start * SR:end * SR]
        times, midi, elapsed = collect(predict, clip)
        times, midi = score_grid(times, midi, end - start)
        row = dict(start=start, end=end, elapsed=elapsed, coverage=float(np.isfinite(midi).mean()),
                   predictions=series(times + start, midi), reference=[])
        for left, right, truth in reference:
            if start <= left < right <= end:
                values = midi[(times + start >= left) & (times + start < right)]
                score = metrics(values, np.full(len(values), truth))
                finite = values[np.isfinite(values)]
                row["reference"].append(dict(start=left, end=right, midi=truth,
                    median_midi=float(np.median(finite)) if finite.size else None, **score))
        out["real"].append(row)
    out["peak_rss_mib"] = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 2**20
    out["versions"] = {}
    for package in ["numpy", "librosa", "torch", "torchcrepe", "pesto-pitch", "penn"]:
        try:
            out["versions"][package] = importlib.metadata.version(package)
        except PackageNotFoundError:
            pass
    args.output.write_text(json.dumps(out, allow_nan=False))
    print(args.method, json.dumps({k: v for k, v in out.items() if k not in ("real", "synthetic")}),
          out["synthetic"]["all"], flush=True)


if __name__ == "__main__":
    main()
