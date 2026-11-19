# DSP 模組：只讀本機分析副本，回傳可追溯候選，不直接修改人工標註或原譜。

"""Local, deterministic DSP. Scores describe evidence, never calibrated probabilities."""
from __future__ import annotations
import hashlib
import json
import math
import os
from pathlib import Path
import time
from datetime import datetime, timezone

os.environ.setdefault("NUMBA_NUM_THREADS", "2")
os.environ.setdefault("OPENBLAS_NUM_THREADS", "2")
os.environ.setdefault("OMP_NUM_THREADS", "2")
import numpy as np
import soundfile as sf
import librosa
from tempo import METHOD as TEMPO_METHOD, candidates_from_onsets

# 方法版本屬於快取鍵。改變數值算法或閾值時應升版，避免拿舊結果冒充新方法。
METHOD = "librosa-0.11-cqt-chroma-template-v3"
HARMONY_METHOD = METHOD + " / bass-salience-octave-v2"
SOURCE_HARMONY_METHOD = HARMONY_METHOD + " / source-tiles-v1"
TUNED_HARMONY_METHOD = SOURCE_HARMONY_METHOD + " / global-tuning-v1"
PITCH_NAMES = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]

def cache_key(data):
    return hashlib.sha256(json.dumps(data, sort_keys=True, separators=(",", ":")).encode()).hexdigest()

# 先寫 partial 再替換，取消分析時不把半份 JSON 當成可用快取。
def write_json(path, data):
    path = Path(path)
    temporary = path.with_suffix(path.suffix + ".partial")
    temporary.write_text(json.dumps(data, ensure_ascii=False, allow_nan=False))
    temporary.replace(path)

# 所有 request 使用主時間（秒）；讀檔前扣除 stem offset。前後保留 context，減少窗口邊界誤差。
def read_region(asset, start, end, padding=2.0):
    info = sf.info(asset["path"])
    offset = float(asset.get("offset", 0))
    local_start, local_end = max(0.0, start - offset), min(info.duration, end - offset)
    if local_end <= local_start or local_end - local_start < 0.15:
        raise ValueError("分析區段未被此音源涵蓋，請調整對齊點或 stem 時間偏移。")
    first = max(0, int((local_start - padding) * info.samplerate))
    last = min(info.frames, int((local_end + padding) * info.samplerate))
    y, sr = sf.read(asset["path"], start=first, stop=last, dtype="float32", always_2d=True)
    y = np.mean(y, axis=1)
    if sr != 22050:
        y = librosa.resample(y, orig_sr=sr, target_sr=22050, res_type="soxr_hq")
    return y, 22050, first / info.samplerate + offset


def tempo_job(request, progress=lambda *_: None):
    """Bounded local beat estimate. A pulse is not a bar/downbeat or a meter prediction."""
    started = time.perf_counter()
    asset = request["asset"]
    info = sf.info(asset["path"])
    offset = float(asset.get("offset", 0))
    if not math.isfinite(offset) or info.duration <= 0:
        raise ValueError("音源時間無效。")
    start = max(0.0, offset)
    end = min(offset + info.duration, start + 90.0)
    result = dict(bpm=None, alternatives=[], beats=[], start=start, end=end,
                  sourceHash=asset["hash"], method=TEMPO_METHOD, candidates=[],
                  rawBPM=None, resolutionMs=256 / 22050 * 1000,
                  warnings=["只估測開頭最多 90 秒；變速、弱起或前奏可能影響結果。",
                            "拍點不是小節第一拍；拍號、半速／倍速與第一小節起點請聆聽確認。"])
    if end - start < 4:
        result["warnings"].append("可用音訊不足 4 秒，請手動設定。")
        return result
    progress(0.1, "讀取開頭最多 90 秒，估測起音與節拍")
    y, sr, origin = read_region(asset, start, end, padding=0)
    if float(np.sqrt(np.mean(y**2))) < 0.0004:
        result["warnings"].append("音訊能量過低，無可用拍點。")
        return result
    hop = 256
    envelope = librosa.onset.onset_strength(y=y, sr=sr, hop_length=hop)
    # 持續單音的頻譜數值波動也會形成微小局部峰；不讓相對門檻把它放大成節拍。
    envelope = np.maximum(0, envelope - 0.1)
    onsets = librosa.onset.onset_detect(onset_envelope=envelope, sr=sr, hop_length=hop)
    if len(onsets) < 6:
        result["warnings"].append("起音不足，無法提供穩定 BPM 候選。")
        return result
    progress(0.5, "估測 BPM 與拍點；拍號保留人工設定")
    tempo, frames = librosa.beat.beat_track(onset_envelope=envelope, sr=sr,
                                           hop_length=hop, trim=True)
    bpm = float(np.asarray(tempo).reshape(-1)[0])
    if not math.isfinite(bpm) or not 20 <= bpm <= 400 or len(frames) < 4:
        result["warnings"].append("節拍證據不足，請手動設定。")
        return result
    onset_times = origin + np.asarray(onsets) * hop / sr
    tracker_beats = origin + np.asarray(frames) * hop / sr
    progress(0.75, "以觀測起音擬合速度，重擬合量化候選截距與殘差")
    candidates, observed = candidates_from_onsets(onset_times, tracker_beats, bpm)
    primary = next((c for c in candidates if c["multiplier"] == 1), None)
    if primary is None or primary["fit"]["status"] == "insufficient":
        result["warnings"].append("可對應的觀測起音不足，請手動設定。")
        return result
    result.update(bpm=primary["bpm"], rawBPM=bpm, candidates=candidates,
                  alternatives=sorted({c["bpm"] for c in candidates}),
                  beats=[t for t in observed if start <= t < end], elapsed=time.perf_counter() - started)
    if primary["usedFloat"]:
        result["warnings"].append("量化速度的殘差未通過，已保留量化前浮點速度與其自身截距。")
    if primary["fit"]["status"] == "poor":
        result["warnings"].append("浮點速度的殘差仍過大，請人工確認或使用分段錨點。")
    result["warnings"].append("殘差來自可配對的觀測起音；只有本次片段的內部一致性，不保證全曲或每一拍正確。")
    progress(1.0, "估測完成，候選尚未套用")
    return result

# CQT 是音高能量而非 F0。低音有較長的時間窗口，不能用亮線邊緣當精準 onset。
def cqt_amplitude(y, sr, fmin, n_bins, bins_per_octave):
    """Undo scale=False's filter-length gain, using one fixed amplitude reference."""
    magnitude = np.abs(librosa.cqt(y, sr=sr, hop_length=256, fmin=fmin, n_bins=n_bins, bins_per_octave=bins_per_octave, tuning=0.0, scale=False, norm=1))
    frequencies = librosa.cqt_frequencies(n_bins, fmin=fmin, bins_per_octave=bins_per_octave)
    lengths, _ = librosa.filters.wavelet_lengths(freqs=frequencies, sr=sr, window="hann", filter_scale=1)
    # scale=False 的長濾波器具有長度增益；除回各頻帶長度，保持固定的振幅參考。
    return 2 * magnitude / lengths[:, None]

def bass_pitch_trace(y, sr, origin, start, end):
    # Keep a long enough frame for low B while reducing the pYIN search cost.
    guide_rate = sr // 2
    y = librosa.resample(y, orig_sr=sr, target_sr=guide_rate, res_type="soxr_hq")
    f0, voiced, _ = librosa.pyin(
        y, sr=guide_rate, fmin=28, fmax=350, frame_length=2048, hop_length=256
    )
    times = origin + np.arange(len(f0)) * 256 / guide_rate
    keep = voiced & np.isfinite(f0) & (times >= start) & (times <= end)
    return [
        dict(time=float(t), midi=float(m))
        for t, m in zip(times[keep], librosa.hz_to_midi(f0[keep]))
    ]


def feature_job(request, progress=lambda *_: None):
    started = time.perf_counter()
    cache = Path(request["cache"])
    cache.mkdir(parents=True, exist_ok=True)
    start, end = float(request["start"]), float(request["end"])
    if not math.isfinite(start + end) or end - start > 90 or end <= start:
        raise ValueError("請選取 0.15–90 秒的分析區段；可跨小節。")
    low, high, bpo = int(request.get("minMIDI", 23)), int(request.get("maxMIDI", 60)), int(request.get("binsPerOctave", 24))
    if not (12 <= low < high <= 96 and bpo in (12, 24, 36)):
        raise ValueError("音高顯示範圍或解析度無效。")
    # 不依絕對檔案路徑識別素材，專案搬家後仍可重用同一內容與參數的快取。
    settings = {k: request[k] for k in ("start", "end", "minMIDI", "maxMIDI", "binsPerOctave")}
    settings.update(method=METHOD, hash=request["asset"]["hash"], offset=request["asset"].get("offset", 0))
    key = cache_key(settings)
    guide = request.get("pitchGuide") is True and request["asset"].get("role") == "bass"
    metadata_path, binary_path = cache / f"{key}.json", cache / f"{key}.f32"
    if metadata_path.exists() and binary_path.exists():
        metadata = json.loads(metadata_path.read_text())
        if binary_path.stat().st_size == metadata["rows"] * metadata["columns"] * 4:
            if guide and "pitchTrace" not in metadata:
                progress(0.35, "估計 Bass stem 基頻")
                y, sr, origin = read_region(request["asset"], start, end)
                metadata["pitchTrace"] = bass_pitch_trace(y, sr, origin, start, end)
                write_json(metadata_path, metadata)
            metadata["cacheHit"] = True
            metadata["elapsed"] = time.perf_counter() - started
            metadata["binaryPath"] = str(binary_path)
            return metadata
    progress(0.08, "讀取本機分析副本")
    y, sr, origin = read_region(request["asset"], start, end)
    progress(0.2, "計算真正的 Constant-Q 音高能量")
    hop = 256
    bins = int(round((high - low) * bpo / 12)) + 1
    magnitude = cqt_amplitude(y, sr, float(librosa.midi_to_hz(low)), bins, bpo)
    times = origin + np.arange(magnitude.shape[1]) * hop / sr
    selected = np.flatnonzero((times >= start) & (times <= end))
    if not selected.size:
        raise ValueError("分析區段沒有可顯示的音訊影格。")
    values = (20 * np.log10(np.maximum(magnitude[:, selected], 1e-6))).astype("<f4")
    progress(0.75, "擷取起音標記與時間基準")
    onset_frames = librosa.onset.onset_detect(y=y, sr=sr, hop_length=hop)
    onsets = [float(origin + frame * hop / sr) for frame in onset_frames if start <= origin + frame * hop / sr <= end]
    temporary = binary_path.with_suffix(".partial")
    values.tofile(temporary)
    temporary.replace(binary_path)
    result = dict(cacheKey=key, method=METHOD, sampleRate=sr, hop=hop, start=start, end=end, frameOrigin=float(times[selected[0]]), binsPerOctave=bpo, minMIDI=low, maxMIDI=high, rows=int(values.shape[0]), columns=int(values.shape[1]), binaryPath=str(binary_path), onsets=onsets, lowWindowSeconds=float((1 / (2 ** (1 / bpo) - 1)) / librosa.midi_to_hz(low)), tuningCents=0.0, elapsed=time.perf_counter()-started, cacheHit=False, warnings=["音高能量含諧波，亮線不等於 Bass 基頻。", "低頻窗口較長，起音位置請搭配波形與起音標記。"], sourceHash=request["asset"]["hash"])
    if guide:
        progress(0.85, "估計 Bass stem 基頻")
        result["pitchTrace"] = bass_pitch_trace(y, sr, origin, start, end)
    write_json(metadata_path, result)
    return result

# 大、小三和弦方向的模板比對：使用全頻段 chroma；不能只由 Bass 首音命名和弦。
def rank_chord_templates(chroma):
    c = np.maximum(np.asarray(chroma, dtype=float), 0)
    if np.linalg.norm(c) < 1e-8:
        return c, []
    c = c / np.linalg.norm(c)
    scores = []
    for root in range(12):
        for quality, intervals in [("maj", [0, 4, 7]), ("min", [0, 3, 7])]:
            template = np.zeros(12)
            template[(root + np.array(intervals)) % 12] = [1.05, 1.0, 0.8]
            template /= np.linalg.norm(template)
            similarity = float(np.dot(c, template))
            notes = [(root + i) % 12 for i in intervals]
            support = [PITCH_NAMES[i] for i in notes if c[i] > c.max() * 0.22]
            # Sevenths/extensions are allowed evidence, not automatically errors.
            conflict = [PITCH_NAMES[i] for i in range(12) if i not in notes and c[i] > c.max() * 0.7]
            scores.append(dict(root=root, quality=quality, symbol=PITCH_NAMES[root]+("m" if quality=="min" else ""), score=similarity, support=support, conflict=conflict))
    scores.sort(key=lambda x: x["score"], reverse=True)
    return c, scores


def chord_candidates(chroma):
    c, scores = rank_chord_templates(chroma)
    if not scores:
        return [], None, None, 0.0
    best = scores[0]
    other_root = next(s for s in scores if s["root"] != best["root"])
    margin = best["score"] - other_root["score"]
    # root 與品質分開決定。閾值為初版啟發式，尚未以真實歌曲標註校準成機率。
    root = best["root"] if best["score"] >= 0.70 and margin >= 0.045 and len(best["support"]) >= 2 else None
    other_quality = next(s for s in scores if s["root"] == best["root"] and s["quality"] != best["quality"])
    third = (best["root"] + (4 if best["quality"] == "maj" else 3)) % 12
    symbol = best["symbol"] if root is not None and best["score"]-other_quality["score"] >= 0.06 and c[third] >= c.max()*0.25 else None
    return scores[:5], root, symbol, margin

def period_correlation(segment, lag):
    if len(segment) <= lag * 2:
        return 0.0
    left, right = segment[:-lag], segment[lag:]
    return float(np.dot(left, right) / max(1e-10, np.linalg.norm(left) * np.linalg.norm(right)))


# 首音原型：需要連續穩定影格、可見基頻與週期性。不是完整 F0／逐音符模型。
def bass_summary(y, sr, origin, start, end, is_stem):
    hop = 256
    mag = cqt_amplitude(y, sr, float(librosa.midi_to_hz(23)), 64, 12)
    times = origin + np.arange(mag.shape[1])*hop/sr
    selection = np.flatnonzero((times >= start) & (times < end))
    if selection.size == 0:
        return None, None, 0.0, None, None
    rms = librosa.feature.rms(y=y, frame_length=512, hop_length=hop)[0]

    def waveform(second):
        center = int((second - origin) * sr)
        return y[max(0, center-int(sr*0.03)):min(len(y), center+int(sr*0.24))]

    return summarize_bass(mag[:, selection], rms[selection], times[selection], sr, is_stem, waveform)


def summarize_bass(mag, rms, times, sr, is_stem, waveform):
    if not times.size:
        return None, None, 0.0, None, None
    # Fundamental evidence is mandatory; upper harmonics only strengthen it.
    low = mag[:38]
    salience = low.copy()
    salience += 0.35 * mag[12:50] + 0.15 * mag[19:57]
    winners = salience.argmax(axis=0)
    frames = np.arange(times.size)
    winner_values = salience[winners, frames]
    sorted_values = np.sort(salience, axis=0)
    contrast = np.maximum(0, (winner_values - sorted_values[-2]) / np.maximum(winner_values, 1e-8))
    fundamental = low[winners, frames] / np.maximum(winner_values, 1e-8)
    # Windowed waveform energy prevents a preceding silent region from inheriting CQT smear.
    active = rms > max(0.0008, float(rms.max()) * 0.09)
    valid = active & (fundamental > 0.24) & (contrast > (0.12 if is_stem else 0.22))
    first, first_time, first_score = None, None, 0.0
    # 尋找區間內第一段足夠穩定的音高；可能略晚於真正 onset，尤其遇到滑音或弱基頻。
    for i in range(max(0, len(winners)-3)):
        if valid[i:i+4].all() and np.all(winners[i:i+4] == winners[i]):
            candidate = int(winners[i]+23)
            segment = waveform(times[i]).astype(float)
            segment -= np.mean(segment)
            lag = int(round(sr / librosa.midi_to_hz(candidate)))
            if len(segment) <= lag*2:
                continue
            periodicity = period_correlation(segment, lag)
            if periodicity < (0.35 if is_stem else 0.45):
                continue
            # A stronger second harmonic can win the CQT vote. Only lower the
            # stem candidate when a stable sub-octave peak and the longer
            # waveform period both support it. Leave ambiguous cases alone.
            lower = int(winners[i]) - 12
            if is_stem and lower >= 0:
                frames = slice(i, i + 4)
                lower_peak = low[lower, frames]
                neighbors = low[max(0, lower - 1):lower + 2, frames]
                if np.all(lower_peak >= 0.20 * low[winners[i], frames]) and np.all(
                    lower_peak == neighbors.max(axis=0)
                ):
                    lower_lag = int(round(sr / librosa.midi_to_hz(candidate - 12)))
                    lower_periodicity = period_correlation(segment, lower_lag)
                    if lower_periodicity >= 0.70 and lower_periodicity - periodicity >= 0.12:
                        candidate -= 12
                        periodicity = lower_periodicity
            first, first_time, first_score = candidate, float(times[i]), float((np.mean(contrast[i:i+4]) + periodicity)/2)
            break
    valid_pitch = winners[valid] + 23
    center = int(np.median(valid_pitch)) if valid_pitch.size and first is not None else None
    # 初版只取區間起始可用音，尚未獨立建模節拍強弱；不要把此欄解讀為已完成重音分析。
    strong = int(winners[0]+23) if valid.size and valid[0] else first
    if first is not None and i == 0:
        strong = first
    return first, first_time, first_score, center, strong

# 快取保存自動 Evidence；回用時更新 timingRevision，但不需要把純 revision 加入音訊特徵鍵。
def harmony_job(request, progress=lambda *_: None):
    cache = Path(request["cache"]) if request.get("cache") else None
    settings = {k: request[k] for k in ("start", "end")}
    for name in ("arrangement", "bass"):
        asset = request.get(name) or request["arrangement"]
        settings[name] = {k: asset.get(k) for k in ("hash", "offset", "role")}
    method = request.get("method", HARMONY_METHOD)
    if method not in (HARMONY_METHOD, SOURCE_HARMONY_METHOD, TUNED_HARMONY_METHOD):
        raise ValueError("不支援的和聲分析方法。")
    settings["method"] = method
    key = cache_key(settings)
    path = cache / f"harmony-{key}.json" if cache else None
    if path and path.exists():
        try:
            result = json.loads(path.read_text())
            if result["method"] == method and isinstance(result["candidates"], list):
                result["cacheHit"] = True
                result["timingRevision"] = request.get("timingRevision", 0)
                return result
        except (ValueError, KeyError, OSError):
            pass
    if method == HARMONY_METHOD:
        result = _harmony_compute(request, progress)
    else:
        from harmony_features import cached_harmony
        result = cached_harmony(request, progress, cache, method)
    result["cacheHit"] = False
    result["cacheKey"] = key
    if path:
        cache.mkdir(parents=True, exist_ok=True)
        write_json(path, result)
    return result

def _harmony_compute(request, progress=lambda *_: None):
    start, end = float(request["start"]), float(request["end"])
    if not math.isfinite(start+end) or end<=start or end-start>90:
        raise ValueError("請選取 0.15–90 秒的和聲分析區段。")
    progress(0.08, "讀取和聲與低音分析來源")
    arrangement = request["arrangement"]
    bass = request.get("bass") or arrangement
    y, sr, origin = read_region(arrangement, start, end)
    progress(0.24, "分離持續音色特徵並計算全頻段 chroma")
    hop, nfft = 256, 4096
    spectrum = np.abs(librosa.stft(y, n_fft=nfft, hop_length=hop))
    harmonic, _ = librosa.decompose.hpss(spectrum, margin=2.0)
    frequencies = librosa.fft_frequencies(sr=sr, n_fft=nfft)
    # 降低最底部低頻對和弦模板的主導，並用 HPSS 減少打擊干擾；不是人聲／Bass 分軌。
    harmonic[frequencies < 90] *= 0.15
    harmonic[frequencies > 5000] = 0
    chroma = librosa.feature.chroma_stft(S=harmonic**2, sr=sr, hop_length=hop, n_fft=nfft, tuning=0.0, norm=2)
    times = origin + np.arange(chroma.shape[1])*hop/sr
    selected = (times >= start) & (times < end)
    if not selected.any():
        raise ValueError("和聲區段沒有可用影格。")
    energy = harmonic[:, selected].sum(axis=0)
    average = np.average(chroma[:, selected], axis=1, weights=np.maximum(energy, 1e-8))
    local_samples = y[max(0,int((start-origin)*sr)):min(len(y),int((end-origin)*sr))]
    silent = not len(local_samples) or float(np.sqrt(np.mean(local_samples**2))) < 0.0004
    candidates, root, chord, margin = chord_candidates(average if not silent else np.zeros(12))
    progress(0.65, "獨立估計 Bass 首音候選；不以首音決定 Root")
    # 和聲來源與 Bass 來源獨立。伴奏靜音／Root 不明，不能因此刪除可靠的 Bass 首音。
    by, bsr, borigin = read_region(bass, start, end)
    is_stem = bass.get("role") == "bass"
    first, first_time, first_score, center, strong = bass_summary(by, bsr, borigin, start, end, is_stem)
    return harmony_evidence(request, average, silent, (first, first_time, first_score, center, strong),
                            HARMONY_METHOD, (candidates, root, chord, margin))


def harmony_evidence(request, average, silent, bass_result, method, harmony_result=None):
    arrangement = request["arrangement"]
    bass = request.get("bass") or arrangement
    first, first_time, first_score, center, strong = bass_result
    if harmony_result is None:
        harmony_result = chord_candidates(average if not silent else np.zeros(12))
    candidates, root, chord, margin = harmony_result
    warnings = []
    if bass.get("role") != "bass":
        warnings.append("未提供 Bass stem：首音來自混音低頻，可能受鼓或其他樂器干擾，僅供核對。")
    if root is None:
        warnings.append("Root 證據不足，主標籤保留空白；候選分數不是正確機率。")
    if silent:
        warnings.append("和聲來源能量過低，Root／和弦保留空白；Bass 首音依獨立來源判斷。")
    return dict(firstPitch=first, firstTime=first_time, firstScore=first_score, bassCenter=center, bassStrongBeat=strong, root=root, chord=chord, rootMargin=float(margin), candidates=candidates, chroma=[float(x) for x in average], warnings=warnings, arrangementSource=arrangement["hash"], bassSource=bass["hash"], method=method, timingRevision=request.get("timingRevision", 0), createdAt=datetime.now(timezone.utc).isoformat())
