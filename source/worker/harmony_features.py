"""Bounded source-time features for full-song harmony analysis."""

from functools import lru_cache
import math
from pathlib import Path
from tempfile import NamedTemporaryFile
from zipfile import BadZipFile

import librosa
import numpy as np
import soundfile as sf

from analysis import (
    TUNED_HARMONY_METHOD, cache_key, cqt_amplitude, harmony_evidence, summarize_bass,
)

RATE = 22050
HOP = 256
FFT = 4096
CHUNK = round(15 * RATE / HOP)
HPSS_KERNEL = 31
HPSS_MARGIN = 2.0
# The halo covers both the STFT and temporal median kernel, with room for low CQT windows.
HALO = max(math.ceil(2 * RATE / HOP), HPSS_KERNEL // 2 + math.ceil(FFT / (2 * HOP)))
MAX_HZ = 5000
BINS = int(MAX_HZ * FFT / RATE) + 1
SOURCE_SETTINGS = dict(version=1, rate=RATE, hop=HOP, fft=FFT, chunk=CHUNK, halo=HALO,
                       hpssKernel=HPSS_KERNEL, hpssMargin=HPSS_MARGIN, maxHz=MAX_HZ)
FREQUENCIES = np.arange(BINS) * RATE / FFT
TUNING_EDGES = np.linspace(-0.5, 0.5, 101)


@lru_cache(maxsize=8)
def source_info(path):
    info = sf.info(path)
    samples = round(info.frames * RATE / info.samplerate)
    return info.samplerate, info.frames, samples


@lru_cache(maxsize=4)
def audio_chunk(path, digest, index):
    source_rate, source_frames, samples = source_info(path)
    first = max(0, (index * CHUNK - HALO) * HOP)
    stop = min(samples, ((index + 1) * CHUNK + HALO) * HOP)
    native_first = round(first * source_rate / RATE)
    native_stop = min(source_frames, round(stop * source_rate / RATE))
    y, sr = sf.read(path, start=native_first, stop=native_stop, dtype="float32", always_2d=True)
    y = y.mean(axis=1)
    if sr != RATE:
        y = librosa.resample(y, orig_sr=sr, target_sr=RATE, res_type="soxr_hq")
    return y[:stop-first], first


def read_tile(root, key, expected, compute):
    if root is None:
        return compute()
    path = root / f"{key}.npz"
    try:
        with np.load(path, allow_pickle=False) as data:
            arrays = {name: data[name] for name in expected}
        if all(a.shape == expected[name] and np.isfinite(a).all() for name, a in arrays.items()):
            return arrays
    except (ValueError, KeyError, OSError, EOFError, BadZipFile):
        pass
    arrays = compute()
    root.mkdir(parents=True, exist_ok=True)
    with NamedTemporaryFile(dir=root, prefix=".tile-", suffix=".partial", delete=False) as stream:
        temporary = Path(stream.name)
        try:
            np.savez_compressed(stream, **arrays)
            stream.flush()
            temporary.replace(path)
        finally:
            temporary.unlink(missing_ok=True)
    return arrays


def chunk_layout(path, index):
    samples = source_info(path)[2]
    start = index * CHUNK
    count = min(CHUNK, (samples + HOP - 1) // HOP - start)
    return start, count


@lru_cache(maxsize=2)
def harmonic_chunk(root, path, digest, index):
    start, count = chunk_layout(path, index)
    key = cache_key(dict(SOURCE_SETTINGS, type="harmonic-f16", hash=digest, index=index))

    def compute():
        y, first = audio_chunk(path, digest, index)
        begin = start - first // HOP
        spectrum = np.abs(librosa.stft(y, n_fft=FFT, hop_length=HOP))
        harmonic, _ = librosa.decompose.hpss(spectrum, kernel_size=HPSS_KERNEL, margin=HPSS_MARGIN)
        # Preserve the linear-frequency bins needed for tuning and band weighting up to 5 kHz.
        return {"harmonic": harmonic[:BINS, begin:begin+count].astype(np.float16)}

    return read_tile(root, key, {"harmonic": (BINS, count)}, compute)["harmonic"]


@lru_cache(maxsize=2)
def bass_chunk(root, path, digest, index):
    start, count = chunk_layout(path, index)
    key = cache_key(dict(SOURCE_SETTINGS, type="bass-cqt-rms", hash=digest, index=index,
                         fminMIDI=23, bins=64, binsPerOctave=12, rmsWindow=512))

    def compute():
        y, first = audio_chunk(path, digest, index)
        begin = start - first // HOP
        section = slice(begin, begin+count)
        mag = cqt_amplitude(y, RATE, float(librosa.midi_to_hz(23)), 64, 12)
        rms = librosa.feature.rms(y=y, frame_length=512, hop_length=HOP)[0]
        return {"magnitude": mag[:, section].astype(np.float32), "rms": rms[section]}

    arrays = read_tile(root, key, {"magnitude": (64, count), "rms": (count,)}, compute)
    return arrays["magnitude"], arrays["rms"]


@lru_cache(maxsize=4)
def chroma_filter(tuning):
    return librosa.filters.chroma(sr=RATE, n_fft=FFT, tuning=tuning)[:, :BINS].copy()


@lru_cache(maxsize=4)
def chroma_chunk(root, path, digest, index, tuning, low_hz=90, low_gain=0.15, high_hz=MAX_HZ):
    _, count = chunk_layout(path, index)
    key = cache_key(dict(SOURCE_SETTINGS, type="chroma", harmonicEncoding="float16",
                         hash=digest, index=index, tuning=tuning, bassGain=low_gain,
                         belowHz=low_hz, aboveHz=high_hz))

    def compute():
        harmonic = harmonic_chunk(root, path, digest, index).astype(np.float32)
        harmonic[FREQUENCIES < low_hz] *= low_gain
        harmonic[FREQUENCIES > high_hz] = 0
        energy = harmonic.sum(axis=0)
        chroma = chroma_filter(tuning) @ np.square(harmonic)
        chroma = librosa.util.normalize(chroma, norm=2, axis=0)
        return {"chroma": chroma, "energy": energy}

    arrays = read_tile(root, key, {"chroma": (12, count), "energy": (count,)}, compute)
    return arrays["chroma"], arrays["energy"]


def tuning_for_source(root, path, digest, progress):
    count = math.ceil(source_info(path)[2] / (CHUNK * HOP))
    key = cache_key(dict(SOURCE_SETTINGS, type="global-tuning", harmonicEncoding="float16",
                         hash=digest, stride=8, tuningHz=[150, 4000]))

    def compute():
        histogram = np.zeros(100, dtype=np.int64)
        for index in range(count):
            progress(0.05 + 0.45 * index / count, f"估計全曲調音 · {index+1}/{count}")
            harmonic = harmonic_chunk(root, path, digest, index)[:, ::8].astype(np.float32)
            padded = np.pad(harmonic, ((0, FFT // 2 + 1 - BINS), (0, 0)))
            pitches, strengths = librosa.piptrack(S=padded, sr=RATE, n_fft=FFT, fmin=150, fmax=4000)
            peaks = strengths[pitches > 0]
            if peaks.size:
                use = (pitches > 0) & (strengths >= np.median(peaks))
                residual = (librosa.hz_to_midi(pitches[use]) + 0.5) % 1 - 0.5
                histogram += np.histogram(residual, bins=TUNING_EDGES)[0]
        tuning = TUNING_EDGES[int(histogram.argmax())] if histogram.sum() >= 50 else 0.0
        return {"tuning": np.array([round(float(tuning), 2)])}

    return float(read_tile(root, key, {"tuning": (1,)}, compute)["tuning"][0])


def slice_frames(path, offset, start, end, load):
    samples = source_info(path)[2]
    first = max(0, math.ceil((start - offset) * RATE / HOP - 1e-9))
    stop = min((samples + HOP - 1) // HOP, math.ceil((end - offset) * RATE / HOP - 1e-9))
    if stop <= first:
        raise ValueError("和聲區段沒有可用影格。")
    arrays = []
    for index in range(first // CHUNK, (stop - 1) // CHUNK + 1):
        base = index * CHUNK
        section = slice(max(0, first - base), min(CHUNK, stop - base))
        arrays.append(tuple(values[..., section] for values in load(index)))
    features = arrays[0] if len(arrays) == 1 else tuple(np.concatenate(parts, axis=-1) for parts in zip(*arrays))
    return features, np.arange(first, stop, dtype=np.int64)


def cached_harmony(request, progress, cache, method):
    root = cache / "source-harmony" if cache is not None else None
    start, end = float(request["start"]), float(request["end"])
    if not math.isfinite(start+end) or not 0.15 - 1e-7 <= end-start <= 90:
        raise ValueError("請選取 0.15–90 秒的和聲分析區段。")
    arrangement = request["arrangement"]
    bass = request.get("bass") or arrangement
    apath, ahash, aoffset = arrangement["path"], arrangement["hash"], float(arrangement.get("offset", 0))
    bpath, bhash, boffset = bass["path"], bass["hash"], float(bass.get("offset", 0))
    for path, offset in ((apath, aoffset), (bpath, boffset)):
        if start < max(0, offset) - 1e-7 or end > offset + source_info(path)[2] / RATE + 1 / RATE:
            raise ValueError("分析區段未被此音源涵蓋，請檢查音源偏移。")
    progress(0.08, "讀取音源特徵")
    tuning = tuning_for_source(root, apath, ahash, progress) if method == TUNED_HARMONY_METHOD else 0.0
    (chroma, energy), _ = slice_frames(apath, aoffset, start, end,
                                      lambda index: chroma_chunk(root, apath, ahash, index, tuning))
    average = np.average(chroma, axis=1, weights=np.maximum(energy, 1e-8))
    # Measure raw waveform energy with the original silence criterion, even after HPSS.
    first = max(0, int((start - aoffset) * RATE))
    stop = min(source_info(apath)[2], int((end - aoffset) * RATE))
    total = 0.0
    size = 0
    for index in range(first // (CHUNK * HOP), (stop - 1) // (CHUNK * HOP) + 1):
        y, origin = audio_chunk(apath, ahash, index)
        segment = y[max(first, index * CHUNK * HOP)-origin:min(stop, (index+1)*CHUNK*HOP)-origin]
        total += float(np.dot(segment, segment))
        size += len(segment)
    silent = size == 0 or math.sqrt(total / size) < 0.0004

    progress(0.65, "讀取低音特徵並估計首音")
    (magnitude, rms), frames = slice_frames(bpath, boffset, start, end,
                                           lambda index: bass_chunk(root, bpath, bhash, index))
    times = boffset + frames * HOP / RATE

    def waveform(second):
        sample = round((second - boffset) * RATE)
        y, origin = audio_chunk(bpath, bhash, sample // (CHUNK * HOP))
        center = sample - origin
        return y[max(0, center-int(RATE*0.03)):center+int(RATE*0.24)]

    first_note = summarize_bass(magnitude, rms, times, RATE, bass.get("role") == "bass", waveform)
    result = harmony_evidence(request, average, silent, first_note, method)
    result["tuningCents"] = round(tuning * 100)
    return result
