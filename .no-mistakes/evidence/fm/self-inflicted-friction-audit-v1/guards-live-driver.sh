#!/usr/bin/env bash
set -eu
ROOT=$PWD
unset FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
LAB=$(mktemp -d "$ROOT/.phase-test-tmp/fm-lab.guards.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
bin/fm-lab-home.sh create "$LAB" >/dev/null
export FM_HOME="$LAB"
printf 'ARM GUARD: public PreToolUse interface and actual read-only shell execution\n'
for cmd in 'git cat-file -s HEAD:bin/fm-watch.sh' 'wc -l bin/fm-watch.sh' 'grep -c "^#" bin/fm-watch.sh' 'cat bin/fm-watch.sh >/dev/null' 'for f in bin/fm-watch.sh; do git cat-file -s HEAD:$f; wc -l "$f"; done'; do
 printf '\nCOMMAND: %s\n' "$cmd"
 bin/fm-arm-pretool-check.sh --command "$cmd"
 bash -c "$cmd"
 printf 'allow + executed read-only command: PASS\n'
done
for cmd in 'bin/fm-watch.sh' 'for f in bin/fm-watch.sh; do "$f"; done' 'pkill -f bin/fm-watch.sh' 'for f in bin/fm-watch.sh; do wc -l "$f"; bash "$f"; done'; do
 printf '\nATTEMPT: %s\n' "$cmd"
 rc=0; bin/fm-arm-pretool-check.sh --command "$cmd" > "$LAB/out" 2> "$LAB/err" || rc=$?
 printf 'exit=%s\n' "$rc"; python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).read_text())' "$LAB/err"
 [ "$rc" = 2 ]
 printf 'denied before execution: PASS\n'
done
PRIMARY="$LAB/primary"
mkdir -p "$PRIMARY/bin" "$PRIMARY/project"
git init -q "$PRIMARY"
printf '# Disposable Firstmate primary\n' > "$PRIMARY/AGENTS.md"
for f in fm-cd-pretool-check.sh fm-hook-host-lib.sh fm-cd-command-policy.mjs fm-arm-command-policy.mjs; do cp "$ROOT/bin/$f" "$PRIMARY/bin/$f"; done
ln -s "$PRIMARY" "$LAB/home-alias"
export FM_ROOT_OVERRIDE="$PRIMARY"
printf '\nCD GUARD: real standalone Git primary with copied production executables\n'
for target in "$PRIMARY" "$PRIMARY/bin/.." "$LAB/home-alias"; do
 cmd="cd '$target'"
 printf '\nCOMMAND: %s\n' "$cmd"
 "$PRIMARY/bin/fm-cd-pretool-check.sh" --command "$cmd"
 actual=$(cd "$PRIMARY/project"; eval "$cmd"; pwd -P)
 printf 'cwd after allowed cd: %s\n' "$actual"
 [ "$actual" = "$PRIMARY" ]
done
for cmd in "cd '$PRIMARY/project'" "cd '$PRIMARY'; cd project" "pushd '$PRIMARY'" 'cd "$FM_HOME"'; do
 printf '\nATTEMPT: %s\n' "$cmd"
 rc=0; "$PRIMARY/bin/fm-cd-pretool-check.sh" --command "$cmd" > "$LAB/out" 2> "$LAB/err" || rc=$?
 printf 'exit=%s\n' "$rc"; python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).read_text())' "$LAB/err"
 [ "$rc" = 2 ]
 printf 'denied before cwd mutation: PASS\n'
done
