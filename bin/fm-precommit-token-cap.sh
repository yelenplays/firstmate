#!/usr/bin/env bash
# Pre-commit token cap for staged files, dispatched by .githooks/pre-commit.
# CONTRIBUTING.md's "Git hooks" section owns installation.
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
# crossing the limit fail. A Git-detected rename measures against the source
# path's HEAD size. Staged deletions never fail.
#
# SKIPS, one obvious place to extend: fm_is_skipped below plus the
# LOCKFILE_BASENAMES list just before it. Authorship is not detected: these
# exemptions approximate non-agent-authored content; all other staged files
# are subject to the cap, including human-authored files.
# A staged file is skipped when it is binary, a lockfile by basename, or
# its linguist-generated or linguist-vendored attributes are reported by
# git check-attr --cached as set, true, TRUE, or True; false does not
# exempt a file.
# Binary classification mirrors git's own diff machinery and reads the diff
# attribute through git check-attr --cached only, so unstaged gitattributes
# can neither exempt nor reclassify a staged file: a diff attribute value of
# unset is binary, including -diff and the binary macro; set forces text
# even when the blob carries a NUL byte; for a named diff driver the diff
# <driver>.binary config boolean decides (read with git config --bool --get,
# since driver settings live in config, never in gitattributes) with true
# marking the blob binary and false forcing text; every other case - no
# matching diff attribute, an unknown driver, a driver without its boolean
# set, and a blob the attribute logic does not decide outright - falls back
# to the content heuristic: binary when a NUL occurs within the first 8000
# bytes.
# Generated markers are case-sensitive and must occur in the first 20 lines:
# a comment beginning @generated, DO NOT EDIT or Code generated
# ...DO NOT EDIT after one of #, //, /*, *, ;, --, or <!-- and optional whitespace.
# Incidental "do not edit" prose elsewhere does not qualify.
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
  local _ value
  while IFS= read -r -d '' _ &&
    IFS= read -r -d '' _ &&
    IFS= read -r -d '' value; do
    case "$value" in
    set | true | TRUE | True) return 0 ;;
    esac
  done < <(git check-attr --cached -z linguist-generated linguist-vendored -- "$1")
  return 1
}

fm_blob_is_binary() { # <path> <blob>: mirror git's own diff binary classification.
  local _ value
  while IFS= read -r -d '' _ &&
    IFS= read -r -d '' _ &&
    IFS= read -r -d '' value; do
    :
  done < <(git check-attr --cached -z diff -- "$1")
  case "$value" in
  unset) return 0 ;;
  set) return 1 ;;
  unspecified) ;;
  *)
    case "$(git config --bool --get "diff.$value.binary" 2>/dev/null)" in
    true) return 0 ;;
    false) return 1 ;;
    esac
    ;;
  esac
  git cat-file blob "$2" | head -c 8000 | od -An -tx1 | grep -q ' 00'
}

fm_blob_is_generated() { # <blob>
  git cat-file blob "$1" | head -n 20 | grep -qE '^[[:space:]]*(#|//|/\*|\*|;|--|<!--)[[:space:]]*(@generated|DO NOT EDIT|Code generated .*DO NOT EDIT)'
}

fm_is_skipped() { # <path> <blob>
  fm_path_is_lockfile "$1" && return 0
  fm_path_is_linguist_skipped "$1" && return 0
  fm_blob_is_binary "$1" "$2" && return 0
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
