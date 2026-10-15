#!/usr/bin/env bash
# fm-matt-skill.sh - load one Matt Pocock skill from its installed Claude plugin
# and print the original bytes, or refuse and print nothing on stdout.
#
# Firstmate never copies, vendors, or paraphrases a third-party skill. The
# suite ships as the Claude plugin `mattpocock-skills`, and only `claude` reads
# the plugin cache. Runtimes that discover skills under `~/.agents/skills`
# (codex, grok, kimi, pi) get a small generated pointer per skill instead, and
# every pointer's first instruction is to run this command. Nothing is copied,
# so nothing can drift, and an upstream plugin bump arrives on its own.
#
# The plugin is whichever `mattpocock-skills@<marketplace>` install is enabled
# in this Claude configuration; no marketplace is assumed. Installs from several
# marketplaces resolve to the one enabled install, and none or more than one
# enabled is a refusal.
#
# The skills offered are every skill in that install: the ones its manifest
# declares, plus the ones upstream keeps in its source tree outside the declared
# set (its in-progress and misc buckets), never a deprecated bucket. A skill is
# offered only when it resolves, so every name --list prints loads.
#
# Attribution: the skills are Matt Pocock's work, MIT licensed, published at
# https://github.com/mattpocock/skills and distributed as the Claude plugin
# `mattpocock-skills`. This script reads the installed original in place and
# reproduces nothing of its own.
#
# Usage:
#   fm-matt-skill.sh --list                   offered skills, one name per line
#   fm-matt-skill.sh <skill>                  header, then original SKILL.md bytes
#   fm-matt-skill.sh <skill> --path           absolute SKILL.md path only
#   fm-matt-skill.sh <skill> --files          support files, absolute, one per line
#   fm-matt-skill.sh <skill> --check          verify only, print the identity block
#
# Options:
#   --validated-plugin <plugin@marketplace>
#   --validated-version <version>
#   --validated-commit <sha>
#                            the plugin identity the caller was validated
#                            against; a generated pointer passes the identity it
#                            was generated from. Any difference is reported as
#                            pin=changed under a PLUGIN CHANGED banner, and no
#                            value given reports pin=unpinned
#   --require-validated-pin  refuse when any given validated value differs from
#                            the resolved plugin, instead of loading the
#                            installed bytes under a PLUGIN CHANGED banner;
#                            requires at least one --validated-* value
#   -h, --help               print this header
#
# Exit status:
#   0    resolved and printed
#   2    usage error
#   3    plugin not installed for this configuration
#   4    plugin installed but not enabled
#   5    skill not offered by this installed plugin version
#   6    integrity or ambiguity refusal
#   7    --list left out at least one offered skill that does not resolve; the
#        ones that do are still printed and each left-out one is named on stderr
#   127  a required tool is missing
#
# Nothing reaches stdout unless every check passed, so a caller may treat any
# output as original bytes and any other nonzero status as an honest
# unsupported state. The one exception is status 7 from --list: stdout still
# carries every offered skill that resolves, and bin/fm-skill-path.sh names each
# left-out skill on stderr. Diagnostics go to stderr.
#
# Version drift is reported, not fatal by default. Refusing on every upstream
# bump would turn each release into a fleet outage and recreate the sync chore
# the pointer pattern exists to remove, so a differing plugin still loads the
# original bytes and prints a PLUGIN CHANGED banner naming both identities.
# Identity, offer, symlink, containment, and front-matter checks always refuse,
# because those are the states where the bytes cannot be trusted.
# --require-validated-pin turns drift back into a refusal for a caller that
# wants the strict reading.
#
# Resolution, enablement, and listing are delegated to bin/fm-skill-path.sh, the
# repo's single owner of plugin-skill resolution. There is deliberately no second
# resolver: a loader that guesses a path when the owner is absent is exactly the
# drift the pointer pattern exists to prevent, so a missing owner is a refusal
# (127).
set -eu

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
RESOLVER="$HERE/fm-skill-path.sh"

PLUGIN=mattpocock-skills
UPSTREAM=https://github.com/mattpocock/skills
LICENSE=MIT
AUTHOR='Matt Pocock'

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
  printf 'fm-matt-skill.sh: %s\n' "$*" >&2
  exit "$code"
}

SKILL=
MODE=body
LIST=0
REQUIRE_PIN=0
PIN_PLUGIN=
PIN_VERSION=
PIN_COMMIT=

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --list) LIST=1; shift ;;
    --path) MODE=path; shift ;;
    --files) MODE=files; shift ;;
    --check) MODE=check; shift ;;
    --require-validated-pin) REQUIRE_PIN=1; shift ;;
    --validated-plugin)
      [ "$#" -ge 2 ] || die 2 "--validated-plugin requires <plugin@marketplace>"
      PIN_PLUGIN=$2
      shift 2
      ;;
    --validated-plugin=*) PIN_PLUGIN=${1#*=}; shift ;;
    --validated-version)
      [ "$#" -ge 2 ] || die 2 "--validated-version requires a version"
      PIN_VERSION=$2
      shift 2
      ;;
    --validated-version=*) PIN_VERSION=${1#*=}; shift ;;
    --validated-commit)
      [ "$#" -ge 2 ] || die 2 "--validated-commit requires a commit"
      PIN_COMMIT=$2
      shift 2
      ;;
    --validated-commit=*) PIN_COMMIT=${1#*=}; shift ;;
    --) shift; break ;;
    -*) die 2 "unknown option '$1' (see --help)" ;;
    *)
      [ -z "$SKILL" ] || die 2 "unexpected argument '$1' (see --help)"
      SKILL=$1
      shift
      ;;
  esac
done

if [ "$REQUIRE_PIN" -eq 1 ] && [ -z "$PIN_PLUGIN$PIN_VERSION$PIN_COMMIT" ]; then
  die 2 "--require-validated-pin needs --validated-plugin, --validated-version, or --validated-commit"
fi
if [ "$LIST" -eq 1 ]; then
  [ -z "$SKILL" ] || die 2 "--list takes no skill name"
else
  [ -n "$SKILL" ] || die 2 "usage: fm-matt-skill.sh <skill> (see --help)"
  case "$SKILL" in
    */*|.|..) die 2 "skill name must not contain a path separator: '$SKILL'" ;;
  esac
fi

[ -x "$RESOLVER" ] \
  || die 127 "bin/fm-skill-path.sh is required to resolve a skill and is missing or not executable at $RESOLVER"

# The repo's single owner of plugin-skill resolution finds the one enabled
# install, verifies it, and decides what it offers. Its refusals pass through
# verbatim on stderr, exit status included. A partial listing (7) still
# carries the skills that resolve.
resolve() {  # <args...> -> resolver stdout, or exit with its status
  set +e
  RESOLVED=$("$RESOLVER" "$PLUGIN" "$@" --include-undeclared)
  RC=$?
  set -e
  [ "$RC" -eq 0 ] || [ "$RC" -eq 7 ] || exit "$RC"
}

if [ "$LIST" -eq 1 ]; then
  resolve --list-skills
  [ -z "$RESOLVED" ] || printf '%s\n' "$RESOLVED" | cut -f 1
  exit "$RC"
fi

resolve "$SKILL"
field() {  # <key>
  printf '%s\n' "$RESOLVED" | sed -n "s/^$1=//p" | head -n 1
}
KEY="$(field plugin)@$(field marketplace)"
SCOPE=$(field scope)
VERSION=$(field version)
COMMIT=$(field commit)
SKILL_DIR=$(field skill_dir)
SKILL_FILE=$(field skill_file)
RESOLVED_BY="bin/fm-skill-path.sh"
[ -n "$SKILL_FILE" ] || die 6 "bin/fm-skill-path.sh resolved $SKILL without a skill_file"

# --- pin comparison ----------------------------------------------------------

PIN_STATE=unpinned
if [ -n "$PIN_PLUGIN$PIN_VERSION$PIN_COMMIT" ]; then
  PIN_STATE=validated
  if { [ -n "$PIN_PLUGIN" ] && [ "$PIN_PLUGIN" != "$KEY" ]; } \
     || { [ -n "$PIN_VERSION" ] && [ "$PIN_VERSION" != "$VERSION" ]; } \
     || { [ -n "$PIN_COMMIT" ] && [ "$PIN_COMMIT" != "$COMMIT" ]; }; then
    PIN_STATE=changed
  fi
fi
if [ "$PIN_STATE" = changed ] && [ "$REQUIRE_PIN" -eq 1 ]; then
  die 6 "resolved $KEY version '$VERSION' commit '${COMMIT:-none}', not the validated ${PIN_PLUGIN:-plugin} version '${PIN_VERSION:-any}' commit '${PIN_COMMIT:-any}'"
fi

if [ "$MODE" = path ]; then
  printf '%s\n' "$SKILL_FILE"
  exit 0
fi

support_files() {
  find "$SKILL_DIR" -type f ! -name SKILL.md -print 2>/dev/null | LC_ALL=C sort
}

if [ "$MODE" = files ]; then
  support_files
  exit 0
fi

digest() {  # <file> -> sha256 or empty
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  fi
}

emit_header() {
  printf '===== FIRSTMATE POINTER: ORIGINAL SKILL LOADED =====\n'
  printf 'skill=%s\n' "$SKILL"
  printf 'author=%s\n' "$AUTHOR"
  printf 'license=%s\n' "$LICENSE"
  printf 'upstream=%s\n' "$UPSTREAM"
  printf 'plugin=%s\n' "$KEY"
  printf 'scope=%s\n' "$SCOPE"
  printf 'resolved_version=%s\n' "$VERSION"
  printf 'resolved_commit=%s\n' "${COMMIT:-none}"
  printf 'validated_plugin=%s\n' "${PIN_PLUGIN:-none}"
  printf 'validated_version=%s\n' "${PIN_VERSION:-none}"
  printf 'validated_commit=%s\n' "${PIN_COMMIT:-none}"
  printf 'pin=%s\n' "$PIN_STATE"
  printf 'skill_file=%s\n' "$SKILL_FILE"
  d=$(digest "$SKILL_FILE")
  [ -z "$d" ] || printf 'skill_file_sha256=%s\n' "$d"
  printf 'resolved_by=%s\n' "$RESOLVED_BY"
  if [ "$PIN_STATE" = changed ]; then
    printf '\n!!! PLUGIN CHANGED !!!\n'
    printf 'The installed plugin is %s %s (%s), not the %s %s (%s) this pointer was validated against.\n' \
      "$KEY" "$VERSION" "${COMMIT:-no commit}" \
      "${PIN_PLUGIN:-same plugin}" "${PIN_VERSION:-any version}" "${PIN_COMMIT:-any commit}"
    printf 'The bytes below are the installed original and are authoritative. Follow them,\n'
    printf 'and tell the operator the pointers need regenerating with bin/fm-matt-pointers.sh.\n'
  fi
  printf '=====================================================\n'
}

if [ "$MODE" = check ]; then
  emit_header
  exit 0
fi

emit_header
printf '\n'
cat "$SKILL_FILE"
printf '\n===== END ORIGINAL SKILL.md =====\n'

SUPPORT=$(support_files)
if [ -n "$SUPPORT" ]; then
  printf '\nSupport files shipped with this skill. Read any the instructions above refer to:\n'
  printf '%s\n' "$SUPPORT"
fi
