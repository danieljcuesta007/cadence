"""site/install.sh (the one-line installer) against a tiny fake release disk image: it must
install into Applications with no quarantine flag, refuse a wrong checksum or a foreign app,
update an existing Cadence in place and never touch ~/.cadence."""
import hashlib
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BUNDLE_ID = 'dev.cadence.app'


def make_app(path, bundle_id=BUNDLE_ID, version='9.9.9'):
    (path / 'Contents/MacOS').mkdir(parents=True)
    (path / 'Contents/MacOS/Cadence').write_text('#!/bin/sh\n')
    (path / 'Contents/MacOS/Cadence').chmod(0o755)
    (path / 'Contents/Info.plist').write_text('<?xml version="1.0"?><plist version="1.0"><dict>'
        f'<key>CFBundleShortVersionString</key><string>{version}</string><key>CFBundleExecutable</key><string>Cadence</string>'
        f'<key>CFBundleIdentifier</key><string>{bundle_id}</string></dict></plist>')


class InstallShTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='cadence-install-')).resolve()
        stage = self.tmp / 'stage'
        make_app(stage / 'Cadence.app')
        # A browser download carries this flag; the installer must not pass it on.
        subprocess.run(['xattr', '-w', 'com.apple.quarantine', '0083;00000000;Safari;', str(stage / 'Cadence.app')], check=True)
        self.dmg = self.tmp / 'Cadence.dmg'
        subprocess.run(['hdiutil', 'create', '-quiet', '-volname', 'Cadence', '-srcfolder', str(stage),
                        '-format', 'UDZO', '-fs', 'HFS+', '-ov', str(self.dmg)], check=True)
        self.sha = hashlib.sha256(self.dmg.read_bytes()).hexdigest()
        self.home = self.tmp / 'home'
        (self.home / '.cadence').mkdir(parents=True)
        (self.home / '.cadence/store.db').write_text('your history')
        self.apps = self.tmp / 'Applications'

    def tearDown(self):
        # A failing installer may leave its image mounted; never leak it past the test.
        info = subprocess.run(['hdiutil', 'info'], capture_output=True, text=True).stdout.split('================================================')
        for block in info:
            if str(self.tmp) in block:
                for line in block.splitlines():
                    if line.startswith('/dev/disk'):
                        subprocess.run(['hdiutil', 'detach', '-quiet', '-force', line.split()[0]], capture_output=True)
                        break
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_installer(self, sha=None, cut=None):
        script = (ROOT / 'site/install.sh').read_text()
        lines = [f'SHA256="{sha or self.sha}"' if l.startswith('SHA256="') else l for l in script.splitlines()]
        installer = self.tmp / 'install.sh'
        installer.write_text('\n'.join(lines) + '\n')
        (self.tmp / 'tmpdir').mkdir(exist_ok=True)
        env = dict(os.environ, HOME=str(self.home), TMPDIR=str(self.tmp / 'tmpdir'), CADENCE_URL=self.dmg.as_uri(),
                   CADENCE_APPS=str(self.apps), CADENCE_NO_OPEN='1')
        # Piped into sh, exactly as the site tells people to run it.
        text = installer.read_text()
        return subprocess.run(['sh'], input=text[:cut] if cut else text, env=env, capture_output=True, text=True, timeout=300)

    def quarantined(self, app):
        return subprocess.run(['xattr', '-p', 'com.apple.quarantine', str(app)], capture_output=True).returncode == 0

    def test_installs_without_the_quarantine_flag(self):
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stderr)
        app = self.apps / 'Cadence.app'
        self.assertTrue((app / 'Contents/MacOS/Cadence').exists())
        self.assertFalse(self.quarantined(app), 'Gatekeeper would still block the first open')
        self.assertIn('checksum verified', result.stdout)
        self.assertEqual((self.home / '.cadence/store.db').read_text(), 'your history')
        self.assertFalse((self.apps / '.Cadence.app.new').exists())

    def test_refuses_a_wrong_checksum_and_installs_nothing(self):
        result = self.run_installer(sha='0' * 64)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('checksum mismatch', result.stderr)
        self.assertFalse((self.apps / 'Cadence.app').exists())

    def test_updates_an_existing_cadence_in_place(self):
        make_app(self.apps / 'Cadence.app', version='0.0.1')
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('<string>9.9.9</string>', (self.apps / 'Cadence.app/Contents/Info.plist').read_text())

    def test_never_replaces_a_different_app_named_cadence(self):
        make_app(self.apps / 'Cadence.app', bundle_id='com.example.other')
        result = self.run_installer()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('different app', result.stderr)
        self.assertIn('com.example.other', (self.apps / 'Cadence.app/Contents/Info.plist').read_text())

    def test_a_download_cut_short_runs_nothing(self):
        script = (ROOT / 'site/install.sh').read_text()
        result = self.run_installer(cut=script.index('ditto "$src"'))  # stops mid-script
        self.assertNotIn('downloading', result.stdout)
        self.assertFalse((self.apps / 'Cadence.app').exists())

    def test_leaves_no_disk_image_mounted(self):
        self.run_installer()
        mounts = subprocess.run(['hdiutil', 'info'], capture_output=True, text=True).stdout
        self.assertNotIn(str(self.tmp), mounts)


if __name__ == '__main__':
    unittest.main()
