#!/usr/bin/env python3
"""State-bound consultation receipts used by fm-dispatch-resolve and launch consumers.

Usage: fm-model-route-receipt.py write|check --brief FILE --kind KIND
       [--config DIR] [--home DIR] [--selected JSON]
write reads a JSON decision envelope from stdin and prints the record path.
check verifies the selected harness/model/effort, brief and policy hashes and
receipt age (five minutes for dispatch; fixed policy records are reissued at
consumption). A receipt is evidence of consultation, never launch authority.
No input text, credentials, or quota account identities are persisted.
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
KINDS = ('dispatch', 'cross-review', 'secondmate', 'no-mistakes', 'static')
EXCEPTIONS = ('deterministic_policy', 'privacy_insufficient_payload', 'jev_unavailable', 'jev_escalation')
MAX_AGE = 300


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
    ap.add_argument('action', choices=('write', 'check', 'fingerprint'))
    ap.add_argument('--brief', required=True)
    ap.add_argument('--kind', choices=KINDS, default='dispatch')
    ap.add_argument('--home', default=os.environ.get('FM_HOME', str(Path(__file__).resolve().parent.parent)))
    ap.add_argument('--config')
    ap.add_argument('--selected')
    ap.add_argument('--expected-state-hash')
    ap.add_argument('--context-hash', default='')
    ap.add_argument('--policy-file', action='append', default=[])
    args = ap.parse_args()
    home = Path(args.home).resolve()
    config = Path(args.config or os.environ.get('FM_CONFIG_OVERRIDE') or home / 'config')
    brief = Path(args.brief).resolve(strict=True)
    path = home / 'state' / 'model-route' / (digest(encoded([str(brief), args.kind])) + '.json')
    safe(path)
    source_hashes = {str(Path(p).resolve()): digest(Path(p).read_bytes()) for p in args.policy_file}
    if args.context_hash and (len(args.context_hash) != 64 or any(c not in '0123456789abcdef' for c in args.context_hash)):
        raise ValueError('invalid launch context hash')
    fingerprint = digest(encoded({'brief': digest(brief.read_bytes()), 'policy': policy(config), 'sources': source_hashes,
                                  'launch_context': args.context_hash}))
    if args.action == 'fingerprint':
        print(fingerprint)
        return 0
    if args.expected_state_hash and args.expected_state_hash != fingerprint:
        raise ValueError('brief or model policy changed during consultation: resolve again')
    if args.action == 'write':
        envelope = json.load(sys.stdin)
        pick = selected(envelope['selected'])
        exception = envelope.get('exception')
        consultation = envelope.get('consultation')
        if exception is not None:
            if exception not in EXCEPTIONS or not envelope.get('reason'):
                raise ValueError('invalid or unexplained model-routing exception')
        elif not isinstance(consultation, dict) or not consultation.get('model') or not consultation.get('answer'):
            raise ValueError('model selection has no Jev consultation or typed exception')
        record = {'version': VERSION, 'kind': args.kind, 'created': time.time(),
                  'state_hash': fingerprint, 'options_hash': envelope.get('options_hash'),
                  'selected': pick, 'consultation': consultation, 'exception': exception,
                  'reason': envelope.get('reason'), 'source_hashes': source_hashes,
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
            # consultation, even though the latest consumption receipt is one
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
    if not args.selected:
        raise ValueError('check needs --selected')
    record = json.loads(path.read_bytes())
    if record.get('version') != VERSION or record.get('kind') != args.kind:
        raise ValueError('wrong model-routing receipt version or decision kind')
    age = time.time() - record['created']
    if age < 0 or age > MAX_AGE:
        raise ValueError('stale model-routing receipt: resolve again')
    if record.get('state_hash') != fingerprint:
        raise ValueError('brief or model policy changed: resolve again')
    if record.get('selected') != selected(json.loads(args.selected)):
        raise ValueError('launch profile differs from model-routing receipt')
    exception = record.get('exception')
    consultation = record.get('consultation')
    if exception not in EXCEPTIONS and not (isinstance(consultation, dict) and consultation.get('model') and consultation.get('answer')):
        raise ValueError('missing model-routing consultation or typed exception')
    if exception is not None and not record.get('reason'):
        raise ValueError('unexplained model-routing exception')
    print('model-route: receipt verified')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, TypeError) as exc:
        print(f'model-route: {exc}', file=sys.stderr)
        sys.exit(1)
