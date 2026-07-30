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
# Attribution: the skills are Matt Pocock's work, MIT licensed, published at
# https://github.com/mattpocock/skills and distributed as the plugin
# `mattpocock-skills@claude-plugins-official`. This script reads the installed
# original in place and reproduces nothing of its own.
#
# Usage:
#   fm-matt-skill.sh --list                   declared skills, one name per line
#   fm-matt-skill.sh <skill>                  header, then original SKILL.md bytes
#   fm-matt-skill.sh <skill> --path           absolute SKILL.md path only
#   fm-matt-skill.sh <skill> --files          support files, absolute, one per line
#   fm-matt-skill.sh <skill> --check          verify only, print the identity block
#
# Options:
#   --require-validated-pin  refuse when the installed version or source commit
#                            differs from the pin this repo was validated
#                            against, instead of loading the newer bytes under a
#                            PLUGIN CHANGED banner
#   -h, --help               print this header
#
# Exit status:
#   0    resolved and printed
#   2    usage error
#   3    plugin not installed for this configuration
#   4    plugin installed but not enabled
#   5    skill not declared by this installed plugin version
#   6    integrity or ambiguity refusal
#   127  a required tool is missing
#
# Nothing reaches stdout unless every check passed, so a caller may treat any
# output as original bytes and any nonzero status as an honest unsupported
# state. Diagnostics go to stderr.
#
# Version drift is reported, not fatal by default. Refusing on every upstream
# bump would turn each release into a fleet outage and recreate the sync chore
# the pointer pattern exists to remove, so a differing version still loads the
# original bytes and prints a PLUGIN CHANGED banner naming both versions.
# Identity, declaration, symlink, containment, and front-matter checks always
# refuse, because those are the states where the bytes cannot be trusted.
# --require-validated-pin turns drift back into a refusal for a caller that
# wants the strict reading.
#
# Resolution is delegated to bin/fm-skill-path.sh when that script is present,
# which is the repo's single owner of plugin-skill resolution. The inline
# fallback below exists only because that owner has not landed yet; it verifies
# the same properties for this one plugin and is meant to be deleted, without
# touching any generated pointer, once the owner is available.
set -eu

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
RESOLVER="$HERE/fm-skill-path.sh"

PLUGIN=mattpocock-skills
MARKETPLACE=claude-plugins-official
VALIDATED_VERSION=1.2.0
VALIDATED_COMMIT=2ab958093e83e0ec752e6c1c5932da465bf23e0c
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

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --list) LIST=1; shift ;;
    --path) MODE=path; shift ;;
    --files) MODE=files; shift ;;
    --check) MODE=check; shift ;;
    --require-validated-pin) REQUIRE_PIN=1; shift ;;
    --) shift; break ;;
    -*) die 2 "unknown option '$1' (see --help)" ;;
    *)
      [ -z "$SKILL" ] || die 2 "unexpected argument '$1' (see --help)"
      SKILL=$1
      shift
      ;;
  esac
done

command -v jq >/dev/null 2>&1 || die 127 "jq is required to read the Claude plugin registry"

CONFIG_ROOT=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
REGISTRY="$CONFIG_ROOT/plugins/installed_plugins.json"
KEY="$PLUGIN@$MARKETPLACE"

# --- install location and enablement ----------------------------------------
#
# Needed for --list and for the fallback resolver, and cheap enough that the
# delegating path reuses it for the manifest read rather than re-deriving it.

[ -f "$REGISTRY" ] \
  || die 3 "no Claude plugin registry at $REGISTRY; $PLUGIN is not installed for this configuration"
jq -e . "$REGISTRY" >/dev/null 2>&1 \
  || die 3 "unreadable Claude plugin registry at $REGISTRY"

ENTRY_COUNT=$(jq -r --arg k "$KEY" '
  (if ((.plugins[$k]) | type) == "array" then .plugins[$k] else [] end)
  | map(select(type == "object"))
  | length
' "$REGISTRY")
case "$ENTRY_COUNT" in
  0) die 3 "$KEY is not installed for this configuration ($REGISTRY)" ;;
  1) : ;;
  *) die 6 "$KEY is installed in several scopes; resolve it with bin/fm-skill-path.sh --scope" ;;
esac

ENTRY=$(jq -c --arg k "$KEY" '
  (if ((.plugins[$k]) | type) == "array" then .plugins[$k] else [] end)
  | map(select(type == "object"))
  | .[0]
' "$REGISTRY")
INSTALL_PATH=$(printf '%s' "$ENTRY" | jq -r '.installPath // ""')
REG_VERSION=$(printf '%s' "$ENTRY" | jq -r '.version // ""')
COMMIT=$(printf '%s' "$ENTRY" | jq -r '.gitCommitSha // ""')
SCOPE=$(printf '%s' "$ENTRY" | jq -r '.scope // ""')

[ -n "$INSTALL_PATH" ] || die 6 "$KEY has no installPath in $REGISTRY"
case "$INSTALL_PATH" in
  /*) : ;;
  *) die 6 "$KEY has a non-absolute installPath: $INSTALL_PATH" ;;
esac
[ -d "$INSTALL_PATH" ] \
  || die 3 "$KEY install directory is missing (moved or removed): $INSTALL_PATH"

plugin_enabled_state() {  # <settings-file> -> true|false|unset
  file=$1
  [ -f "$file" ] || { printf 'unset\n'; return 0; }
  jq -e . "$file" >/dev/null 2>&1 || { printf 'unset\n'; return 0; }
  jq -r --arg k "$KEY" '
    if ((.enabledPlugins) | type) != "object" then "unset"
    elif (.enabledPlugins | has($k)) then ((.enabledPlugins[$k]) | tostring)
    else "unset"
    end
  ' "$file"
}

ENABLED=$(plugin_enabled_state "$CONFIG_ROOT/settings.local.json")
if [ "$ENABLED" = unset ]; then
  ENABLED=$(plugin_enabled_state "$CONFIG_ROOT/settings.json")
fi
case "$ENABLED" in
  true) : ;;
  false) die 4 "$KEY is installed but disabled in this Claude configuration" ;;
  *) die 4 "$KEY is installed but not enabled in this Claude configuration" ;;
esac

MANIFEST="$INSTALL_PATH/.claude-plugin/plugin.json"
[ -f "$MANIFEST" ] || die 6 "$KEY install has no manifest at $MANIFEST"
jq -e . "$MANIFEST" >/dev/null 2>&1 || die 6 "$KEY has an unreadable manifest at $MANIFEST"

MANIFEST_NAME=$(jq -r '.name // ""' "$MANIFEST")
VERSION=$(jq -r '.version // ""' "$MANIFEST")
[ "$MANIFEST_NAME" = "$PLUGIN" ] \
  || die 6 "install for $KEY carries manifest name '$MANIFEST_NAME', not '$PLUGIN'"
if [ -n "$REG_VERSION" ] && [ "$VERSION" != "$REG_VERSION" ]; then
  die 6 "$KEY registry version '$REG_VERSION' disagrees with manifest version '$VERSION'"
fi
[ -n "$VERSION" ] || die 6 "$KEY declares no version"

if [ "$LIST" -eq 1 ]; then
  [ -z "$SKILL" ] || die 2 "--list takes no skill name"
  jq -r '
    (if (.skills | type) == "array" then .skills else [] end)
    | map(select(type == "string"))
    | map(sub("/+$"; "") | split("/") | last)
    | .[]
  ' "$MANIFEST" | LC_ALL=C sort
  exit 0
fi

[ -n "$SKILL" ] || die 2 "usage: fm-matt-skill.sh <skill> (see --help)"
case "$SKILL" in
  */*|.|..) die 2 "skill name must not contain a path separator: '$SKILL'" ;;
esac

# --- resolve the skill directory --------------------------------------------

if [ -x "$RESOLVER" ]; then
  # The repo's single owner of plugin-skill resolution. It re-derives the
  # registry entry itself, so this branch passes only the identity constants and
  # trusts its refusals verbatim.
  set +e
  RESOLVED=$("$RESOLVER" "$KEY" "$SKILL" 2>&1)
  RC=$?
  set -e
  if [ "$RC" -ne 0 ]; then
    printf '%s\n' "$RESOLVED" >&2
    exit "$RC"
  fi
  SKILL_DIR=$(printf '%s\n' "$RESOLVED" | sed -n 's/^skill_dir=//p' | head -n 1)
  SKILL_FILE=$(printf '%s\n' "$RESOLVED" | sed -n 's/^skill_file=//p' | head -n 1)
  RESOLVED_BY="bin/fm-skill-path.sh"
  [ -n "$SKILL_FILE" ] || die 6 "bin/fm-skill-path.sh resolved $SKILL without a skill_file"
else
  # --- inline fallback, delete once bin/fm-skill-path.sh lands ---------------
  RESOLVED_BY="fm-matt-skill.sh built-in fallback (bin/fm-skill-path.sh not installed)"

  DECLARED=$(jq -r --arg s "$SKILL" '
    (if (.skills | type) == "array" then .skills else [] end)
    | map(select(type == "string"))
    | map(select((sub("/+$"; "") | split("/") | last) == $s))
    | .[]
  ' "$MANIFEST")
  DECLARED_COUNT=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    DECLARED_COUNT=$((DECLARED_COUNT + 1))
  done <<EOF
$DECLARED
EOF
  case "$DECLARED_COUNT" in
    0) die 5 "skill '$SKILL' is not declared by $PLUGIN $VERSION" ;;
    1) : ;;
    *) die 6 "skill '$SKILL' is declared more than once by $PLUGIN $VERSION" ;;
  esac

  REL=$(printf '%s' "$DECLARED" | head -n 1)
  REL=${REL#./}
  REL=${REL%/}
  case "$REL" in
    ''|/*) die 6 "skill '$SKILL' is declared with an unusable path: '$REL'" ;;
    ..|../*|*/..|*/../*) die 6 "skill '$SKILL' is declared with a traversing path: $REL" ;;
  esac

  SKILL_DIR="$INSTALL_PATH/$REL"
  [ -d "$SKILL_DIR" ] || die 6 "skill '$SKILL' directory is missing: $SKILL_DIR"

  # Ancestors of the install root belong to the operating system (macOS resolves
  # /tmp through a symlink), so only the plugin's own tree is checked.
  cur=$INSTALL_PATH
  remainder=$REL
  while [ -n "$remainder" ]; do
    part=${remainder%%/*}
    if [ "$part" = "$remainder" ]; then remainder=; else remainder=${remainder#*/}; fi
    [ -n "$part" ] || continue
    cur="$cur/$part"
    [ ! -L "$cur" ] || die 6 "skill '$SKILL' resolves through a symlink at $cur"
  done
  if [ -n "$(find "$SKILL_DIR" -type l -print 2>/dev/null | head -n 1)" ]; then
    die 6 "skill '$SKILL' support tree contains a symlink under $SKILL_DIR"
  fi

  INSTALL_REAL=$(CDPATH='' cd -- "$INSTALL_PATH" 2>/dev/null && pwd -P) \
    || die 6 "$KEY install directory cannot be resolved: $INSTALL_PATH"
  SKILL_REAL=$(CDPATH='' cd -- "$SKILL_DIR" 2>/dev/null && pwd -P) \
    || die 6 "skill '$SKILL' directory cannot be resolved: $SKILL_DIR"
  case "$SKILL_REAL" in
    "$INSTALL_REAL"/*) : ;;
    *) die 6 "skill '$SKILL' resolves outside the plugin install: $SKILL_REAL" ;;
  esac

  SKILL_FILE="$SKILL_DIR/SKILL.md"
  [ -f "$SKILL_FILE" ] || die 6 "skill '$SKILL' has no SKILL.md at $SKILL_FILE"

  DECLARED_NAME=$(awk '
    NR == 1 { if ($0 !~ /^---[[:space:]]*$/) exit 0; next }
    /^---[[:space:]]*$/ { exit 0 }
    /^name:[[:space:]]*/ {
      line = $0
      sub(/^name:[[:space:]]*/, "", line)
      sub(/[[:space:]]+$/, "", line)
      print line
      exit 0
    }
  ' "$SKILL_FILE")
  DECLARED_NAME=${DECLARED_NAME%\"}; DECLARED_NAME=${DECLARED_NAME#\"}
  DECLARED_NAME=${DECLARED_NAME%\'}; DECLARED_NAME=${DECLARED_NAME#\'}
  [ "$DECLARED_NAME" = "$SKILL" ] \
    || die 6 "skill file at $SKILL_FILE declares name '${DECLARED_NAME:-none}', not '$SKILL'"
  # --- end inline fallback ---------------------------------------------------
fi

# --- pin comparison ----------------------------------------------------------

PIN_STATE=validated
if [ "$VERSION" != "$VALIDATED_VERSION" ] || [ "$COMMIT" != "$VALIDATED_COMMIT" ]; then
  PIN_STATE=changed
fi
if [ "$PIN_STATE" = changed ] && [ "$REQUIRE_PIN" -eq 1 ]; then
  die 6 "$KEY resolves to version '$VERSION' commit '${COMMIT:-none}', not the validated '$VALIDATED_VERSION' commit '$VALIDATED_COMMIT'"
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
  printf 'validated_version=%s\n' "$VALIDATED_VERSION"
  printf 'validated_commit=%s\n' "$VALIDATED_COMMIT"
  printf 'pin=%s\n' "$PIN_STATE"
  printf 'skill_file=%s\n' "$SKILL_FILE"
  d=$(digest "$SKILL_FILE")
  [ -z "$d" ] || printf 'skill_file_sha256=%s\n' "$d"
  printf 'resolved_by=%s\n' "$RESOLVED_BY"
  if [ "$PIN_STATE" = changed ]; then
    printf '\n!!! PLUGIN CHANGED !!!\n'
    printf 'The installed plugin is %s (%s), not the %s (%s) this pointer was validated against.\n' \
      "$VERSION" "${COMMIT:-no commit}" "$VALIDATED_VERSION" "$VALIDATED_COMMIT"
    printf 'The bytes below are the installed original and are authoritative. Follow them,\n'
    printf 'and tell the operator the validated pin needs refreshing.\n'
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
