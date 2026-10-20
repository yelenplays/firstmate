#!/usr/bin/env bash
# Exercise the public arm guard before executing expansion side effects in a
# disposable directory: an argument expansion that assigns must not let the
# compound read-only exception run a watcher-named script.
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-arm-pretool-check.sh"
LAB=$(mktemp -d "$ROOT/.fm-arm-expansion.XXXXXX")
trap 'rm -rf "$LAB"' EXIT

cd "$LAB"
mkdir bin
# The marker path is absolute and written with builtins only, so the fixture
# still records its execution after an attack has replaced PATH.
cat > bin/fm-watch.sh <<SH
#!/bin/sh
: > "$LAB/bin/executed"
SH
chmod +x bin/fm-watch.sh
watch="$LAB/bin/fm-watch.sh"

# Assigning BASH_CMDS repoints the next literal `cat` at the watcher script.
# shellcheck disable=SC2016 # Command fixtures intentionally preserve literal expansions.
attack='for f in '"$watch"'; do echo "${BASH_CMDS[cat]:=$f}"; cat; done'

# Prove the expansion really executes the script without the guard.
bash -c "$attack" >/dev/null 2>&1 </dev/null || :
[ -f bin/executed ] || fail 'expansion fixture did not execute the watcher-named script'
rm bin/executed

# shellcheck disable=SC2016 # Command fixtures intentionally preserve literal expansions.
for command in \
  "$attack" \
  'for f in '"$watch"'; do : "${BASH_CMDS[cat]=$f}"; cat; done' \
  'for f in '"$watch"'; do echo "${x:=$f}" "$((BASH_CMDS[cat]=1))"; cat; done' \
  'for BASH_CMDS in '"$watch"'; do cat; done' \
  'while read -r BASH_ALIASES; do cat; done < '"$watch"; do
  rc=0
  "$CHECK" --command "$command" > guard.out 2> guard.err || rc=$?
  if [ "$rc" -eq 0 ]; then
    bash -c "$command" >/dev/null 2>&1 </dev/null || :
  fi
  [ ! -e bin/executed ] || fail "guard allowed an expansion to execute the watcher: $command"
  [ "$rc" -eq 2 ] || fail "side-effecting expansion must be denied, got exit $rc: $command"
done
pass 'assigning expansions cannot execute a watcher through the compound read-only exception'

# printf assigns variables too: %n writes the variable it names, so
# `printf '%n' PATH` sets PATH=0 and the next literal `cat` resolves to 0/cat.
mkdir 0
ln -s ../bin/fm-watch.sh 0/cat
# shellcheck disable=SC2016 # Command fixtures intentionally preserve literal formats.
printf_attack='for f in '"$watch"'; do cd '"$LAB"'; printf '"'"'%n'"'"' PATH; cat; done'

# Prove the %n assignment really executes the script without the guard.
/bin/bash -c "$printf_attack" >/dev/null 2>&1 </dev/null || :
[ -f bin/executed ] || fail 'printf %n fixture did not execute the watcher-named script'
rm bin/executed

# shellcheck disable=SC2016 # Command fixtures intentionally preserve literal formats.
for command in \
  "$printf_attack" \
  'for f in '"$watch"'; do cd '"$LAB"'; fmt=%n; printf "$fmt" PATH; cat; done' \
  'for f in '"$watch"'; do cd '"$LAB"'; printf -v PATH 0; cat; done'; do
  rc=0
  "$CHECK" --command "$command" > guard.out 2> guard.err || rc=$?
  if [ "$rc" -eq 0 ]; then
    /bin/bash -c "$command" >/dev/null 2>&1 </dev/null || :
  fi
  [ ! -e bin/executed ] || fail "guard allowed printf to execute the watcher: $command"
  [ "$rc" -eq 2 ] || fail "variable-writing printf must be denied, got exit $rc: $command"
done
pass 'printf cannot assign a variable to execute a watcher through the compound read-only exception'

# Plain parameter references still read watcher paths as data.
# shellcheck disable=SC2016 # Command fixtures intentionally preserve literal expansions.
command='for f in '"$watch"'; do wc -c < "$f"; echo "${f}" "$f"; done'
"$CHECK" --command "$command"
bash -c "$command" >/dev/null
[ ! -e bin/executed ] || fail 'plain parameter reads executed the watcher'
pass 'plain parameter references stay inside the compound read-only exception'
