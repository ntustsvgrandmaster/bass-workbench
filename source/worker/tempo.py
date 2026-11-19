"""Tempo candidates fitted to observed onsets, never an inferred meter/downbeat."""
import math
import numpy as np

METHOD = "librosa-0.11-observed-tempo-fit-v2"
INTEGER_TOLERANCE = 0.1


def quantize_tempo(bpm, integer_tolerance=INTEGER_TOLERANCE):
    if bpm is None or not math.isfinite(bpm) or not 20 <= bpm <= 400:
        raise ValueError("BPM 必須在 20–400 之間。")
    integer = math.floor(bpm + 0.5)
    if abs(bpm - integer) <= integer_tolerance + 1e-9:
        return float(integer)
    return math.floor(bpm * 2 + 0.5) / 2


def _points(times, indices):
    times, indices = np.asarray(times, dtype=float), np.asarray(indices, dtype=float)
    if (times.ndim != 1 or indices.shape != times.shape or len(times) < 2
            or not np.all(np.isfinite(times)) or not np.all(np.isfinite(indices))
            or np.any(np.diff(times) <= 0) or np.any(np.diff(indices) <= 0)):
        raise ValueError("拍點／拍序資料無效。")
    return times, indices


def fit_continuous_tempo(times, indices):
    times, indices = _points(times, indices)
    # 中／長間隔提供斜率初值，漏拍保留原拍序；少數離群點不主導速度。
    slopes = []
    for lag in sorted({1, max(1, len(times) // 4), max(1, len(times) // 2)}):
        slopes.extend((times[lag:] - times[:-lag]) / (indices[lag:] - indices[:-lag]))
    period = float(np.median(slopes))
    intercept = float(np.median(times - indices * period))
    residual = times - (intercept + indices * period)
    mad = float(np.median(np.abs(residual - np.median(residual))))
    keep = np.abs(residual) <= max(0.025, 3 * 1.4826 * mad)
    if np.count_nonzero(keep) >= 3:
        x, y = indices[keep], times[keep]
        x0, y0 = x - np.mean(x), y - np.mean(y)
        period = float(np.dot(x0, y0) / np.dot(x0, x0))
    bpm = 60 / period if period > 0 else math.nan
    if not math.isfinite(bpm) or not 20 <= bpm <= 400:
        raise ValueError("拍點無法擬合為 20–400 BPM。")
    return bpm


def evaluate_fit(times, indices, bpm, coverage=1.0):
    times, indices = _points(times, indices)
    if not math.isfinite(bpm) or not 20 <= bpm <= 400:
        raise ValueError("固定 BPM 無效。")
    # 固定速度後以 median 重擬合截距，不沿用連續速度的截距。
    intercept = float(np.median(times - indices * (60 / bpm)))
    residual = (times - intercept - indices * (60 / bpm)) * 1000
    absolute = np.abs(residual)
    p95 = float(np.percentile(absolute, 95))
    edge = max(1, len(times) // 4)
    drift = float(np.median(residual[-edge:]) - np.median(residual[:edge]))
    span = float(times[-1] - times[0])
    status = "good" if p95 <= 20 + 1e-7 else "borderline" if p95 <= 30 + 1e-7 else "poor"
    if float(np.max(absolute)) > 100 or abs(drift) > 30 + 1e-7:
        status = "poor"
    if len(times) < 6 or span < 4 or coverage < 0.5:
        status = "insufficient"
    return dict(intercept=intercept, medianMs=float(np.median(absolute)), p95Ms=p95,
                maxMs=float(np.max(absolute)), driftMs=drift, count=len(times), span=span,
                coverage=float(coverage), outlierFraction=float(np.mean(absolute > 30)), status=status)


def select_tempo_candidate(times, indices, original_bpm, coverage=1.0):
    quantized = quantize_tempo(original_bpm)
    quantized_fit = evaluate_fit(times, indices, quantized, coverage)
    original_fit = evaluate_fit(times, indices, original_bpm, coverage)
    use_float = quantized_fit["status"] not in ("good", "borderline")
    return dict(bpm=float(original_bpm if use_float else quantized), originalBPM=float(original_bpm),
                quantizedBPM=quantized, usedFloat=use_float,
                fit=original_fit if use_float else quantized_fit,
                quantizedFit=quantized_fit, originalFit=original_fit)


def match_observations(onsets, references, tolerance):
    """Each observed onset is used once; missing beats keep their reference indices."""
    onsets = np.asarray(onsets, dtype=float)
    times, indices, used = [], [], set()
    for index, reference in enumerate(references):
        position = int(np.searchsorted(onsets, reference))
        nearby = [j for j in (position - 1, position) if 0 <= j < len(onsets) and j not in used]
        if not nearby:
            continue
        j = min(nearby, key=lambda n: abs(onsets[n] - reference))
        if abs(onsets[j] - reference) <= tolerance:
            used.add(j)
            times.append(float(onsets[j]))
            indices.append(index)
    return times, indices


def candidates_from_onsets(onsets, tracker_beats, tracker_bpm):
    beats = np.asarray(tracker_beats, dtype=float)
    candidates, main_times = [], []
    if len(beats) < 4:
        return candidates, main_times
    for multiplier in (1.0, 0.5, 2.0):
        if not 20 <= tracker_bpm * multiplier <= 400:
            continue
        if multiplier == 0.5:
            # 半速的兩種相位各自求解；不把全速拍序直接套進半速。
            reference_sets = [beats[::2], beats[1::2]]
        elif multiplier == 2:
            doubled = np.empty(len(beats) * 2 - 1)
            doubled[::2] = beats
            doubled[1::2] = (beats[:-1] + beats[1:]) / 2
            reference_sets = [doubled]
        else:
            reference_sets = [beats]
        hypotheses = []
        for references in reference_sets:
            times, indices = match_observations(onsets, references, min(0.15, 0.25 * 60 / (tracker_bpm * multiplier)))
            if len(times) < 6:
                continue
            try:
                continuous = fit_continuous_tempo(times, indices)
                candidate = select_tempo_candidate(times, indices, continuous, len(times) / len(references))
                candidate["multiplier"] = multiplier
                hypotheses.append((candidate, times))
            except ValueError:
                continue
        if hypotheses:
            candidate, times = min(hypotheses, key=lambda h: (h[0]["fit"]["status"] == "insufficient", h[0]["fit"]["p95Ms"]))
            candidates.append(candidate)
            if multiplier == 1:
                main_times = times
    return candidates, main_times
