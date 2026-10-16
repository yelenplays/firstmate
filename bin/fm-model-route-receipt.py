#!/usr/bin/env python3
"""Optional state-bound consultation records used by fm-dispatch-resolve.

Usage: fm-model-route-receipt.py write|fingerprint --brief FILE --kind KIND
       [--config DIR] [--home DIR] [--expected-state-hash HASH]
write reads a JSON decision envelope from stdin and prints the record path.
fingerprint prints the brief and model-policy hash a record binds.
A record is evidence of consultation, never launch authority.
No brief bodies, credentials, or quota account identities are persisted.
An explicit captain-override reason is intentionally recorded.
selected_rule names the rule whose profile was selected - after a runoff, the
runoff winner, not the first-pass answer kept in consultation - or null for a
fixed-policy record.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import time

VERSION = 1
KINDS = ('dispatch', 'cross-review', 'secondmate')
EXCEPTIONS = ('deterministic_policy', 'privacy_insufficient_payload', 'jev_unavailable', 'jev_escalation')


def digest(value):
    return hashlib.sha256(value).hexdigest()


def encoded(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':')).encode()


def safe(path):
    if any(p.is_symlink() for p in (path, *path.parents)):
        raise ValueError(f'unsafe receipt path: {path}')


def policy(config):
    facts = {}
    for name in ('crew-dispatch.json', 'model-denylist.json', 'dispatch-never-send',
                 'crew-harness', 'secondmate-harness', 'claude-account', 'pi-account'):
        p = config / name
        facts[name] = digest(p.read_bytes()) if p.exists() else None
    pin_dir = config / 'secondmate-harness.d'
    if pin_dir.is_dir():
        for p in sorted(pin_dir.iterdir()):
            if p.is_file():
                facts['secondmate-harness.d/' + p.name] = digest(p.read_bytes())
    return digest(encoded(facts))


def selected(value):
    if not isinstance(value, dict):
        raise ValueError('selected profile must be an object')
    result = {k: value.get(k) or '' for k in ('harness', 'model', 'effort')}
    if not result['harness'] or not all(isinstance(v, str) for v in result.values()):
        raise ValueError('selected profile needs a harness and string fields')
    return result


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('action', choices=('write', 'fingerprint'))
    ap.add_argument('--brief', required=True)
    ap.add_argument('--kind', choices=KINDS, default='dispatch')
    ap.add_argument('--home', default=os.environ.get('FM_HOME', str(Path(__file__).resolve().parent.parent)))
    ap.add_argument('--config')
    ap.add_argument('--expected-state-hash')
    args = ap.parse_args()
    home = Path(args.home).resolve()
    config = Path(args.config or os.environ.get('FM_CONFIG_OVERRIDE') or home / 'config')
    brief = Path(args.brief).resolve(strict=True)
    path = home / 'state' / 'model-route' / (digest(encoded([str(brief), args.kind])) + '.json')
    safe(path)
    fingerprint = digest(encoded({'brief': digest(brief.read_bytes()), 'policy': policy(config)}))
    if args.action == 'fingerprint':
        print(fingerprint)
        return 0
    if args.expected_state_hash and args.expected_state_hash != fingerprint:
        raise ValueError('brief or model policy changed during consultation: resolve again')
    envelope = json.load(sys.stdin)
    pick = selected(envelope['selected'])
    exception = envelope.get('exception')
    selected_rule = envelope.get('selected_rule')
    if selected_rule is not None and (not isinstance(selected_rule, str) or not selected_rule):
        raise ValueError('selected rule must be a non-empty string or null')
    consultation = envelope.get('consultation')
    if exception is not None:
        if exception not in EXCEPTIONS or not envelope.get('reason'):
            raise ValueError('invalid or unexplained model-routing exception')
    elif not isinstance(consultation, dict) or not consultation.get('model') or not consultation.get('answer'):
        raise ValueError('model selection has no Jev consultation or typed exception')
    record = {'version': VERSION, 'kind': args.kind, 'created': time.time(),
              'state_hash': fingerprint, 'options_hash': envelope.get('options_hash'),
              'selected': pick, 'selected_rule': selected_rule, 'consultation': consultation, 'exception': exception,
              'reason': envelope.get('reason'), 'captain_override': envelope.get('captain_override', False),
              'outcome': envelope.get('outcome', 'selected')}
    if not isinstance(record['options_hash'], str) or len(record['options_hash']) != 64:
        raise ValueError('model selection has no options hash')
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix='.receipt-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(record, stream, sort_keys=True)
            stream.write('\n')
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
        # Native policy chains may select more than one agent. Keep each
        # consultation, even though the latest record is one
        # stable path per instruction set and decision kind.
        journal = path.parent / 'decisions.jsonl'
        safe(journal)
        flags = os.O_WRONLY | os.O_CREAT | os.O_APPEND | getattr(os, 'O_NOFOLLOW', 0)
        with os.fdopen(os.open(journal, flags, 0o600), 'a') as stream:
            fcntl.flock(stream, fcntl.LOCK_EX)
            stream.write(json.dumps(record, sort_keys=True) + '\n')
            stream.flush()
            os.fsync(stream.fileno())
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)
    print(path)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, TypeError) as exc:
        print(f'model-route: {exc}', file=sys.stderr)
        sys.exit(1)
