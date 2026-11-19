"""Create disposable synthetic audio and a real worker cache for Swift integration tests."""
import hashlib
import json
from pathlib import Path
import sys

import numpy as np
import soundfile as sf

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "worker"))
from analysis import feature_job

root = Path(sys.argv[1]).resolve()
root.mkdir(parents=True, exist_ok=True)
audio = root / "synthetic.wav"
samples = np.arange(22050 * 6) / 22050
sf.write(audio, 0.15 * np.sin(2 * np.pi * 41.2034 * samples), 22050, subtype="FLOAT")
asset = dict(path=str(audio), hash=hashlib.sha256(audio.read_bytes()).hexdigest(), offset=0)
features = feature_job(dict(asset=asset, start=0, end=4.0, minMIDI=23, maxMIDI=60,
                            binsPerOctave=24, cache=str(root / "features")))
feature_job(dict(asset=dict(asset, offset=0.45), start=0, end=4.0, minMIDI=23, maxMIDI=60,
                 binsPerOctave=24, cache=str(root / "features")))
(root / "fixture.json").write_text(json.dumps(dict(asset=asset, features=features)))
print("Created synthetic worker cache fixture", flush=True)
