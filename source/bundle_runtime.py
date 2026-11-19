"""Bundle the already available relocatable CPython and pinned analysis wheels."""
from pathlib import Path
import importlib.metadata
import json
import os
import shutil
import sys

root = Path(__file__).resolve().parent
app = Path(sys.argv[1])
prebundled = os.environ.get("BASS_PREBUNDLED_PYTHON")
base = Path(prebundled or os.environ.get("BASS_PYTHON_RUNTIME", str(root / "runtime")))
wheel_root = base if prebundled else root / ".venv"
wheel_source = wheel_root / "lib" / "python3.12" / "site-packages"
if not (base / "bin" / "python3.12").exists():
    raise SystemExit("Set BASS_PYTHON_RUNTIME to a relocatable arm64 CPython 3.12 runtime containing bin/python3.12 and lib/python3.12.")
destination = app / "Contents" / "Resources" / "python"
if destination.exists():
    raise SystemExit("The staged app already contains a Python runtime.")
if not wheel_source.is_dir():
    raise SystemExit(f"Missing analysis packages: {wheel_source}")
(destination / "bin").mkdir(parents=True)
shutil.copy2(base / "bin" / "python3.12", destination / "bin" / "python3.12")
shutil.copytree(base / "lib" / "python3.12", destination / "lib" / "python3.12",
                ignore=shutil.ignore_patterns("site-packages", "__pycache__", "test", "tests", "idlelib", "tkinter", "ensurepip"))
for library in (base / "lib").glob("libpython*.dylib"):
    shutil.copy2(library, destination / "lib" / library.name)
if (base / "licenses").exists():
    shutil.copytree(base / "licenses", destination / "licenses")
packages = destination / "lib" / "python3.12" / "site-packages"
shutil.copytree(wheel_source, packages,
                ignore=shutil.ignore_patterns("__pycache__", "tests", "test", "pip", "pip-*.dist-info"))
distributions = []
for dist in importlib.metadata.distributions(path=[str(packages)]):
    distributions.append({"name": dist.metadata["Name"], "version": dist.version, "license": dist.metadata.get("License-Expression") or dist.metadata.get("License") or "See bundled .dist-info licenses", "homepage": dist.metadata.get("Home-page", "")})
(app / "Contents" / "Resources" / "python-dependencies.json").write_text(json.dumps(sorted(distributions, key=lambda d: d["name"].lower()), indent=2))
print("Offline Python runtime and analysis dependencies bundled.")
