"""Protocol validation without installing optional ML packages in the base runtime."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

class OptionalWorkerProtocolTests(unittest.TestCase):
    def test_wrong_weights_returns_error_without_torch_import_or_download(self):
        script=Path(__file__).resolve().parents[1]/'worker/beat_this_tempo.py'
        with tempfile.TemporaryDirectory() as root:
            checkpoint=Path(root)/'invalid.ckpt';checkpoint.write_bytes(b'wrong weights')
            # Closed stdin permits the one-shot protocol child to exit after its reply.
            result=subprocess.run([sys.executable,'-u',str(script)],input=json.dumps(dict(
                id='bad-weights',op='tempo',estimator='small0',checkpoint=str(checkpoint)))+'\n',
                text=True,capture_output=True,timeout=10,env={**os.environ,'PYTHONDONTWRITEBYTECODE':'1'})
            response=json.loads(result.stdout.strip())
            self.assertEqual(response['id'],'bad-weights')
            self.assertEqual(response['type'],'error')
            self.assertIn('權重版本不符',response['message'])
            self.assertNotIn('ModuleNotFoundError',result.stderr)

if __name__=='__main__':unittest.main()
