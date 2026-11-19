from pathlib import Path
import shutil,subprocess,zipfile,json,hashlib,sys
root=Path(__file__).resolve().parent
outputs=Path(sys.argv[1]).resolve() if len(sys.argv)>1 else root/'build'
app=outputs/'Bass Harmony Workbench.app'
# Only generated interpreter caches are removed; original dependency licenses stay intact.
for cache in (app/'Contents/Resources/worker').glob('__pycache__'):
    shutil.rmtree(cache)
subprocess.run(['/usr/bin/codesign','--force','--deep','--sign','-',str(app)],check=True)
subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict',str(app)],check=True)
subprocess.run(['/usr/bin/ditto','-c','-k','--sequesterRsrc','--keepParent',str(app),str(outputs/'BassHarmony-v0.2-macOS.zip')],check=True)
files=[]
for pattern in ('app/*.swift','worker/*.py','resources/**/*','tests/test_analysis.py','tests/NativeTests.swift'):
    files.extend(p for p in root.glob(pattern) if p.is_file() and '__pycache__' not in p.parts)
for name in ('README.md','LICENSE','THIRD_PARTY_NOTICES.md','requirements.txt','requirements-lock.txt','build.sh','test.sh','bundle_runtime.py','fetch_score_renderer.py','package_release.py','.gitignore'):
    files.append(root/name)
with zipfile.ZipFile(outputs/'BassHarmony-v0.2-source.zip','w',zipfile.ZIP_DEFLATED) as archive:
    for path in sorted(set(files)):
        archive.write(path,Path('BassHarmony')/path.relative_to(root))
for name in ('BassHarmony-v0.2-macOS.zip','BassHarmony-v0.2-source.zip'):
    path=outputs/name
    with zipfile.ZipFile(path) as z:
        assert z.testzip() is None
        assert not any('.basswork/' in n or n.endswith(('.m4a','.mscz')) for n in z.namelist())
    print(name,round(path.stat().st_size/1024**2,2),'MiB; ZIP integrity passed; no private song assets')
print('Source files:',len(set(files)))
