#!/usr/bin/env bash
# Exercise the public arm guard before executing Git in a disposable repository.
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-arm-pretool-check.sh"
LAB=$(mktemp -d "$ROOT/.fm-arm-git.XXXXXX")
trap 'rm -rf "$LAB"' EXIT

git init -q "$LAB"
cd "$LAB"
mkdir bin
printf 'before\n' > before
printf 'after\n' > after
cat > bin/fm-watch.sh <<'SH'
#!/bin/sh
: > "$(dirname "$0")/executed"
SH
chmod +x bin/fm-watch.sh
git config diff.external "$LAB/bin/fm-watch.sh"

# Prove the configured external program really runs without the guard.
git diff --no-index --ext-diff before after >/dev/null || :
[ -f bin/executed ] || fail 'external diff fixture did not execute'
rm bin/executed

command='for f in bin/fm-watch.sh; do git diff --no-index --ext-diff before after; done'
rc=0
"$CHECK" --command "$command" > guard.out 2> guard.err || rc=$?
if [ "$rc" -eq 0 ]; then
  bash -c "$command" >/dev/null || :
fi
[ ! -e bin/executed ] || fail 'guard allowed Git to execute the watcher-named external diff'
[ "$rc" -eq 2 ] || fail "external diff must be denied, got exit $rc"
pass 'compound external diff cannot execute through the arm guard'

# Git operations with execution-capable modes do not belong to the compound
# read-only exception, including cat-file text conversion and filters.
# shellcheck disable=SC2016 # Command fixtures intentionally preserve literal $f.
for command in \
  'for f in bin/fm-watch.sh; do git diff before after; done' \
  'for f in bin/fm-watch.sh; do git log; done' \
  'for f in bin/fm-watch.sh; do git show; done' \
  'for f in bin/fm-watch.sh; do git status; done' \
  'for f in bin/fm-watch.sh; do git cat-file --textconv HEAD:$f; done' \
  'for f in bin/fm-watch.sh; do git cat-file --filters HEAD:$f; done'; do
  rc=0
  "$CHECK" --command "$command" > guard.out 2> guard.err || rc=$?
  [ "$rc" -eq 2 ] || fail "execution-capable Git mode must be denied: $command"
done
pass 'execution-capable Git modes stay outside the compound exception'

# The required object-size probe still reads watcher paths as data.
git add bin/fm-watch.sh
object=$(git write-tree)
command="for f in bin/fm-watch.sh; do git cat-file -s $object:\$f; done"
"$CHECK" --command "$command"
actual=$(bash -c "$command")
expected=$(wc -c < bin/fm-watch.sh | tr -d ' ')
[ "$actual" = "$expected" ] || fail 'allowed Git object-size probe returned the wrong size'
[ ! -e bin/executed ] || fail 'object-size probe executed the watcher'
pass 'compound cat-file size probe reads watcher data without executing it'
