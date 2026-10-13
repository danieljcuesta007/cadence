"""qa/make-dmg.sh against a tiny fake app: it must refuse a wrong model, missing
licenses or a broken signature, and on success write the checksum to the cask and site."""
import hashlib
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class MakeDmgTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='cadence-dmg-')).resolve()
        for rel in ('qa/make-dmg.sh', 'Casks/cadence.rb', 'site/index.html', 'LICENSE', 'THIRD_PARTY_NOTICES.md'):
            (self.tmp / rel).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(ROOT / rel, self.tmp / rel)
        model = b'fake multilingual model'
        (self.tmp / 'models').mkdir()
        (self.tmp / 'models/fetch-models.sh').write_text(
            f'fetch ggml-small.bin \\\n    "https://example.invalid/ggml-small.bin" \\\n    "{hashlib.sha256(model).hexdigest()}"\n')
        self.app = self.tmp / 'dist/Cadence.app'
        res = self.app / 'Contents/Resources'
        (res / 'models').mkdir(parents=True)
        (self.app / 'Contents/MacOS').mkdir()
        (res / 'models/ggml-small.bin').write_bytes(model)
        shutil.copy(ROOT / 'LICENSE', res); shutil.copy(ROOT / 'THIRD_PARTY_NOTICES.md', res)
        (self.app / 'Contents/MacOS/Cadence').write_text('#!/bin/sh\n')
        (self.app / 'Contents/MacOS/Cadence').chmod(0o755)
        (self.app / 'Contents/Info.plist').write_text('<?xml version="1.0"?><plist version="1.0"><dict>'
            '<key>CFBundleShortVersionString</key><string>9.9.9</string><key>CFBundleExecutable</key><string>Cadence</string><key>CFBundleIdentifier</key><string>dev.cadence.test</string></dict></plist>')
        self.sign()

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def sign(self):
        subprocess.run(['codesign', '--force', '--sign', '-', str(self.app)], check=True, capture_output=True)

    def run_script(self):
        return subprocess.run(['bash', 'qa/make-dmg.sh', '9.9.9'], cwd=self.tmp, capture_output=True, text=True, timeout=300)

    def test_builds_and_records_the_checksum_everywhere(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        sha = hashlib.sha256((self.tmp / 'dist/Cadence.dmg').read_bytes()).hexdigest()
        cask = (self.tmp / 'Casks/cadence.rb').read_text()
        self.assertIn(f'sha256 "{sha}"', cask)
        self.assertIn('version "9.9.9"', cask)
        self.assertIn(f'<code data-sha>{sha}</code>', (self.tmp / 'site/index.html').read_text())

    def test_refuses_a_model_that_is_not_the_pinned_one(self):
        (self.app / 'Contents/Resources/models/ggml-small.bin').write_bytes(b'english only')
        self.sign()
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('pinned hash', result.stderr)
        self.assertFalse((self.tmp / 'dist/Cadence.dmg').exists())

    def test_refuses_a_version_the_app_does_not_carry(self):
        result = subprocess.run(['bash', 'qa/make-dmg.sh', '9.9.8'], cwd=self.tmp, capture_output=True, text=True, timeout=300)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("the app says version '9.9.9'", result.stderr)
        bad = subprocess.run(['bash', 'qa/make-dmg.sh', 'v9.9.9'], cwd=self.tmp, capture_output=True, text=True, timeout=300)
        self.assertNotEqual(bad.returncode, 0)
        self.assertIn('no leading v', bad.stderr)
        self.assertIn('sha256 "UNRELEASED"', (self.tmp / 'Casks/cadence.rb').read_text())

    def test_refuses_without_licenses(self):
        (self.app / 'Contents/Resources/THIRD_PARTY_NOTICES.md').unlink()
        self.sign()
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('THIRD_PARTY_NOTICES.md missing', result.stderr)

    def test_refuses_a_tampered_app(self):
        (self.app / 'Contents/MacOS/Cadence').write_text('#!/bin/sh\necho changed\n')  # after signing
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('signature does not verify', result.stderr)


if __name__ == '__main__':
    unittest.main()
