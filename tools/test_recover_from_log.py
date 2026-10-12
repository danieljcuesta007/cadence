import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('recover', Path(__file__).with_name('recover_from_log.py'))
recover = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recover)

LOG = """\
2026-07-16 09:08:25.000 core ready in 1007 ms
2026-07-16 09:10:00.100 ptt down: Right-Option → en
2026-07-16 09:10:09.300 capture window 9300 ms
2026-07-16 09:10:09.900 insertion: paste_restore inserted=true verify=verified clipboardRestored=true 91 ms
2026-07-16 09:12:00.000 capture window 4000 ms
2026-07-16 09:12:01.000 insertion: clipboard_notify inserted=false verify=contradicted clipboardRestored=false
2026-07-17 23:59:50.000 capture window 700 ms
2026-07-17 23:59:51.000 insertion: direct inserted=true clipboardRestored=true
2026-07-18 08:00:00.000 insertion: paste_restore inserted=true verify=verified clipboardRestored=true
2026-10-11 17:32:22.530 capture window 31182 ms
2026-10-11 17:32:23.963 insertion: paste_restore inserted=true verify=verified clipboardRestored=true 64 ms
2026-10-11 19:32:10.961 store open failed — staying on JSONL: wrong key
2026-10-11 20:00:00.000 capture window 5000 ms
2026-10-11 20:00:01.000 insertion: paste_restore inserted=true verify=verified clipboardRestored=true
"""


class RecoverTests(unittest.TestCase):
    def test_counts_only_landed_dictations_per_local_day(self):
        days, _ = recover.recover(LOG.splitlines())
        self.assertEqual([(d['date'], d['dictations'], d['speech_sec']) for d in days],
                         [('2026-07-16', 1, 9.3), ('2026-07-17', 1, 0.7), ('2026-10-11', 1, 31.2)])

    def test_stops_at_the_store_failure_so_the_new_store_is_not_double_counted(self):
        _, cutoff = recover.recover(LOG.splitlines())
        self.assertEqual(cutoff, '2026-10-11T19:32:10')

    def test_insertion_without_a_capture_is_ignored(self):
        days, _ = recover.recover(LOG.splitlines())
        self.assertNotIn('2026-07-18', [d['date'] for d in days])

    def test_writes_file_with_no_text(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            (home / '.cadence/logs').mkdir(parents=True)
            (home / '.cadence/logs/cadence.log').write_text(LOG)
            self.assertEqual(recover.main([], home=home), 0)
            body = json.loads((home / '.cadence/recovered.json').read_text())
            self.assertEqual(sum(d['dictations'] for d in body['days']), 3)
            self.assertNotIn('text', json.dumps(body['days']))

    def test_reset_line_is_also_a_cutoff(self):
        log = LOG.replace('store open failed — staying on JSONL: wrong key',
                          'store: no key opens store.db (wrong key); kept it as store.locked-x.db')
        _, cutoff = recover.recover(log.splitlines())
        self.assertEqual(cutoff, '2026-10-11T19:32:10')

    def test_healthy_log_writes_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            (home / '.cadence/logs').mkdir(parents=True)
            (home / '.cadence/logs/cadence.log').write_text(LOG.split('2026-10-11 19:32')[0])
            self.assertEqual(recover.main([], home=home), 1)
            self.assertFalse((home / '.cadence/recovered.json').exists())

    def test_missing_log_is_an_error_not_a_crash(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(recover.main([], home=Path(tmp)), 1)


if __name__ == '__main__':
    unittest.main()
