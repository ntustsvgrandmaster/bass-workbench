"""Fetch the pinned, BSD-licensed renderer from the official npm registry."""
import base64
import hashlib
import io
import json
from pathlib import Path
import tarfile
import subprocess

root = Path(__file__).resolve().parent
version = "2.2.1"
def fetch(url):
    return subprocess.check_output(["/usr/bin/curl", "--fail", "--location", "--silent", "--show-error", url])

metadata = json.loads(fetch(f"https://registry.npmjs.org/opensheetmusicdisplay/{version}"))
archive = fetch(metadata["dist"]["tarball"])
algorithm, expected = metadata["dist"]["integrity"].split("-", 1)
assert algorithm == "sha512"
assert base64.b64encode(hashlib.sha512(archive).digest()).decode() == expected
destination = root / "resources" / "score-viewer"
destination.mkdir(parents=True, exist_ok=True)
with tarfile.open(fileobj=io.BytesIO(archive), mode="r:gz") as tar:
    for name, target in [("package/build/opensheetmusicdisplay.min.js", "osmd.min.js"), ("package/LICENSE", "OSMD-LICENSE")]:
        member = tar.extractfile(name)
        assert member is not None
        (destination / target).write_bytes(member.read())
(destination / "dependency.json").write_text(json.dumps({"name": "opensheetmusicdisplay", "version": version, "registry": "https://registry.npmjs.org", "integrity": metadata["dist"]["integrity"], "license": metadata["license"]}, indent=2))
print("Pinned OSMD renderer and license saved locally.")
