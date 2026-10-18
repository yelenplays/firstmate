#!/usr/bin/env bash
# Pre-commit token cap: refuse agent-authored staged files over 5,000 tokens.
# Wired as a tracked hook script at bin/fm-precommit-token-cap.sh, dispatched by
# the tracked .githooks/pre-commit wrapper that `git config core.hooksPath
# .githooks` installs (the one install step, documented in CONTRIBUTING.md).
#
# Usage:
#   fm-precommit-token-cap.sh
#       Pre-commit hook mode. Reads the staged diff from the index, never the
#       working tree, prints one message naming every failing file with its
#       size, token estimate and split instructions, then exits 1 to refuse
#       the commit; exits 0 when nothing fails.
#
# CAP RULE (owner: this header). Tokens = bytes/4 and the limit is 5000, so a
# staged file fails when its staged blob size is more than 20000 bytes,
# measured from the index with git cat-file -s, not from the working tree.
# A staged file that already exceeded the limit at HEAD fails only when its
# staged size is larger than its HEAD size - the ratchet: existing oversized
# files may stay the same or shrink, but never grow. New files and files
# crossing the limit fail. A rename or copy measures against the source
# path's HEAD size. Deleted files and staged deletions never fail.
#
# SKIPS, one obvious place to extend: fm_is_skipped below plus the
# LOCKFILE_BASENAMES list just before it. A staged file is skipped when it is
# binary by git's own rule (a NUL byte within the first 8000 bytes of the
# blob), a lockfile by basename, marked linguist-generated or
# linguist-vendored in .gitattributes, or its first 20 lines carry a standard
# generated marker (@generated, DO NOT EDIT).
set -u
unset CDPATH

LIMIT_BYTES=20000  # 5000 tokens at tokens = bytes/4

# Lockfiles and generated dependency manifests that agents never author.
LOCKFILE_BASENAMES=(
  package-lock.json
  npm-shrinkwrap.json
  packages-lock.json
  yarn.lock
  pnpm-lock.yaml
  bun.lock
  bun.lockb
  Cargo.lock
  uv.lock
  poetry.lock
  Gemfile.lock
  go.sum
  composer.lock
  mix.lock
  flake.lock
)

fm_path_is_lockfile() { # <path>
  local base=${1##*/}
  local name
  for name in "${LOCKFILE_BASENAMES[@]}"; do
    [ "$base" = "$name" ] && return 0
  done
  return 1
}

fm_path_is_linguist_skipped() { # <path>
  local path attribute value
  while IFS= read -r -d '' path &&
    IFS= read -r -d '' attribute &&
    IFS= read -r -d '' value; do
    [ "$value" = set ] && return 0
  done < <(git check-attr --cached -z linguist-generated linguist-vendored -- "$1")
  return 1
}

fm_blob_is_binary() { # <blob>
  # git's own binary rule: a NUL byte within the first 8000 bytes.
  git cat-file blob "$1" | head -c 8000 | od -An -tx1 | grep -q ' 00'
}

fm_blob_is_generated() { # <blob>
  git cat-file blob "$1" | head -n 20 | grep -qE '@generated|^[[:space:]]*(#|//|/\*|\*|;|--|<!--)[[:space:]]*(DO NOT EDIT|Code generated .*DO NOT EDIT)'
}

fm_is_skipped() { # <path> <blob>
  fm_path_is_lockfile "$1" && return 0
  fm_path_is_linguist_skipped "$1" && return 0
  fm_blob_is_binary "$2" && return 0
  fm_blob_is_generated "$2" && return 0
  return 1
}

main() {
  local top
  top=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
  cd "$top" || exit 1

  local -a fail_paths=() fail_sizes=() fail_notes=()

  local meta fields status letter blob path dst_path head_path size head_size note
  while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
    IFS=' ' read -r -a fields <<<"${meta#:}"
    status=${fields[4]}
    letter=${status:0:1}
    blob=${fields[3]}
    head_path=$path
    if [ "$letter" = R ] || [ "$letter" = C ]; then
      if ! IFS= read -r -d '' dst_path; then
        break
      fi
      path=$dst_path
    fi
    case "$letter" in
    D) continue ;;
    esac
    [ -n "$blob" ] || continue
    if ! size=$(git cat-file -s "$blob" 2>/dev/null); then
      continue
    fi
    [ "$size" -gt "$LIMIT_BYTES" ] || continue
    if fm_is_skipped "$path" "$blob"; then
      continue
    fi
    head_size=$(git cat-file -s "HEAD:$head_path" 2>/dev/null) || head_size=''
    if [ -n "$head_size" ] && [ "$head_size" -gt "$LIMIT_BYTES" ] && [ "$size" -le "$head_size" ]; then
      continue
    fi
    if [ -n "$head_size" ]; then
      note=$(printf ' (grew from %s bytes = %s tokens at HEAD)' "$head_size" $((head_size / 4)))
    else
      note=''
    fi
    fail_paths+=("$path")
    fail_sizes+=("$size")
    fail_notes+=("$note")
  done < <(git diff --cached --find-renames --raw --no-ext-diff -z)

  if [ "${#fail_paths[@]}" -eq 0 ]; then
    exit 0
  fi
  {
    printf 'precommit-token-cap: %d staged file(s) exceed the %d-token limit (tokens = bytes/4)\n\n' \
      "${#fail_paths[@]}" $((LIMIT_BYTES / 4))
    local i
    for ((i = 0; i < ${#fail_paths[@]}; i++)); do
      printf '  %s: %s bytes = %d tokens (limit %d)%s\n' \
        "${fail_paths[i]}" "${fail_sizes[i]}" $(( (fail_sizes[i] + 3) / 4 )) "$((LIMIT_BYTES / 4))" "${fail_notes[i]}"
    done
    cat <<'TEXT'

How to split:
  1. Split along existing responsibility boundaries - one concern per file.
  2. Move helpers or sections into sibling files with the same naming convention.
  3. Keep a thin entry point that sources or imports them, then update references and tests.
  4. For documentation, split by heading into linked pages.

An already-oversized existing file only has to stop growing: staging it at the same size or smaller passes, and splitting or shrinking it still helps.
TEXT
  } >&2
  exit 1
}

main
