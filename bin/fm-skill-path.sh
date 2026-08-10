#!/usr/bin/env bash
# fm-skill-path.sh - resolve one exact installed Claude plugin skill from the
# authoritative plugin registry, or refuse and print no path.
#
# Firstmate never copies, vendors, or paraphrases a third-party skill. An adapter
# that wants to operate under an original skill resolves it here and reads the
# installed bytes, so an upstream bump arrives on its own and a moved or tampered
# install becomes a loud refusal instead of a hallucinated path.
#
# Usage:
#   fm-skill-path.sh <plugin>[@<marketplace>] <skill> [options]
#
# Options:
#   --field <key>          print only that value from the resolved block
#   --list-files           print the skill's support tree, one relative path per
#                          line, instead of the resolved block
#   --scope <scope>        select one scope when a plugin is installed in several
#                          (for example user, project, local)
#   --expect-version <v>   refuse unless the resolved plugin version equals <v>
#   --expect-commit <sha>  refuse unless the resolved source pin equals <sha>
#   -h, --help             print this header
#
# Resolved block on stdout (key=value lines, stable order):
#   plugin, marketplace, scope, version, commit, skill, skill_dir, skill_file
#
# Exit status:
#   0    resolved
#   2    usage error
#   3    plugin not installed (no registry, unreadable registry, or no entry)
#   4    plugin installed but not enabled in this Claude configuration
#   5    skill not declared by this installed plugin version
#   6    integrity or ambiguity refusal
#   127  a required tool is missing
#
# Nothing is printed on stdout unless every check passed, so a caller can treat
# any output as a resolved path and any nonzero status as an honest unsupported
# state. Diagnostics go to stderr.
#
# What is verified before a path is printed:
#   - the registry entry resolves to exactly one scope, and the install directory
#     exists;
#   - the plugin manifest names this plugin and agrees with the registry version,
#     so a swapped cache directory cannot pass;
#   - the skill is declared in that manifest's own skills list, so deprecated,
#     in-progress, misc, and personal skills that ship in the source tree but not
#     in the plugin can never resolve;
#   - exactly one declared skill matches the requested name;
#   - no component from the install root down to the skill, and no file inside the
#     skill directory, is a symlink, and the skill directory stays inside the
#     install root;
#   - SKILL.md exists as a regular file and its front matter names this skill.
#
# Resolution reads only the Claude plugin registry, so a stale user-level copy
# under ~/.agents/skills can never satisfy a request: it carries no plugin
# manifest and is never consulted. CLAUDE_CONFIG_DIR selects the configuration
# root, matching the value bin/fm-spawn.sh forwards to claude crewmates.
set -eu

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die() {  # <exit-code> <message>
  local code=$1
  shift
  printf 'fm-skill-path.sh: %s\n' "$*" >&2
  exit "$code"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

PLUGIN_ARG=
SKILL=
FIELD=
LIST_FILES=0
WANT_SCOPE=
EXPECT_VERSION=
EXPECT_COMMIT=

while [ "$#" -gt 0 ]; do
  case "$1" in
    --field)
      [ "$#" -ge 2 ] || die 2 "--field requires a key"
      FIELD=$2
      shift 2
      ;;
    --field=*) FIELD=${1#*=}; shift ;;
    --list-files) LIST_FILES=1; shift ;;
    --scope)
      [ "$#" -ge 2 ] || die 2 "--scope requires a value"
      WANT_SCOPE=$2
      shift 2
      ;;
    --scope=*) WANT_SCOPE=${1#*=}; shift ;;
    --expect-version)
      [ "$#" -ge 2 ] || die 2 "--expect-version requires a value"
      EXPECT_VERSION=$2
      shift 2
      ;;
    --expect-version=*) EXPECT_VERSION=${1#*=}; shift ;;
    --expect-commit)
      [ "$#" -ge 2 ] || die 2 "--expect-commit requires a value"
      EXPECT_COMMIT=$2
      shift 2
      ;;
    --expect-commit=*) EXPECT_COMMIT=${1#*=}; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) die 2 "unknown option '$1' (see --help)" ;;
    *)
      if [ -z "$PLUGIN_ARG" ]; then
        PLUGIN_ARG=$1
      elif [ -z "$SKILL" ]; then
        SKILL=$1
      else
        die 2 "unexpected argument '$1' (see --help)"
      fi
      shift
      ;;
  esac
done

[ -n "$PLUGIN_ARG" ] && [ -n "$SKILL" ] || die 2 "usage: fm-skill-path.sh <plugin>[@<marketplace>] <skill> (see --help)"
[ "$LIST_FILES" -eq 0 ] || [ -z "$FIELD" ] || die 2 "--list-files and --field are mutually exclusive"

case "$SKILL" in
  */*|.|..|'') die 2 "skill name must not contain a path separator: '$SKILL'" ;;
esac

# Validate the field name before touching the environment, so a typo is always
# the same usage error rather than whichever resolution failure came first.
case "$FIELD" in
  ''|plugin|marketplace|scope|version|commit|skill|skill_dir|skill_file) : ;;
  *) die 2 "unknown field '$FIELD' (plugin, marketplace, scope, version, commit, skill, skill_dir, skill_file)" ;;
esac

command -v jq >/dev/null 2>&1 || die 127 "jq is required to read the Claude plugin registry"

CONFIG_ROOT=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
REGISTRY="$CONFIG_ROOT/plugins/installed_plugins.json"

[ -f "$REGISTRY" ] \
  || die 3 "no Claude plugin registry at $REGISTRY; the plugin is not installed for this configuration"
jq -e . "$REGISTRY" >/dev/null 2>&1 \
  || die 3 "unreadable Claude plugin registry at $REGISTRY"

# --- registry key: <plugin>@<marketplace> -----------------------------------

PLUGIN=${PLUGIN_ARG%%@*}
MARKETPLACE=
case "$PLUGIN_ARG" in
  *@*) MARKETPLACE=${PLUGIN_ARG#*@} ;;
esac
[ -n "$PLUGIN" ] || die 2 "plugin name is empty in '$PLUGIN_ARG'"

if [ -n "$MARKETPLACE" ]; then
  KEY="$PLUGIN@$MARKETPLACE"
  jq -e --arg k "$KEY" '.plugins | has($k)' "$REGISTRY" >/dev/null 2>&1 \
    || die 3 "plugin '$KEY' is not installed for this configuration"
else
  KEY_MATCHES=$(jq -r --arg p "$PLUGIN" '
    (if (.plugins | type) == "object" then .plugins else {} end)
    | keys[]
    | select(startswith($p + "@"))
  ' "$REGISTRY")
  KEY_COUNT=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    KEY_COUNT=$((KEY_COUNT + 1))
  done <<EOF
$KEY_MATCHES
EOF
  case "$KEY_COUNT" in
    0) die 3 "plugin '$PLUGIN' is not installed for this configuration" ;;
    1) KEY=$(printf '%s' "$KEY_MATCHES" | head -n 1) ;;
    *) die 6 "plugin '$PLUGIN' is ambiguous across marketplaces ($(printf '%s' "$KEY_MATCHES" | tr '\n' ' ')); name it as <plugin>@<marketplace>" ;;
  esac
  MARKETPLACE=${KEY#*@}
fi

# --- exactly one install scope ----------------------------------------------

ENTRY_COUNT=$(jq -r --arg k "$KEY" --arg s "$WANT_SCOPE" '
  (if ((.plugins[$k]) | type) == "array" then .plugins[$k] else [] end)
  | map(select(type == "object"))
  | map(select($s == "" or (.scope // "") == $s))
  | length
' "$REGISTRY")
case "$ENTRY_COUNT" in
  0)
    if [ -n "$WANT_SCOPE" ]; then
      die 3 "plugin '$KEY' has no install with scope '$WANT_SCOPE'"
    fi
    die 3 "plugin '$KEY' has no install entry in $REGISTRY"
    ;;
  1) : ;;
  *)
    SCOPES=$(jq -r --arg k "$KEY" '
      (if ((.plugins[$k]) | type) == "array" then .plugins[$k] else [] end)
      | map(select(type == "object"))
      | map(.scope // "unknown")
      | join(" ")
    ' "$REGISTRY")
    die 6 "plugin '$KEY' is installed in several scopes ($SCOPES); select one with --scope"
    ;;
esac

ENTRY=$(jq -c --arg k "$KEY" --arg s "$WANT_SCOPE" '
  (if ((.plugins[$k]) | type) == "array" then .plugins[$k] else [] end)
  | map(select(type == "object"))
  | map(select($s == "" or (.scope // "") == $s))
  | .[0]
' "$REGISTRY")

INSTALL_PATH=$(printf '%s' "$ENTRY" | jq -r '.installPath // ""')
REG_VERSION=$(printf '%s' "$ENTRY" | jq -r '.version // ""')
COMMIT=$(printf '%s' "$ENTRY" | jq -r '.gitCommitSha // ""')
SCOPE=$(printf '%s' "$ENTRY" | jq -r '.scope // ""')

[ -n "$INSTALL_PATH" ] || die 6 "plugin '$KEY' has no installPath in $REGISTRY"
case "$INSTALL_PATH" in
  /*) : ;;
  *) die 6 "plugin '$KEY' has a non-absolute installPath: $INSTALL_PATH" ;;
esac
[ -d "$INSTALL_PATH" ] || die 3 "plugin '$KEY' install directory is missing: $INSTALL_PATH"

# --- enabled in this configuration ------------------------------------------
#
# A disabled plugin is invisible to the Claude runtime, so its skills cannot be
# invoked even though the bytes are still on disk. Refusing here keeps a caller
# from reporting a workflow as available when no worker could actually load it.
# A local settings file, when it carries a decision for this plugin, wins over
# the shared one; absence of any decision is treated as not enabled.

plugin_enabled_state() {  # <settings-file> <key> -> true|false|unset
  local file=$1 key=$2
  [ -f "$file" ] || { printf 'unset\n'; return 0; }
  jq -e . "$file" >/dev/null 2>&1 || { printf 'unset\n'; return 0; }
  jq -r --arg k "$key" '
    if ((.enabledPlugins) | type) != "object" then "unset"
    elif (.enabledPlugins | has($k)) then ((.enabledPlugins[$k]) | tostring)
    else "unset"
    end
  ' "$file"
}

ENABLED=$(plugin_enabled_state "$CONFIG_ROOT/settings.local.json" "$KEY")
if [ "$ENABLED" = unset ]; then
  ENABLED=$(plugin_enabled_state "$CONFIG_ROOT/settings.json" "$KEY")
fi
case "$ENABLED" in
  true) : ;;
  false) die 4 "plugin '$KEY' is installed but disabled in this Claude configuration" ;;
  *) die 4 "plugin '$KEY' is installed but not enabled in this Claude configuration" ;;
esac

# --- manifest identity -------------------------------------------------------

MANIFEST="$INSTALL_PATH/.claude-plugin/plugin.json"
[ -f "$MANIFEST" ] \
  || die 6 "plugin '$KEY' install has no manifest at $MANIFEST"
jq -e . "$MANIFEST" >/dev/null 2>&1 \
  || die 6 "plugin '$KEY' has an unreadable manifest at $MANIFEST"

MANIFEST_NAME=$(jq -r '.name // ""' "$MANIFEST")
MANIFEST_VERSION=$(jq -r '.version // ""' "$MANIFEST")
[ "$MANIFEST_NAME" = "$PLUGIN" ] \
  || die 6 "install for '$KEY' carries manifest name '$MANIFEST_NAME', not '$PLUGIN'"
if [ -n "$REG_VERSION" ] && [ "$MANIFEST_VERSION" != "$REG_VERSION" ]; then
  die 6 "plugin '$KEY' registry version '$REG_VERSION' disagrees with manifest version '$MANIFEST_VERSION'"
fi
VERSION=${MANIFEST_VERSION:-$REG_VERSION}
[ -n "$VERSION" ] || die 6 "plugin '$KEY' declares no version"

if [ -n "$EXPECT_VERSION" ] && [ "$VERSION" != "$EXPECT_VERSION" ]; then
  die 6 "plugin '$KEY' is version '$VERSION', not the expected '$EXPECT_VERSION'"
fi
if [ -n "$EXPECT_COMMIT" ] && [ "$COMMIT" != "$EXPECT_COMMIT" ]; then
  die 6 "plugin '$KEY' is pinned at source commit '${COMMIT:-none}', not the expected '$EXPECT_COMMIT'"
fi

# --- the skill must be declared by this version ------------------------------

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
  *) die 6 "skill '$SKILL' is declared more than once by $PLUGIN $VERSION ($(printf '%s' "$DECLARED" | tr '\n' ' '))" ;;
esac
REL=$(printf '%s' "$DECLARED" | head -n 1)
REL=${REL#./}
REL=${REL%/}

case "$REL" in
  /*) die 6 "skill '$SKILL' is declared with an absolute path: $REL" ;;
  ..|../*|*/..|*/../*) die 6 "skill '$SKILL' is declared with a traversing path: $REL" ;;
  '') die 6 "skill '$SKILL' is declared with an empty path" ;;
esac

SKILL_DIR="$INSTALL_PATH/$REL"
[ -d "$SKILL_DIR" ] || die 6 "skill '$SKILL' directory is missing: $SKILL_DIR"

# --- no symlink from the install root down to the skill's files --------------
#
# Ancestors of the install root belong to the operating system (macOS resolves
# /tmp and $TMPDIR through symlinks), so only the plugin's own tree is checked.

path_has_symlink_component() {  # <root> <relative-path>
  local cur=$1 remainder=$2 part
  while [ -n "$remainder" ]; do
    part=${remainder%%/*}
    if [ "$part" = "$remainder" ]; then
      remainder=
    else
      remainder=${remainder#*/}
    fi
    [ -n "$part" ] || continue
    cur="$cur/$part"
    [ ! -L "$cur" ] || return 0
  done
  return 1
}

if path_has_symlink_component "$INSTALL_PATH" "$REL"; then
  die 6 "skill '$SKILL' resolves through a symlink under $INSTALL_PATH"
fi
if [ -n "$(find "$SKILL_DIR" -type l -print 2>/dev/null | head -n 1)" ]; then
  die 6 "skill '$SKILL' support tree contains a symlink under $SKILL_DIR"
fi

INSTALL_REAL=$(CDPATH='' cd -- "$INSTALL_PATH" 2>/dev/null && pwd -P) \
  || die 6 "plugin '$KEY' install directory cannot be resolved: $INSTALL_PATH"
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
DECLARED_NAME=${DECLARED_NAME%\"}
DECLARED_NAME=${DECLARED_NAME#\"}
DECLARED_NAME=${DECLARED_NAME%\'}
DECLARED_NAME=${DECLARED_NAME#\'}
[ -n "$DECLARED_NAME" ] \
  || die 6 "skill '$SKILL' front matter at $SKILL_FILE declares no name"
[ "$DECLARED_NAME" = "$SKILL" ] \
  || die 6 "skill file at $SKILL_FILE declares name '$DECLARED_NAME', not '$SKILL'"

# --- resolved -----------------------------------------------------------------

if [ "$LIST_FILES" -eq 1 ]; then
  # Relative paths so a caller can join them onto skill_dir. Stripping by
  # parameter expansion keeps a directory name containing sed metacharacters
  # from corrupting the listing.
  find "$SKILL_DIR" -type f -print \
    | while IFS= read -r found; do
        printf '%s\n' "${found#"$SKILL_DIR"/}"
      done \
    | LC_ALL=C sort
  exit 0
fi

emit_field() {  # <key>
  case "$1" in
    plugin) printf '%s\n' "$PLUGIN" ;;
    marketplace) printf '%s\n' "$MARKETPLACE" ;;
    scope) printf '%s\n' "$SCOPE" ;;
    version) printf '%s\n' "$VERSION" ;;
    commit) printf '%s\n' "$COMMIT" ;;
    skill) printf '%s\n' "$SKILL" ;;
    skill_dir) printf '%s\n' "$SKILL_DIR" ;;
    skill_file) printf '%s\n' "$SKILL_FILE" ;;
    *) return 1 ;;
  esac
}

if [ -n "$FIELD" ]; then
  emit_field "$FIELD" || die 2 "unknown field '$FIELD' (plugin, marketplace, scope, version, commit, skill, skill_dir, skill_file)"
  exit 0
fi

printf 'plugin=%s\n' "$PLUGIN"
printf 'marketplace=%s\n' "$MARKETPLACE"
printf 'scope=%s\n' "$SCOPE"
printf 'version=%s\n' "$VERSION"
printf 'commit=%s\n' "$COMMIT"
printf 'skill=%s\n' "$SKILL"
printf 'skill_dir=%s\n' "$SKILL_DIR"
printf 'skill_file=%s\n' "$SKILL_FILE"
