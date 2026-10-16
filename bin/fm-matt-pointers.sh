#!/usr/bin/env bash
# fm-matt-pointers.sh - install one small pointer skill per Matt Pocock skill
# into the directory non-Claude runtimes read, so grok, codex, kimi and pi can
# reach the installed originals through generated pointers.
#
# Plugin selection and skill listing come from bin/fm-matt-skill.sh; see its
# header for those rules. Runtime discovery evidence lives in
# docs/verification/matt-pocock-runtime-reach.md; choose --dest for the runtime.
# Newly generated pointers load installed originals without copying skill bodies,
# so upstream procedure changes take effect on the next load without regeneration.
# The loader header owns compatibility loading for older pointers.
#
# Install and refresh generate one pointer per listed plugin skill; they do not
# create pointers for bundled compatibility routes.
#
# What IS derived from upstream is each pointer's front matter: its description
# and its model-invocation flag, which the host runtime needs before any body is
# read. Re-run this script after a plugin bump to refresh them, and use --check
# to detect that they have fallen behind. A stale description only weakens
# automatic triggering; it can never make a worker follow a stale procedure.
#
# Attribution: the skills are Matt Pocock's work, MIT licensed, published at
# https://github.com/mattpocock/skills. Every generated pointer names him, the
# licence, the upstream repository, the resolved plugin, and the version and
# commit it was generated from. That identity is the pointer's validated pin:
# its load command passes it to the loader, which flags any later difference.
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
#                  drifted from what upstream would generate now (including a
#                  plugin, version, or commit change), is retired upstream even
#                  when no skills remain offered, or names a
#                  loader that is no longer executable, or when an offered
#                  upstream skill does not resolve; every applicable state
#                  is reported independently. An unlisted skill the loader serves
#                  with pin=bundled is reported as BUNDLED, not drift; its pointer
#                  SKILL.md must still be a regular file and its recorded loader
#                  must be executable
#   --prune        remove firstmate pointers whose upstream skill is gone, unless
#                  the loader serves a bundled compatibility route (BUNDLED).
#                  A pointer whose skill upstream still offers but which does
#                  not resolve is kept and reported, never removed
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
#   1    --check found drift, a foreign directory blocked an install, install
#        or --check found a partial skill listing (UNRESOLVED), or --prune kept
#        a pointer whose upstream skill could not be resolved
#   2    usage error
#   3-6  the plugin could not be resolved (see bin/fm-matt-skill.sh); except for
#        --check, no resolvable skill also exits 6 before any destination changes
set -eu

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
LOADER="$HERE/fm-matt-skill.sh"
MARKER=.firstmate-pointer
PREFIX=matt-
UPSTREAM=https://github.com/mattpocock/skills
PLUGIN=mattpocock-skills

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
# actually offers rather than a fixed name, so an upstream rename can never
# take out --check, --prune, or --uninstall - the modes an operator needs most
# when a rename has left stale pointers on disk. With a partial listing (7),
# resolvable skills still supply identity and install candidates; install and
# --check report the omitted names rather than treating the set as complete.
LIST_ERR_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-matt-pointers.XXXXXX")
trap 'rm -f "$LIST_ERR_FILE"' EXIT
set +e
SKILLS=$("$LOADER" --list 2>"$LIST_ERR_FILE")
LIST_RC=$?
set -e
LIST_ERR=$(cat "$LIST_ERR_FILE")
rm -f "$LIST_ERR_FILE"
trap - EXIT
[ -z "$LIST_ERR" ] || printf '%s\n' "$LIST_ERR" >&2
case "$LIST_RC" in
  0|7) : ;;
  *) exit "$LIST_RC" ;;
esac
LEFT_OUT=$(printf '%s\n' "$LIST_ERR" \
  | sed -n 's/^fm-skill-path\.sh: --list-skills leaves out \(.*\), which does not resolve$/\1/p')
IDENTITY_SKILL=
while IFS= read -r declared; do
  [ -n "$declared" ] || continue
  IDENTITY_SKILL=$declared
  break
done <<EOF
$SKILLS
EOF
HAVE_IDENTITY=0
PLUGIN_KEY=$PLUGIN
VERSION=
COMMIT=
INSTALL_ROOT=
identity_field() {  # <identity-block> <key>
  printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n 1
}
if [ -n "$IDENTITY_SKILL" ]; then
  IDENTITY=$("$LOADER" "$IDENTITY_SKILL" --check)
  PLUGIN_KEY=$(identity_field "$IDENTITY" plugin)
  VERSION=$(identity_field "$IDENTITY" resolved_version)
  COMMIT=$(identity_field "$IDENTITY" resolved_commit)
  [ "$COMMIT" != none ] || COMMIT=
  SKILL_ROOT=$(identity_field "$IDENTITY" skill_file)
  [ -n "$VERSION" ] || die 6 "could not read the resolved plugin version from the loader"
  case "$PLUGIN_KEY" in
    "$PLUGIN"@?*) : ;;
    *) die 6 "the loader resolved an unexpected plugin '$PLUGIN_KEY'" ;;
  esac
  INSTALL_ROOT=${SKILL_ROOT%/skills/*}
  HAVE_IDENTITY=1
elif [ "$MODE" != check ]; then
  die 6 "the enabled $PLUGIN plugin offers no skill that resolves, so there is nothing to point at"
fi

# The loader owns compatibility as well as plugin resolution. An unlisted name
# can still be loadable through a bundled route; only status 5 proves it retired
# without that route. Every other refusal must preserve the pointer as unresolved.
unlisted_skill_state() {  # <skill> -> bundled|retired|unresolved
  local identity rc=0
  identity=$("$LOADER" "$1" --check 2>/dev/null) || rc=$?
  if [ "$rc" -eq 0 ] && printf '%s\n' "$identity" | grep -qx 'pin=bundled'; then
    printf 'bundled\n'
  elif [ "$rc" -eq 5 ]; then
    printf 'retired\n'
  else
    printf 'unresolved\n'
  fi
}

report_unresolved_listing() {
  [ "$LIST_RC" -eq 7 ] || return 0
  printf '%s\n' "$LEFT_OUT" | while IFS= read -r left; do
    [ -n "$left" ] || continue
    printf 'UNRESOLVED: upstream skill %s is offered but does not resolve, so it has no current pointer\n' \
      "$left" >&2
  done
  return 1
}

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
<$UPSTREAM>, installed here as the plugin \`$PLUGIN_KEY\`.
This pointer was validated against version $VERSION (${COMMIT:-no commit}).
Firstmate generated it on $stamp so runtimes that read \`.agents/skills\` can
reach the installed original. Nothing was copied, so nothing here can be out of
date with the original.

## Step 1 - load the original, before doing anything else

Run exactly this:

\`\`\`bash
$loader $skill \\
  --validated-plugin $PLUGIN_KEY \\
  --validated-version $VERSION${COMMIT:+ \\
  --validated-commit $COMMIT}
\`\`\`

It prints the original \`SKILL.md\` bytes, preceded by an identity header naming
the resolved version, commit and SHA-256 of the file it read, and followed by
the absolute paths of the skill's support files.

## Step 2 - follow what it printed

Treat the printed instructions as the body of this skill and follow them as
written. Read any support file they refer to, at the absolute path listed. Do
not summarise the printed procedure and then work from your summary.

If the header says **PLUGIN CHANGED**, the enabled plugin is no longer the
plugin, version, or commit this pointer was validated against. The printed bytes
are still the installed original and are authoritative, so follow them - and
tell the user the pointers need regenerating with \`bin/fm-matt-pointers.sh\`.

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
  status=0
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
    if [ "$MODE" = prune ]; then
      case "$(unlisted_skill_state "$skill")" in
        bundled)
          printf 'BUNDLED: kept %s, served by the repository compatibility skill\n' "$dir"
          continue
          ;;
        retired) : ;;
        *)
          printf 'UNRESOLVED: kept %s, whose upstream skill %s is still offered but does not resolve\n' \
            "$dir" "$skill" >&2
          status=1
          continue
          ;;
      esac
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
  exit "$status"
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
    # Offered skills above cannot expose a pointer whose upstream entry was
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
      pointer_drift=0
      case "$(unlisted_skill_state "$skill")" in
        bundled)
          printf 'BUNDLED: %s is served by the repository compatibility skill\n' "$dir"
          ;;
        retired)
          printf 'RETIRED: %s points at upstream skill %s, which the plugin no longer offers\n' \
            "$dir" "$skill" >&2
          pointer_drift=1
          ;;
        *)
          printf 'UNRESOLVED: %s points at upstream skill %s, which the plugin still offers but which does not resolve\n' \
            "$dir" "$skill" >&2
          pointer_drift=1
          ;;
      esac
      if [ ! -f "$file" ]; then
        printf 'MISSING: %s\n' "$file" >&2
        pointer_drift=1
      fi
      if [ ! -x "$loader" ]; then
        printf 'BROKEN: %s points at a loader that is not executable: %s\n' \
          "$file" "$loader" >&2
        pointer_drift=1
      fi
      if [ "$pointer_drift" -eq 1 ]; then
        drift=$((drift + 1))
        status=1
      fi
    done

    report_unresolved_listing || status=1
    if [ "$status" -eq 0 ] && [ "$HAVE_IDENTITY" -eq 0 ]; then
      printf 'ok - no offered skills or marked pointers under %s\n' "$DEST"
    elif [ "$status" -eq 0 ]; then
      printf 'ok - %s plugin pointers under %s match %s %s\n' \
        "$(printf '%s\n' "$SKILLS" | grep -c .)" "$DEST" "$PLUGIN_KEY" "$VERSION"
    else
      printf 'drift=%s foreign=%s under %s\n' "$drift" "$foreign" "$DEST" >&2
    fi
  else
    printf '%s pointers under %s: %s written, %s already current (%s %s, install %s)\n' \
      "$(printf '%s\n' "$SKILLS" | grep -c .)" "$DEST" "$written" "$unchanged" \
      "$PLUGIN_KEY" "$VERSION" "$INSTALL_ROOT"
    [ "$foreign" -eq 0 ] || printf '%s foreign directories were left untouched\n' "$foreign" >&2
    report_unresolved_listing || status=1
  fi
  exit "$status"
}
