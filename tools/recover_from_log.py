#!/usr/bin/env python3
"""Rebuild per-day dictation totals from ~/.cadence/logs/cadence.log.

For history that can no longer be read (a store whose key was lost). The log never held
transcript text, so this recovers what it can honestly: how many dictations landed each day
and how long you spoke. Word counts are estimated later, by the reader, and labelled so.

    python3 tools/recover_from_log.py            # writes ~/.cadence/recovered.json
    python3 tools/recover_from_log.py --dry-run  # print instead

Only dictations before the first "store open failed" / "store: no key opens" line count: anything after that is in
the new store, and counting it here would double it.
"""
import datetime as dt
import json
import os
import re
import sys
import tempfile
from pathlib import Path

LINE = re.compile(r'^(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2})(?:\.\d+)? (.*)$')
CAPTURE = re.compile(r'^capture window (\d+) ms')
INSERTED = re.compile(r'^insertion: \S+ inserted=(true|false)')


def recover(lines, cutoff=None):
    """lines -> (days, cutoff). A dictation = a capture window whose next insertion landed."""
    days, pending = {}, None
    for raw in lines:
        m = LINE.match(raw.rstrip('\n'))
        if not m:
            continue
        date, time, msg = m.groups()
        stamp = f'{date}T{time}'
        if cutoff is None and (msg.startswith('store open failed') or msg.startswith('store: no key opens')):
            cutoff = stamp
        if cutoff is not None and stamp >= cutoff:
            break
        c = CAPTURE.match(msg)
        if c:
            pending = int(c.group(1))
            continue
        i = INSERTED.match(msg)
        if i and pending is not None:
            if i.group(1) == 'true':
                d = days.setdefault(date, {'date': date, 'dictations': 0, 'speech_sec': 0.0})
                d['dictations'] += 1
                d['speech_sec'] = round(d['speech_sec'] + pending / 1000, 1)
            pending = None
    return sorted(days.values(), key=lambda d: d['date']), cutoff


def main(argv, home=Path.home()):
    log = home / '.cadence/logs/cadence.log'
    if not log.is_file():
        print(f'no log at {log}', file=sys.stderr)
        return 1
    with log.open(encoding='utf-8', errors='replace') as f:
        days, cutoff = recover(f)
    if cutoff is None:
        # Nothing was lost (or the failure was trimmed out of the log): everything logged is
        # still in the store, and recovering it would double every total.
        print('no lost-store line in the log; nothing to recover', file=sys.stderr)
        return 1
    body = {'schema': 1, 'source': 'cadence.log', 'cutoff': cutoff,
            'generated_at': dt.datetime.now().isoformat(timespec='seconds'),
            'note': 'Dictation counts and speaking time from the log; text was not recoverable.',
            'days': days}
    text = json.dumps(body, indent=2)
    if '--dry-run' in argv:
        print(text)
        return 0
    target = home / '.cadence/recovered.json'
    fd, tmp = tempfile.mkstemp(dir=target.parent)
    try:
        with os.fdopen(fd, 'w') as f:
            f.write(text)
        os.replace(tmp, target)
    except BaseException:
        os.unlink(tmp)
        raise
    n = sum(d['dictations'] for d in days)
    mins = sum(d['speech_sec'] for d in days) / 60
    print(f'{target}: {n} dictations, {mins:.0f} min spoken, {len(days)} days (before {cutoff})')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
