"""Opt-in local model experiment. No audio or model is downloaded by this script.

The constant-tempo reference is provisional, not manually annotated ground truth.
Run each backend in its own process; keep outputs and all media outside Git.
"""
import argparse
import hashlib
import gc
import json
import math
import os
from pathlib import Path
import resource
import sys
import time


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--audio', required=True)
    p.add_argument('--output', required=True)
    p.add_argument('--engine', choices=['librosa', 'small0', 'final0'], required=True)
    p.add_argument('--device', choices=['cpu', 'mps'], default='cpu')
    p.add_argument('--checkpoint')
    p.add_argument('--start', type=float, default=0)
    p.add_argument('--duration', type=float, default=90)
    p.add_argument('--bpm', type=float, default=190)
    p.add_argument('--origin', type=float, default=0.44)
    a = p.parse_args()
    Path(a.output).parent.mkdir(parents=True, exist_ok=True)
    if not all(map(math.isfinite,[a.start,a.duration,a.bpm,a.origin])) or a.start < 0 or not 0 < a.duration <= 90 or not 20 <= a.bpm <= 400:
        p.error('finite values required: start >= 0, 0 < duration <= 90, 20 <= bpm <= 400')
    os.environ.setdefault('NUMBA_NUM_THREADS', '2')
    os.environ.setdefault('OMP_NUM_THREADS', '2')
    os.environ.setdefault('OPENBLAS_NUM_THREADS', '2')
    started = time.perf_counter()
    import numpy as np
    import soundfile as sf
    import mir_eval
    import importlib.metadata as md
    info = sf.info(a.audio)
    if info.samplerate != 22050 or info.channels != 1:
        raise ValueError('Supply common 22050 Hz mono WAV to keep decoders identical')
    signal, sr = sf.read(a.audio, start=round(a.start*22050), frames=round(a.duration*22050), dtype='float32')
    end = a.start + len(signal)/sr
    result = dict(engine=a.engine, device=a.device, start=a.start, end=end, threads=2,
                  reference=dict(bpm=a.bpm, first_bar_seconds=a.origin, status='provisional constant grid, not ground truth'),
                  audio_sha256=hashlib.sha256(Path(a.audio).read_bytes()).hexdigest(), runs=[])
    step = 60/a.bpm
    reference = np.arange(a.origin, end, step)
    def metrics(prediction):
        prediction = np.asarray(prediction, dtype=float)
        output = {}
        # Fixed predeclared windows; never optimize phase against predictions.
        for lo, hi in [(max(5,a.start),end),(max(5,a.start),min(30,end)),(max(30,a.start),min(60,end)),(max(60,a.start),end)]:
            if hi <= lo: continue
            ref = reference[(reference >= lo) & (reference < hi)]
            pred = prediction[(prediction >= lo) & (prediction < hi)]
            row = dict(reference_beats=len(ref), predicted_beats=len(pred))
            for ms in [20,30,70]:
                row[f'f1_{ms}ms'] = float(mir_eval.beat.f_measure(ref,pred,f_measure_threshold=ms/1000))
            for parity in [0,1]:
                half = reference[parity::2]; half=half[(half>=lo)&(half<hi)]
                row[f'half_grid_{parity}_f1_70ms'] = float(mir_eval.beat.f_measure(half,pred,f_measure_threshold=.07))
            if len(pred)>1: row['median_interval_bpm'] = float(60/np.median(np.diff(pred)))
            if len(pred) and len(ref):
                signed = (pred[:,None]-ref[None,:]); nearest=signed[np.arange(len(pred)),np.argmin(abs(signed),axis=1)]
                row.update(nearest_grid_median_ms=float(np.median(nearest)*1000), nearest_grid_p95_absolute_ms=float(np.percentile(abs(nearest),95)*1000))
            output[f'{lo:g}-{hi:g}s'] = row
        return output
    if a.engine == 'librosa':
        import librosa
        sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'worker'))
        from analysis import tempo_job
        result['setup_seconds'] = time.perf_counter()-started
        # Same bounded application pipeline; its returned beats are matched onset
        # observations, not a complete regular tracker sequence. Report separately.
        for repeat in range(2):
            t=time.perf_counter()
            # tempo_job always reads file start; use shared segment file for nonzero windows.
            import tempfile
            with tempfile.TemporaryDirectory(dir=Path(a.output).parent) as folder:
                segment=Path(folder)/'segment.wav'; sf.write(segment,signal,sr,subtype='FLOAT')
                output=tempo_job(dict(asset=dict(path=str(segment),hash=result['audio_sha256'],offset=0)))
            elapsed=time.perf_counter()-t
            t=time.perf_counter()
            env=np.maximum(0,librosa.onset.onset_strength(y=signal,sr=sr,hop_length=256)-.1)
            tempo,frames=librosa.beat.beat_track(onset_envelope=env,sr=sr,hop_length=256,trim=True)
            raw=a.start+np.asarray(frames)*256/sr
            observations=a.start+np.asarray(output['beats'])
            result['runs'].append(dict(app_seconds=elapsed,tracker_seconds=time.perf_counter()-t,
              app_bpm=output['bpm'],raw_bpm=float(np.asarray(tempo).item()), candidates=output['candidates'],
              beats=raw.tolist(), metrics=metrics(raw), app_observation_metrics=metrics(observations)))
    else:
        import torch
        torch.set_num_threads(2)
        from beat_this.inference import Audio2Beats
        if not a.checkpoint: p.error('explicit local checkpoint required; download separately')
        t=time.perf_counter()
        model=Audio2Beats(checkpoint_path=a.checkpoint,device=a.device,dbn=False)
        result['load_seconds']=time.perf_counter()-t
        result['setup_seconds']=time.perf_counter()-started
        result['weights_sha256']=hashlib.sha256(Path(a.checkpoint).read_bytes()).hexdigest()
        result['mps_available']=torch.backends.mps.is_available()
        for repeat in range(2):
            if a.device=='mps': torch.mps.synchronize()
            t=time.perf_counter(); beats,downbeats=model(signal,sr)
            if a.device=='mps': torch.mps.synchronize()
            elapsed=time.perf_counter()-t
            result['runs'].append(dict(inference_seconds=elapsed, beats=(a.start+beats).tolist(),
                downbeats=(a.start+downbeats).tolist(),metrics=metrics(a.start+beats)))
        import psutil
        result['rss_before_unload_bytes'] = psutil.Process().memory_info().rss
        if a.device=='mps':
            result['mps_allocated_bytes']=torch.mps.current_allocated_memory()
            result['mps_driver_bytes']=torch.mps.driver_allocated_memory()
        del model
        gc.collect()
        if a.device=='mps':
            torch.mps.synchronize(); torch.mps.empty_cache()
            result['mps_allocated_after_unload_bytes']=torch.mps.current_allocated_memory()
            result['mps_driver_after_unload_bytes']=torch.mps.driver_allocated_memory()
        result['rss_after_unload_bytes']=psutil.Process().memory_info().rss
    result['peak_process_rss_bytes']=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss * (1 if sys.platform=='darwin' else 1024)
    result['versions']={name:md.version(name) for name in ['numpy','librosa','torch','torchaudio','beat-this','mir_eval']}
    Path(a.output).write_text(json.dumps(result,indent=2))
    print(json.dumps({k:v for k,v in result.items() if k!='runs'}),flush=True)
    for run in result['runs']:
        print(json.dumps({k:v for k,v in run.items() if k not in ['beats','downbeats','candidates']}),flush=True)

if __name__ == '__main__': main()
