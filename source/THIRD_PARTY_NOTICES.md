# Third-party notices

Project MIT licensing covers only the original Bass Harmony Workbench source.
Third-party components retain their original licenses and copyrights.

- OpenSheetMusicDisplay **2.2.1**, BSD-3-Clause. Distribution and original LICENSE are in `resources/score-viewer/`. The prebuilt distribution includes its renderer dependencies; its original bundled license comments are preserved. `dependency.json` records package source and SHA512 verification. Source: https://github.com/opensheetmusicdisplay/opensheetmusicdisplay
- CPython **3.12.14**, Python Software Foundation license and its included component notices. The app contains the original `python/lib/python3.12/LICENSE.txt`. No interpreter source modifications were made.
- librosa **0.11.0**, ISC. https://github.com/librosa/librosa
- NumPy, SciPy, scikit-learn and their binary wheel components; Numba/llvmlite, soundfile/libsndfile, soxr/libsoxr, and the other Python dependencies are redistributed with original `.dist-info` metadata and available license directories. Licenses vary (including BSD, ISC, MIT, Apache and LGPL components). **Do not replace them with the project MIT license.**
- Exact dependency versions: `requirements-lock.txt`; packaged metadata inventory: app `Contents/Resources/python-dependencies.json`. Actual license texts: app `Contents/Resources/python/lib/python3.12/site-packages/*dist-info/` and related bundled library license directories. These remain in the app and should accompany redistribution.
- SwiftUI, AppKit, AVFoundation, WebKit and SQLite system libraries are provided by macOS and are not copied into the app.

### Optional local beat estimation

- [Beat This! 1.1.0](https://github.com/CPJKU/beat_this) and the published `small0` checkpoint are MIT-licensed by the upstream project. See the [upstream license](https://github.com/CPJKU/beat_this/blob/main/LICENSE) and its [statement on published weights](https://github.com/CPJKU/beat_this#license).
- Beat This!, its checkpoint, PyTorch and the other optional dependencies are installed separately in a local environment. The app ships the integration code and does not bundle that environment or the checkpoint. The optional evaluation versions are recorded in `tests/beat-evaluation-requirements.txt`. If these components are bundled in a future release, include their applicable upstream copyright, license and dependency notices.

- Optional [BTC-ISMIR19](https://github.com/jayg996/BTC-ISMIR19) model code is sourced from an external checkout with its [upstream MIT license](https://github.com/jayg996/BTC-ISMIR19/blob/master/LICENSE). Its checkpoint and optional Python environment are installed locally.

No separation weights or external chord model weights are distributed. MuseScore is separately installed by the user, only invoked for local score conversion. FFmpeg was used solely to create an optional synthetic FLAC test fixture; it is not packaged or required at runtime.

The separately provided private validation project contains user-owned audio and score copies. It is excluded from the application and source-code archives and is not licensed by the project MIT license.
