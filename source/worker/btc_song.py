"""Optional CPU-only BTC worker. Reads local model files and caches source-time scores."""
import hashlib
import math
from pathlib import Path
import sys
import tempfile
from zipfile import BadZipFile

import numpy as np
import soundfile as sf

from beat_this_tempo import emit

WEIGHTS_HASH = "71c2c5db17e8c43b8a9a9da5db36ef2d667158c07a214eba16344c154c00bf54"
METHOD = "btc-ismir19-majmin-v1"
SAMPLE_RATE = 22050
WINDOW_SECONDS = 10
MODEL_FRAMES = 108
STEP = WINDOW_SECONDS / MODEL_FRAMES


def load_model(checkout):
    import torch
    import yaml

    weights = checkout / "test/btc_model.pt"
    if hashlib.sha256(weights.read_bytes()).hexdigest() != WEIGHTS_HASH:
        raise ValueError("BTC 權重版本不符，請檢查本機模型設定。")
    sys.path.insert(0, str(checkout))
    # The original model uses the old NumPy spelling when building its positional encoding.
    if not hasattr(np, "float"):
        np.float = float
    from btc_model import BTC_model

    def legacy_numpy_global(name):
        def read(*args):
            return getattr(np._core.multiarray, name)(*args)
        read.__module__ = "numpy.core.multiarray"
        read.__name__ = name
        return read

    torch.set_num_threads(2)
    torch.set_num_interop_threads(1)
    with torch.serialization.safe_globals([
        legacy_numpy_global("scalar"), legacy_numpy_global("_reconstruct"),
        np.dtype, type(np.dtype("float64")), type(np.dtype("float32")), np.ndarray,
    ]):
        checkpoint = torch.load(weights, map_location="cpu", weights_only=True)
    config = yaml.safe_load((checkout / "run_config.yaml").read_text())["model"]
    config.update(num_chords=25, probs_out=True)
    model = BTC_model(config).eval()
    model.load_state_dict(checkpoint["model"])
    return model, checkpoint["mean"], checkpoint["std"]


def infer(path, checkout, progress):
    import librosa
    import torch

    model, mean, std = load_model(checkout)
    rows = []
    with sf.SoundFile(path) as source, torch.inference_mode():
        chunk_size = WINDOW_SECONDS * source.samplerate
        while source.tell() < source.frames:
            samples = source.read(chunk_size, dtype="float32", always_2d=True).mean(axis=1)
            count = math.ceil(len(samples) * MODEL_FRAMES / chunk_size)
            if source.samplerate != SAMPLE_RATE:
                samples = librosa.resample(samples, orig_sr=source.samplerate, target_sr=SAMPLE_RATE,
                                           res_type="soxr_hq")
            if not count:
                continue
            if float(np.sqrt(np.mean(samples ** 2))) < .0004:
                scores = np.zeros((count, 25), dtype=np.float32)
                scores[:, -1] = 1
            else:
                # Retain the reference model's 10 s CQT/attention windows. A short tail is
                # padded for the CQT, with only the frames covered by real audio retained.
                padded = np.pad(samples, (0, max(0, 2048 - len(samples))))
                cqt = librosa.cqt(padded, sr=SAMPLE_RATE, n_bins=144, bins_per_octave=24,
                                  hop_length=2048)
                features = (np.log(np.abs(cqt.T) + 1e-6) - mean) / std
                features = features[:count]
                features = np.pad(features, ((0, MODEL_FRAMES - len(features)), (0, 0)))
                hidden, _ = model.self_attn_layers(torch.tensor(features, dtype=torch.float32).unsqueeze(0))
                scores = torch.softmax(model.output_layer(hidden), -1)[0, :count].numpy()
            rows.append(scores)
            progress(.1 + .85 * source.tell() / source.frames, "正在估測全曲和弦")
    return np.concatenate(rows) if rows else np.empty((0, 25), dtype=np.float32)


def source_scores(asset, checkout, cache, duration, progress):
    key = hashlib.sha256(f"{METHOD}:{WEIGHTS_HASH}:{asset['hash']}".encode()).hexdigest()
    cache.mkdir(parents=True, exist_ok=True)
    path = cache / f"{key}.npz"
    expected_rows = math.ceil(duration / STEP - 1e-9)

    def valid(values):
        return (values.shape == (expected_rows, 25) and np.isfinite(values).all()
                and (values >= 0).all() and np.allclose(values.sum(axis=1), 1, atol=1e-5))

    if path.is_file():
        try:
            with np.load(path, allow_pickle=False) as stored:
                values = stored["scores"]
            if valid(values):
                return values, True
        except (OSError, ValueError, KeyError, BadZipFile, EOFError):
            pass
    values = infer(asset["path"], checkout, progress)
    if not valid(values):
        raise ValueError("BTC 回傳的和弦影格與音源不符。")
    with tempfile.NamedTemporaryFile(dir=cache, suffix=".partial", delete=False) as file:
        temporary = Path(file.name)
        try:
            np.savez_compressed(file, scores=values)
            file.close()
            temporary.replace(path)
        finally:
            temporary.unlink(missing_ok=True)
    return values, False


def first_bar_phase(timing, scores, origin):
    """Rank the four 4/4 rotations using the tested downbeat and BTC weights."""
    beat = 60 / float(timing["bpm"])
    bar = 4 * beat
    beats = np.asarray(timing["beats"])
    downbeats = np.asarray(timing["downbeats"])
    if len(beats) < 8 or len(downbeats) < 4:
        return None
    roots = scores[:, :24].reshape(-1, 12, 2).sum(axis=-1)
    best, strength = roots.argmax(axis=1), roots.max(axis=1)
    changed = (best[1:] != best[:-1]) & (strength[1:] > .45) & (strength[:-1] > .45)
    changes = origin + (np.flatnonzero(changed) + 1) * STEP
    changes = changes[(changes >= timing["start"]) & (changes < timing["end"])]
    if len(changes) < 4:
        return None

    def agreement(events, phases, period, width):
        distance = (events[:, None] - phases + period / 2) % period - period / 2
        return np.exp(-.5 * (distance / width) ** 2).mean(axis=0)

    grid = np.arange(0, beat, .001)
    origin_beat = grid[agreement(beats, grid, beat, .055).argmax()]
    fine = np.arange(-.1, .1001, .001)
    phases = (origin_beat + np.arange(4)[:, None] * beat + fine) % bar
    down = agreement(downbeats, phases.ravel(), bar, .065).reshape(phases.shape)
    chord = agreement(changes, phases.ravel(), bar, .1).reshape(phases.shape)
    combined = .65 * down + .35 * chord
    order = np.argsort(-combined.max(axis=1), kind="stable")
    row, runner_up = order[:2]
    col = combined[row].argmax()
    # A narrow lead or weak downbeat support leaves the first bar for manual calibration.
    if combined[row, col] - combined[runner_up].max() < .15 or down[row, col] < .35:
        return None
    return round(float(phases[row, col]), 3)


def song_job(request, progress):
    asset = request["asset"]
    duration = sf.info(asset["path"]).duration
    offset = float(asset["offset"])
    if not math.isfinite(offset) or duration <= 0:
        raise ValueError("音源時間無效。")
    scores, cached = source_scores(asset, Path(request["checkout"]), Path(request["cache"]), duration, progress)
    timing = request.get("timing")
    first_bar = first_bar_phase(timing, scores, offset) if timing else None
    return dict(method=METHOD, sourceHash=asset["hash"], duration=duration, step=STEP,
                firstBar=first_bar, cached=cached, scores=scores.astype(float).round(5).tolist())


if __name__ == "__main__":
    import json
    import traceback

    request = None
    try:
        request = json.loads(sys.stdin.readline())
        if request.get("op") != "btc":
            raise ValueError("Only BTC song requests supported")
        request_id = request["id"]
        result = song_job(request, lambda value, message: emit(
            dict(id=request_id, type="progress", progress=value, message=message)))
        emit(dict(id=request_id, type="result", result=result))
    except Exception as error:
        emit(dict(id=request.get("id", "") if request else "", type="error", message=str(error)))
        traceback.print_exc(file=sys.stderr)
    finally:
        sys.stdin.read()
