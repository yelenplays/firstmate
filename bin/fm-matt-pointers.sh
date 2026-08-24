#!/usr/bin/env bash
# fm-matt-pointers.sh - install one small pointer skill per Matt Pocock skill
# into the directory non-Claude runtimes read, so grok, codex, kimi and pi can
# reach the installed originals without a copy existing anywhere.
#
# The suite ships as the Claude plugin `mattpocock-skills`, and only `claude`
# reads the plugin cache. The other runtimes read `~/.agents/skills`. Vendoring
# the bodies there was tried and rotted, so each pointer is a few lines of
# instruction whose first step is to run bin/fm-matt-skill.sh, which resolves
# and prints the installed original at load time. No skill body is ever copied,
# so no skill body can ever drift, and an upstream plugin bump takes effect on
# the next load with nothing to re-run.
#
# What IS derived from upstream is each pointer's front matter: its description
# and its model-invocation flag, which the host runtime needs before any body is
# read. Re-run this script after a plugin bump to refresh them, and use --check
# to detect that they have fallen behind. A stale description only weakens
# automatic triggering; it can never make a worker follow a stale procedure.
#
# Attribution: the skills are Matt Pocock's work, MIT licensed, published at
# https://github.com/mattpocock/skills. Every generated pointer names him, the
# licence, the upstream repository, the plugin, and the validated version.
#
# Usage:
#   fm-matt-pointers.sh [--dest <dir>] [--dry-run]      install or refresh
#   fm-matt-pointers.sh --list                          what would be installed
#   fm-matt-pointers.sh --check [--dest <dir>]          audit installed pointers
#   fm-matt-pointers.sh --prune [--dest <dir>]          drop retired pointers
#   fm-matt-pointers.sh --uninstall [--dest <dir>]      remove every pointer
#
# Options:
#   --dest <dir>   where pointers live (default: $HOME/.agents/skills)
#   --loader <path>
#                  absolute path each pointer should invoke (default: the
#                  fm-matt-skill.sh beside this script). Generating from a
#                  disposable worktree bakes that worktree's path into every
#                  pointer, so pass the stable checkout's path instead.
#   --dry-run      print what would change, write nothing
#   --list         print "<pointer-name> <upstream-skill> <invocation>" and exit
#   --check        exit 1 when an installed pointer is missing, foreign, has
#                  drifted from what upstream would generate now, is retired
#                  upstream even when no skills remain declared, or names a
#                  loader that is no longer executable; every applicable state
#                  is reported independently
#   --prune        remove firstmate pointers whose upstream skill is gone
#   --uninstall    remove every firstmate pointer under --dest. Use this when a
#                  runtime turns out to read the installed plugin directly and
#                  the pointers are only duplicating it
#   --date <YYYY-MM-DD>
#                  stamp generated pointers with this date instead of today
#   -h, --help     print this header
#
# Safety: a destination subdirectory that exists without this script's
# `.firstmate-pointer` marker is never written to, never merged into, and never
# removed. It is reported and skipped. Only marked pointer directories are
# rewritten or pruned, so a hand-authored skill that happens to share a name
# survives untouched.
#
# Exit status:
#   0    everything requested succeeded, or --check found no drift
#   1    --check found drift, or a foreign directory blocked an install
#   2    usage error
#   3-6  the plugin could not be resolved (see bin/fm-matt-skill.sh)
set -eu

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
LOADER="$HERE/fm-matt-skill.sh"
MARKER=.firstmate-pointer
PREFIX=matt-
UPSTREAM=https://github.com/mattpocock/skills
PLUGIN_KEY=mattpocock-skills@claude-plugins-official

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die() {  # <exit-code> <message>
  code=$1
  shift
  printf 'fm-matt-pointers.sh: %s\n' "$*" >&2
  exit "$code"
}

DEST=${HOME}/.agents/skills
DRY=0
MODE=install
STAMP=
LOADER_PATH=

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --dest) [ "$#" -ge 2 ] || die 2 "--dest requires a directory"; DEST=$2; shift 2 ;;
    --dest=*) DEST=${1#*=}; shift ;;
    --loader) [ "$#" -ge 2 ] || die 2 "--loader requires a path"; LOADER_PATH=$2; shift 2 ;;
    --loader=*) LOADER_PATH=${1#*=}; shift ;;
    --dry-run) DRY=1; shift ;;
    --list) MODE=list; shift ;;
    --check) MODE=check; shift ;;
    --prune) MODE=prune; shift ;;
    --uninstall) MODE=uninstall; shift ;;
    --date) [ "$#" -ge 2 ] || die 2 "--date requires YYYY-MM-DD"; STAMP=$2; shift 2 ;;
    --date=*) STAMP=${1#*=}; shift ;;
    --) shift; break ;;
    *) die 2 "unexpected argument '$1' (see --help)" ;;
  esac
done

[ -x "$LOADER" ] || die 2 "loader is missing or not executable: $LOADER"

# The path baked into each pointer. It defaults to the loader this script runs,
# but may name a different checkout so pointers survive a disposable worktree.
if [ -z "$LOADER_PATH" ]; then
  LOADER_PATH=$LOADER
fi
case "$LOADER_PATH" in
  /*) : ;;
  *) die 2 "--loader must be an absolute path (got '$LOADER_PATH')" ;;
esac

if [ -z "$STAMP" ]; then
  STAMP=$(date -u +%Y-%m-%d)
fi
case "$STAMP" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) : ;;
  *) die 2 "--date must be YYYY-MM-DD (got '$STAMP')" ;;
esac

# Both the skill list and the identity block come from the loader, so this
# script never re-reads the registry and the two can never disagree about which
# install is in play. Identity is read through the first skill this install
# actually declares rather than a fixed name, so an upstream rename can never
# take out --check, --prune, or --uninstall - the modes an operator needs most
# when a rename has left stale pointers on disk.
SKILLS=$("$LOADER" --list)
IDENTITY_SKILL=
while IFS= read -r declared; do
  [ -n "$declared" ] || continue
  IDENTITY_SKILL=$declared
  break
done <<EOF
$SKILLS
EOF
HAVE_IDENTITY=0
VERSION=
COMMIT=
INSTALL_ROOT=
if [ -n "$IDENTITY_SKILL" ]; then
  IDENTITY=$("$LOADER" "$IDENTITY_SKILL" --check)
  VERSION=$(printf '%s\n' "$IDENTITY" | sed -n 's/^resolved_version=//p' | head -n 1)
  COMMIT=$(printf '%s\n' "$IDENTITY" | sed -n 's/^resolved_commit=//p' | head -n 1)
  SKILL_ROOT=$(printf '%s\n' "$IDENTITY" | sed -n 's/^skill_file=//p' | head -n 1)
  [ -n "$VERSION" ] || die 6 "could not read the resolved plugin version from the loader"
  INSTALL_ROOT=${SKILL_ROOT%/skills/*}
  HAVE_IDENTITY=1
elif [ "$MODE" != check ]; then
  die 6 "$PLUGIN_KEY declares no skills, so there is nothing to point at"
fi

# --- upstream front-matter reads ---------------------------------------------

skill_file_for() {  # <skill>
  "$LOADER" "$1" --path
}

front_matter_field() {  # <skill-file> <key>
  awk -v key="$2" '
    NR == 1 { if ($0 !~ /^---[[:space:]]*$/) exit 0; next }
    /^---[[:space:]]*$/ { exit 0 }
    index($0, key ":") == 1 {
      line = substr($0, length(key) + 2)
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      print line
      exit 0
    }
  ' "$1"
}

unquote() {  # <value>
  v=$1
  case "$v" in
    '"'*'"') v=${v#\"}; v=${v%\"} ;;
    "'"*"'") v=${v#\'}; v=${v%\'} ;;
  esac
  printf '%s' "$v"
}

yaml_quote() {  # <value> -> a safe double-quoted YAML scalar
  printf '"%s"' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
}

# --- pointer body ------------------------------------------------------------

render_pointer() {  # <skill> <pointer-name> <description> <dmi> <argument-hint> <date> <loader>
  skill=$1 pname=$2 desc=$3 dmi=$4 hint=$5 stamp=$6 loader=$7
  cat <<EOF
---
name: $pname
description: $(yaml_quote "$desc")
user-invocable: true
disable-model-invocation: $dmi
license: MIT
EOF
  [ -z "$hint" ] || printf 'argument-hint: %s\n' "$(yaml_quote "$hint")"
  cat <<EOF
metadata:
  firstmate-pointer: "true"
  generated: "$stamp"
  author: "Matt Pocock"
  upstream-skill: "$skill"
  upstream-repo: "$UPSTREAM"
  upstream-plugin: "$PLUGIN_KEY"
  validated-version: "$VERSION"
  validated-commit: "$COMMIT"
---

# $pname

This file is a pointer, not a skill. It contains no part of the procedure.

The real skill is **\`$skill\`** by **Matt Pocock**, MIT licensed, from
<$UPSTREAM>, installed here as the plugin \`$PLUGIN_KEY\`, validated against
version $VERSION ($COMMIT). Firstmate generated this pointer on $stamp so
runtimes that read \`.agents/skills\` can reach the installed original. Nothing
was copied, so nothing here can be out of date with the original.

## Step 1 - load the original, before doing anything else

Run exactly this:

\`\`\`bash
$loader $skill
\`\`\`

It prints the original \`SKILL.md\` bytes, preceded by an identity header naming
the resolved version, commit and SHA-256 of the file it read, and followed by
the absolute paths of the skill's support files.

## Step 2 - follow what it printed

Treat the printed instructions as the body of this skill and follow them as
written. Read any support file they refer to, at the absolute path listed. Do
not summarise the printed procedure and then work from your summary.

If the header says **PLUGIN CHANGED**, the installed plugin is newer than the
version this pointer was validated against. The printed bytes are still the
installed original and are authoritative, so follow them - and tell the user the
validated pin needs refreshing with \`bin/fm-matt-pointers.sh\`.

## If the command fails

It exits nonzero, prints a diagnostic on stderr, and prints nothing on stdout.
There is no second source for this procedure. So:

- Stop. Do not carry out the task this skill was meant to govern.
- Do not reconstruct, paraphrase, or improvise the procedure from memory, from
  this file, or from any copy found elsewhere on disk.
- Tell the user plainly that \`$skill\` could not be loaded, and quote the exact
  diagnostic.
- Never report this skill as used, followed, or applied.
EOF
}

render_marker() {  # <skill> <pointer-name> <date> <loader>
  cat <<EOF
generator=bin/fm-matt-pointers.sh
generated=$3
pointer=$2
upstream_skill=$1
upstream_plugin=$PLUGIN_KEY
upstream_repo=$UPSTREAM
validated_version=$VERSION
validated_commit=$COMMIT
loader=$4
EOF
}

# --- enumeration -------------------------------------------------------------

describe_skill() {  # <skill> -> "<dmi>\t<hint>\t<description>"
  f=$(skill_file_for "$1")
  d=$(unquote "$(front_matter_field "$f" description)")
  m=$(unquote "$(front_matter_field "$f" disable-model-invocation)")
  h=$(unquote "$(front_matter_field "$f" argument-hint)")
  [ -n "$d" ] || d="Matt Pocock's $1 skill."
  case "$m" in true) m=true ;; *) m=false ;; esac
  printf '%s\t%s\t%s' "$m" "$h" "$d"
}

if [ "$MODE" = list ]; then
  printf '%s\n' "$SKILLS" | while IFS= read -r s; do
    [ -n "$s" ] || continue
    row=$(describe_skill "$s")
    dmi=${row%%	*}
    if [ "$dmi" = true ]; then inv='user-invoked-only'; else inv='model-invocable'; fi
    printf '%s%s\t%s\t%s\n' "$PREFIX" "$s" "$s" "$inv"
  done
  exit 0
fi

is_pointer_dir() {  # <dir>
  [ -f "$1/$MARKER" ] && grep -q '^generator=bin/fm-matt-pointers.sh$' "$1/$MARKER" 2>/dev/null
}

# --- prune -------------------------------------------------------------------

if [ "$MODE" = prune ] || [ "$MODE" = uninstall ]; then
  [ -d "$DEST" ] || { printf 'nothing to remove: %s does not exist\n' "$DEST"; exit 0; }
  removed=0
  for dir in "$DEST"/"$PREFIX"*; do
    [ -d "$dir" ] || continue
    # Only marked pointer directories are ever removed, so a hand-authored skill
    # that happens to share the prefix survives both modes untouched.
    is_pointer_dir "$dir" || continue
    name=$(basename "$dir")
    skill=${name#"$PREFIX"}
    if [ "$MODE" = prune ] && printf '%s\n' "$SKILLS" | grep -qx -- "$skill"; then
      continue
    fi
    if [ "$DRY" -eq 1 ]; then
      printf 'would remove %s\n' "$dir"
    else
      rm -rf -- "$dir"
      printf 'removed %s\n' "$dir"
    fi
    removed=$((removed + 1))
  done
  [ "$removed" -gt 0 ] || printf 'no matching firstmate pointers under %s\n' "$DEST"
  exit 0
fi

# --- install and check -------------------------------------------------------

drift=0
foreign=0
written=0
unchanged=0

[ "$MODE" = check ] || [ "$DRY" -eq 1 ] || mkdir -p "$DEST"

printf '%s\n' "$SKILLS" | {
  status=0
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    row=$(describe_skill "$s")
    dmi=${row%%	*}
    rest=${row#*	}
    hint=${rest%%	*}
    desc=${rest#*	}
    pname="$PREFIX$s"
    dir="$DEST/$pname"
    file="$dir/SKILL.md"

    if [ -d "$dir" ] && ! is_pointer_dir "$dir"; then
      printf 'FOREIGN: %s exists and is not a firstmate pointer; left untouched\n' "$dir" >&2
      foreign=$((foreign + 1))
      status=1
      continue
    fi

    # Re-check against the date and loader the pointer already carries, so an
    # audit reports real content drift instead of the calendar moving or the
    # audit running from a different checkout than the install did.
    stamp=$STAMP
    loader=$LOADER_PATH
    recorded_loader=
    if [ "$MODE" = check ] && [ -f "$dir/$MARKER" ]; then
      existing=$(sed -n 's/^generated=//p' "$dir/$MARKER" | head -n 1)
      [ -z "$existing" ] || stamp=$existing
      recorded=$(sed -n 's/^loader=//p' "$dir/$MARKER" | head -n 1)
      if [ -n "$recorded" ]; then
        loader=$recorded
        recorded_loader=$recorded
      fi
    fi

    want=$(render_pointer "$s" "$pname" "$desc" "$dmi" "$hint" "$stamp" "$loader")

    if [ "$MODE" = check ]; then
      pointer_drift=0
      if [ ! -f "$file" ]; then
        printf 'MISSING: %s\n' "$file" >&2
        pointer_drift=1
      elif ! printf '%s\n' "$want" | cmp -s - "$file"; then
        printf 'DRIFTED: %s no longer matches the installed plugin front matter\n' "$file" >&2
        pointer_drift=1
      fi
      if [ -n "$recorded_loader" ] && [ ! -x "$recorded_loader" ]; then
        printf 'BROKEN: %s points at a loader that is not executable: %s\n' \
          "$file" "$recorded_loader" >&2
        pointer_drift=1
      fi
      if [ "$pointer_drift" -eq 1 ]; then
        drift=$((drift + 1))
        status=1
      fi
      continue
    fi

    if [ -f "$file" ] && printf '%s\n' "$want" | cmp -s - "$file"; then
      unchanged=$((unchanged + 1))
      continue
    fi

    if [ "$DRY" -eq 1 ]; then
      printf 'would write %s\n' "$file"
    else
      mkdir -p "$dir"
      printf '%s\n' "$want" >"$file"
      render_marker "$s" "$pname" "$stamp" "$loader" >"$dir/$MARKER"
      printf 'wrote %s\n' "$file"
    fi
    written=$((written + 1))
  done

  if [ "$MODE" = check ]; then
    # Declared skills above cannot expose a pointer whose upstream entry was
    # removed, so scan every marked destination directory as well.
    for dir in "$DEST"/*; do
      [ -d "$dir" ] || continue
      is_pointer_dir "$dir" || continue
      skill=$(sed -n 's/^upstream_skill=//p' "$dir/$MARKER" | head -n 1)
      [ -n "$skill" ] || skill=${dir##*/}
      case "$skill" in "$PREFIX"*) skill=${skill#"$PREFIX"} ;; esac
      printf '%s\n' "$SKILLS" | grep -qx -- "$skill" && continue

      file="$dir/SKILL.md"
      loader=$(sed -n 's/^loader=//p' "$dir/$MARKER" | head -n 1)
      printf 'RETIRED: %s no longer declares upstream skill %s\n' \
        "$dir" "$skill" >&2
      if [ ! -x "$loader" ]; then
        printf 'BROKEN: %s points at a loader that is not executable: %s\n' \
          "$file" "$loader" >&2
      fi
      drift=$((drift + 1))
      status=1
    done

    if [ "$status" -eq 0 ] && [ "$HAVE_IDENTITY" -eq 0 ]; then
      printf 'ok - no declared skills or marked pointers under %s\n' "$DEST"
    elif [ "$status" -eq 0 ]; then
      printf 'ok - %s pointers under %s match %s %s\n' \
        "$(printf '%s\n' "$SKILLS" | grep -c .)" "$DEST" "$PLUGIN_KEY" "$VERSION"
    else
      printf 'drift=%s foreign=%s under %s\n' "$drift" "$foreign" "$DEST" >&2
    fi
  else
    printf '%s pointers under %s: %s written, %s already current (%s %s, install %s)\n' \
      "$(printf '%s\n' "$SKILLS" | grep -c .)" "$DEST" "$written" "$unchanged" \
      "$PLUGIN_KEY" "$VERSION" "$INSTALL_ROOT"
    [ "$foreign" -eq 0 ] || printf '%s foreign directories were left untouched\n' "$foreign" >&2
  fi
  exit "$status"
}
