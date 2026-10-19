"""Drive the shipped pre-commit hook through real Git commits; no mocked commands."""
import os
from pathlib import Path
import shutil
import subprocess
import sys

root = Path.cwd()
base = root / '.token-cap-validation' / 'manual'
base.mkdir(parents=True, exist_ok=True)
env = dict(os.environ)
for key in list(env):
    if key.startswith('GIT_'):
        env.pop(key)
env.update(GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1',
           GIT_AUTHOR_NAME='Token Cap Validation', GIT_AUTHOR_EMAIL='test@example.invalid',
           GIT_COMMITTER_NAME='Token Cap Validation', GIT_COMMITTER_EMAIL='test@example.invalid')

def git(repo, *args, expected=0):
    p = subprocess.run(['git', '-C', str(repo), *args], env=env,
                       text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    print('$ git', *[repr(a) for a in args])
    if p.stdout:
        print(p.stdout, end='' if p.stdout.endswith('\n') else '\n')
    print(f'[exit {p.returncode}]')
    assert p.returncode == expected, (args, p.returncode, expected)
    return p.stdout

def repo(name):
    path = base / name
    path.mkdir()
    git(path, 'init', '-q', '-b', 'main')
    for rel in ['bin/fm-precommit-token-cap.sh', '.githooks/pre-commit']:
        dest = path / rel
        dest.parent.mkdir(exist_ok=True)
        shutil.copy2(root / rel, dest)
    git(path, 'config', 'core.hooksPath', '.githooks')
    return path

def stage(repo, *names):
    git(repo, 'add', '--', *names)

def commit(repo, message, refused=False):
    old = subprocess.run(['git', '-C', str(repo), 'rev-parse', '--verify', 'HEAD'],
                         env=env, capture_output=True, text=True)
    output = git(repo, 'commit', '-m', message, expected=1 if refused else 0)
    new = subprocess.run(['git', '-C', str(repo), 'rev-parse', '--verify', 'HEAD'],
                         env=env, capture_output=True, text=True)
    if refused:
        assert old.stdout == new.stdout and old.returncode == new.returncode
        assert 'precommit-token-cap:' in output
        print('[HEAD unchanged after refusal]')
    else:
        assert old.stdout != new.stdout
        print('[HEAD advanced]')
    return output

def put(repo, name, data):
    path = repo / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)

print('SCENARIO: Exact byte boundary on an initial commit; refusal gives actionable split instructions; splitting succeeds')
r = repo('boundary')
put(r, 'exact.txt', b'a' * 20000)
stage(r, 'exact.txt')
commit(r, 'Accept exactly 5000 tokens on initial commit')
put(r, 'new.txt', b'b' * 20001)
stage(r, 'new.txt')
out = commit(r, 'Refuse one byte above 5000 tokens', refused=True)
assert 'new.txt: 20001 bytes = 5001 tokens (limit 5000)' in out
assert all(s in out for s in ['1. Split along existing responsibility boundaries',
    '2. Move helpers or sections into sibling files', '3. Keep a thin entry point',
    '4. For documentation, split by heading'])
git(r, 'rm', '--cached', '--', 'new.txt')
(r / 'new.txt').unlink()
put(r, 'split-one.txt', b'b' * 10000)
put(r, 'split-two.txt', b'b' * 10001)
stage(r, 'split-one.txt', 'split-two.txt')
commit(r, 'Split oversized file into sibling files')
print('RESULT: pass\n')

print('SCENARIO: Only staged bytes count in both directions, including multibyte text')
put(r, 'not-staged.txt', b'z' * 35000)
put(r, 'split-one.txt', b'x' * 26000)  # tracked but unstaged
put(r, 'partial.txt', b's' * 1000)
stage(r, 'partial.txt')
put(r, 'partial.txt', b'q' * 24000)  # staged version remains small
commit(r, 'Ignore oversized untracked and unstaged bytes')
assert git(r, 'cat-file', '-s', 'HEAD:partial.txt').strip() == '1000'
put(r, 'partial.txt', ('é' * 10000 + 'x').encode('utf-8'))
stage(r, 'partial.txt')
put(r, 'partial.txt', b'now small in worktree')
out = commit(r, 'Refuse staged 20001 bytes despite small worktree', refused=True)
assert 'partial.txt: 20001 bytes = 5001 tokens' in out
git(r, 'reset', '-q', 'HEAD', '--', 'partial.txt')
print('RESULT: pass\n')

print('SCENARIO: A legacy 357 KB file can be edited without growing or shrunk, but one-byte growth is rejected; deletion succeeds')
r = repo('legacy')
put(r, 'bin/legacy.sh', b'a' * 357000)
stage(r, 'bin/legacy.sh')
git(r, 'commit', '--no-verify', '-m', 'Seed pre-existing oversized file')
put(r, 'bin/legacy.sh', b'b' * 357000)
stage(r, 'bin/legacy.sh')
commit(r, 'Allow same-size edit of legacy file')
put(r, 'bin/legacy.sh', b'c' * 356999)
stage(r, 'bin/legacy.sh')
commit(r, 'Allow shrink of legacy file')
put(r, 'bin/legacy.sh', b'c' * 357000)
stage(r, 'bin/legacy.sh')
out = commit(r, 'Reject one-byte growth of legacy file', refused=True)
assert 'grew from 356999 bytes' in out
git(r, 'rm', '-f', '--', 'bin/legacy.sh')
commit(r, 'Allow deletion of legacy file')
print('RESULT: pass\n')

print('SCENARIO: Rename plus growth in the same commit is rejected against the original path; a shrinking rename succeeds')
r = repo('rename')
original = (b'x' * 79 + b'\n') * 312
put(r, 'old.txt', original)
stage(r, 'old.txt')
git(r, 'commit', '--no-verify', '-m', 'Seed existing oversized source')
git(r, 'mv', '--', 'old.txt', 'renamed.txt')
put(r, 'renamed.txt', original + b'y' * 80)
stage(r, 'renamed.txt')
raw = git(r, 'diff', '--cached', '--find-renames', '--name-status')
assert raw.startswith('R'), raw
out = commit(r, 'Reject simultaneous rename and growth', refused=True)
assert 'renamed.txt: 25040 bytes' in out and 'grew from 24960 bytes' in out
put(r, 'renamed.txt', original[:-80])
stage(r, 'renamed.txt')
commit(r, 'Allow simultaneous rename and shrink')
print('RESULT: pass\n')

print('SCENARIO: Real dependency/codegen/binary artifacts are exempt, but an incidental do-not-edit sentence cannot bypass the cap')
r = repo('exemptions')
put(r, 'package-lock.json', b'l' * 30000)
put(r, 'generated.py', b'# DO NOT EDIT\n' + b'g' * 30000)
put(r, 'generated.c', b'// Code generated by tool. DO NOT EDIT.\n' + b'g' * 30000)
put(r, 'opaque.bin', b'\x00' * 30000)
put(r, 'schema.gen', b'g' * 30000)
put(r, '.gitattributes', b'*.gen linguist-generated=true\n')
stage(r, 'package-lock.json', 'generated.py', 'generated.c', 'opaque.bin', 'schema.gen', '.gitattributes')
commit(r, 'Accept large non-authored artifacts')
put(r, 'authored.py', b'# When updating, do not edit the table below.\n' + b'a' * 21000)
stage(r, 'authored.py')
put(r, 'authored.py', b'# DO NOT EDIT\n' + b'a' * 21000)  # unstaged forged header
put(r, '.gitattributes', b'*.py linguist-generated\n*.py -diff\n')  # unstaged forged exemption
out = commit(r, 'Refuse incidental prose and unstaged exemptions', refused=True)
assert 'authored.py: {} bytes'.format(len(b'# When updating, do not edit the table below.\n') + 21000) in out
print('RESULT: pass\n')

print('SCENARIO: Multiple failures with space/newline paths are all refused and reported')
r = repo('paths')
put(r, 'small.txt', b'')
stage(r, 'small.txt')
commit(r, 'Seed path handling repository')
names = ['space name.txt', 'line\nbreak.txt', '-leading.txt']
for name in names:
    put(r, name, b'a' * 21000)
stage(r, *names)
out = commit(r, 'Refuse every oversized unusual path', refused=True)
assert '3 staged file(s)' in out
assert all(name + ': 21000 bytes' in out for name in names)
print('RESULT: pass\n')
print('All manual scenarios passed.')
