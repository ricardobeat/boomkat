"""CI verdict propagation: python3 -m unittest discover -s scripts -p test_test262_ci.py."""
import contextlib
import io
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import run_test262 as runner


class SingleVerdictTests(unittest.TestCase):
    def test_worker_verdict_and_exit_status(self):
        path = '/test/example.js'
        cases = [('PASS', 0, 0), ('FAIL', 0, 1), ('COMPILE_ERROR', 0, 1),
                 ('PASS', 1, 1), ('', 0, 1)]
        for verdict, status, expected in cases:
            with self.subTest(verdict=verdict, status=status), \
                 patch.object(runner, '_resolve_single_path', return_value=path), \
                 patch.object(runner, 'skip_reason', return_value=None), \
                 patch.object(runner.os.path, 'isfile', return_value=True), \
                 patch.object(runner.subprocess, 'run', return_value=subprocess.CompletedProcess(
                     [], status, f'{verdict} {path}' if verdict else '', '')), \
                 contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(runner.run_single(path), expected)

    def test_debug_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            combined = Path(directory) / 'combined.js'
            combined.touch()
            with patch.object(runner, '_resolve_single_path', return_value='/test/example.js'), \
                 patch.object(runner, 'skip_reason', return_value=None), \
                 patch.object(runner, '_build_concat_file', return_value=str(combined)), \
                 patch.object(runner.os.path, 'isfile', return_value=True), \
                 patch.object(runner.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, '', '')), \
                 contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(runner.run_single('example.js', debug=True), 1)
            self.assertFalse(combined.exists())


class GateTests(unittest.TestCase):
    def test_gate_and_failure_diagnostics(self):
        for failures, status, summary in [(0, 0, True), (1, 0, True), (0, 1, True), (0, 0, False)]:
            with self.subTest(failures=failures, status=status, summary=summary), \
                 tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                scripts = root / 'scripts'
                scripts.mkdir()
                shutil.copyfile(Path(__file__).with_name('test262_gate.sh'), scripts / 'test262_gate.sh')
                verdict = 'FAIL' if failures else 'PASS'
                results = f'{verdict}\tstaging/example.js\n'
                (scripts / 'run_test262.py').write_text(
                    'from pathlib import Path\n'
                    f'Path("out/test262-results.tsv").write_text({results!r})\n'
                    + (f'print("Overall (raw): 1 pass / {failures} fail / 0 CE (100.0%)")\n' if summary else '')
                    + f'raise SystemExit({status})\n')
                result = subprocess.run(['bash', str(scripts / 'test262_gate.sh')], capture_output=True, text=True)
                self.assertEqual(result.returncode, int(bool(failures or status or not summary)))
                if failures:
                    self.assertIn('FAIL\tstaging/example.js', result.stdout)
                self.assertTrue((root / 'out/test262-results.tsv').exists())
