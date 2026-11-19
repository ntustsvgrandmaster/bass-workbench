"""Optional CPU-only small0 worker. Explicit local weights; no downloads.

Each app request uses its own process so PyTorch memory does not stay resident.
"""
import hashlib
import json
import math
from pathlib import Path
import sys
import time
import numpy as np
import soundfile as sf
from tempo import fit_continuous_tempo, select_tempo_candidate, match_observations

WEIGHTS_HASH = '6074be2c4d490c5f6101fcc374a1ec72ae93456e23bb6019783b849f5dc7d47b'
METHOD = 'beat-this-small0-1.1.0-cpu-gridfit-v2'


def match_grid(beats, period, origin):
    tolerance = min(.08, period * .2)
    first = origin + math.ceil((beats[0] - tolerance - origin) / period) * period
    references = np.arange(first, beats[-1] + tolerance, period)
    times, indices = match_observations(beats, references, tolerance)
    return times, indices, len(references)


def beat_candidates(beats):
    """Fit alternative periodic grids to observed model peaks; never invent observations.

Local windows propose tempo hypotheses. Global matched coverage and rejected
peaks guard against mixed metrical levels being treated as a confident tempo.
"""
    beats = np.asarray(beats, dtype=float)
    if len(beats) < 8 or not np.all(np.isfinite(beats)) or np.any(np.diff(beats) <= 0):
        return []
    proposals = []
    for start in range(0, len(beats)-7, 4):
        period = np.polyfit(np.arange(8), beats[start:start+8], 1)[0]
        tempo = 60/period
        for multiplier in (1,.5,2):
            value = tempo*multiplier
            if 20 <= value <= 400 and all(abs(value-v) > .8 for v in proposals): proposals.append(value)
    hypotheses = []
    for tempo in proposals:
        period = 60 / tempo
        # The first detected beat need not be on the best grid. Try evenly spaced
        # phases and use the one supported by the most observed beats.
        phases = np.arange(12) * period / 12
        relative = beats[:, None] - beats[0] - phases
        distance = np.abs((relative + period / 2) % period - period / 2)
        counts = np.count_nonzero(distance <= min(.08, period * .2), axis=0)
        origin = beats[0] + phases[np.argmax(counts)]
        times, indices, _ = match_grid(beats, period, origin)
        if len(times) < 8: continue
        try:
            period = 60 / fit_continuous_tempo(times, indices)
            origin = float(np.median(np.asarray(times) - np.asarray(indices) * period))
            # Reassign observed beats after refitting so the initial BPM drift
            # does not discard otherwise consistent observations.
            times, indices, reference_count = match_grid(beats, period, origin)
            if len(times) < 8: continue
            continuous = fit_continuous_tempo(times, indices)
            grid_coverage = len(times) / reference_count
            observation_coverage = len(times) / len(beats)
            candidate = select_tempo_candidate(times, indices, continuous, min(grid_coverage, observation_coverage))
        except ValueError: continue
        if candidate['fit']['status']=='insufficient': continue
        candidate['multiplier']=1.0
        # Sparse grids or rejected observations indicate metrical ambiguity.
        # Residuals describe matched model peaks only, not correctness probability.
        if grid_coverage < .85 or observation_coverage < .85:
            candidate['fit']['status']='poor'
        score=(candidate['fit']['status'] not in ('good','borderline'), -len(times)/len(beats), candidate['fit']['p95Ms'])
        hypotheses.append((score,candidate))
    selected=[]
    for _,c in sorted(hypotheses,key=lambda item:item[0]):
        if all(abs(c['bpm']-v['bpm'])>.8 for v in selected): selected.append(c)
        if len(selected)==3: break
    return selected


def tempo_job(request,progress=lambda *_:None):
    started=time.perf_counter()
    if request.get('estimator')!='small0': raise ValueError('Unknown optional estimator')
    checkpoint=Path(request['checkpoint'])
    if hashlib.sha256(checkpoint.read_bytes()).hexdigest()!=WEIGHTS_HASH:
        raise ValueError('small0 權重版本不符，請重新設定本機模型。')
    asset=request['asset']; offset=float(asset.get('offset',0)); info=sf.info(asset['path'])
    if not math.isfinite(offset) or info.duration<=0: raise ValueError('Invalid source time')
    start=max(0.,offset); end=min(offset+info.duration,start+90.)
    result=dict(bpm=None,alternatives=[],beats=[],downbeats=[],start=start,end=end,sourceHash=asset['hash'],
      method=METHOD,estimator='small0',weightsHash=WEIGHTS_HASH,candidates=[],resolutionMs=20,
      warnings=['拍點與小節第一拍為模型候選，並非譜面對齊或正確機率。'])
    if end-start<4: return result
    progress(.1,'載入 small0（CPU）；只估測開頭最多 90 秒')
    first=round((start-offset)*info.samplerate)
    signal,sr=sf.read(asset['path'],start=first,frames=round((end-start)*info.samplerate),dtype='float32',always_2d=True)
    signal=signal.mean(axis=1)
    if sr!=22050:
        import soxr
        signal=soxr.resample(signal,sr,22050);sr=22050
    if float(np.sqrt(np.mean(signal**2)))<.0004: return result
    import torch
    from beat_this.inference import Audio2Beats
    import importlib.metadata
    if importlib.metadata.version('beat-this')!='1.1.0': raise ValueError('需要 Beat This! 1.1.0 本機環境。')
    torch.set_num_threads(2)
    model=Audio2Beats(checkpoint_path=str(checkpoint),device='cpu',dbn=False)
    progress(.35,'small0 本機推論')
    beats,downbeats=model(signal,sr)
    beats=np.asarray(beats)+start
    progress(.85,'評估候選速度、量化與拍層級一致性')
    candidates=beat_candidates(beats)
    result.update(beats=beats.tolist(),downbeats=(np.asarray(downbeats)+start).tolist(),
                  candidates=candidates,alternatives=[c['bpm'] for c in candidates],elapsed=time.perf_counter()-started)
    if candidates:
        result['bpm']=candidates[0]['bpm'];result['rawBPM']=candidates[0]['originalBPM']
        if candidates[0]['fit']['status'] not in ('good','borderline'):
            result['warnings'].append('拍層級或速度不一致，需人工確認；不自動套用建議。')
    return result


def emit(value): print(json.dumps(value,ensure_ascii=False,allow_nan=False),flush=True)

if __name__=='__main__':
    request=None
    try:
        request=json.loads(sys.stdin.readline())
        if request.get('op')!='tempo': raise ValueError('Only tempo requests supported')
        result=tempo_job(request,lambda value,message:emit(dict(id=request['id'],type='progress',progress=value,message=message)))
        emit(dict(id=request['id'],type='result',result=result))
    except Exception as error:
        emit(dict(id=request.get('id','') if request else '',type='error',message=str(error)))
        import traceback
        traceback.print_exc(file=sys.stderr)
    finally:
        # Wait for the parent to consume the JSON before it terminates this worker.
        # Avoid an exit/stdout race; the parent always ends this one-shot process.
        sys.stdin.read()
