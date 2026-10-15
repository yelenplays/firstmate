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
#   fm-skill-path.sh <plugin>[@<marketplace>] --list-skills [options]
#
# A bare <plugin> installed from several marketplaces resolves to the one of
# those installs that is enabled in this Claude configuration, and refuses when
# none or more than one is enabled. <plugin>@<marketplace> names one install.
#
# Options:
#   --field <key>          print only that value from the resolved block
#   --list-files           print the skill's support tree, one relative path per
#                          line, instead of the resolved block
#   --list-skills          print every skill the install offers instead of
#                          resolving one, one "<skill> TAB <directory relative
#                          to the install>" per line, sorted by skill. A skill
#                          is listed only when resolving it by name would pass
#                          every check below; one that would be refused is left
#                          out, named on stderr, and turns the exit status to 7
#   --include-undeclared   also offer skills that sit in the install's source
#                          tree at skills/<skill>/ or skills/<bucket>/<skill>/
#                          without being declared by the manifest, except in a
#                          bucket named deprecated; a declared skill of the same
#                          name always wins
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
#   5    skill not offered by this installed plugin version: not declared, and
#        with --include-undeclared not present outside a deprecated bucket either
#   6    integrity or ambiguity refusal
#   7    --list-skills left out at least one skill that does not resolve; the
#        ones that do are still printed
#   127  a required tool is missing
#
# Nothing is printed on stdout unless every check passed, so a caller can treat
# any output as a resolved path and any other nonzero status as an honest
# unsupported state. The one exception is status 7 from --list-skills: stdout
# still carries every skill that passed, and each left-out skill is named on
# stderr as "fm-skill-path.sh: --list-skills leaves out <skill>, which does not
# resolve". Diagnostics go to stderr.
#
# What is verified before a path is printed:
#   - the registry entry resolves to exactly one enabled install and exactly one
#     scope, and the install directory exists;
#   - the plugin manifest names this plugin and agrees with the registry version,
#     so a swapped cache directory cannot pass;
#   - the skill is declared in that manifest's own skills list, so deprecated,
#     in-progress, misc, and personal skills that ship in the source tree but not
#     in the plugin never resolve unless the caller opts in with
#     --include-undeclared, and a deprecated bucket never resolves at all;
#   - exactly one declared skill, or failing that exactly one undeclared one,
#     matches the requested name;
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
LIST_SKILLS=0
INCLUDE_UNDECLARED=0
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
    --list-skills) LIST_SKILLS=1; shift ;;
    --include-undeclared) INCLUDE_UNDECLARED=1; shift ;;
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

[ -n "$PLUGIN_ARG" ] || die 2 "usage: fm-skill-path.sh <plugin>[@<marketplace>] <skill> (see --help)"
[ "$LIST_FILES" -eq 0 ] || [ -z "$FIELD" ] || die 2 "--list-files and --field are mutually exclusive"

if [ "$LIST_SKILLS" -eq 1 ]; then
  [ -z "$SKILL" ] || die 2 "--list-skills takes no skill name"
  [ -z "$FIELD" ] && [ "$LIST_FILES" -eq 0 ] \
    || die 2 "--list-skills cannot be combined with --field or --list-files"
else
  [ -n "$SKILL" ] || die 2 "usage: fm-skill-path.sh <plugin>[@<marketplace>] <skill> (see --help)"
  case "$SKILL" in
    */*|.|..) die 2 "skill name must not contain a path separator: '$SKILL'" ;;
  esac
fi

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

# --- enablement ---------------------------------------------------------------
#
# A disabled plugin is invisible to the Claude runtime, so its skills cannot be
# invoked even though the bytes are still on disk. Refusing a disabled install
# keeps a caller from reporting a workflow as available when no worker could
# actually load it, and picks the live install when several marketplaces carry
# the same plugin. A local settings file, when it carries a decision for a
# plugin, wins over the shared one; absence of any decision is treated as not
# enabled.

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

plugin_enabled() {  # <key> -> true|false|unset
  local state
  state=$(plugin_enabled_state "$CONFIG_ROOT/settings.local.json" "$1")
  if [ "$state" = unset ]; then
    state=$(plugin_enabled_state "$CONFIG_ROOT/settings.json" "$1")
  fi
  printf '%s\n' "$state"
}

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
  ENABLED_KEYS=
  ENABLED_COUNT=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    KEY_COUNT=$((KEY_COUNT + 1))
    [ "$(plugin_enabled "$line")" = true ] || continue
    ENABLED_KEYS="${ENABLED_KEYS:+$ENABLED_KEYS }$line"
    ENABLED_COUNT=$((ENABLED_COUNT + 1))
  done <<EOF
$KEY_MATCHES
EOF
  INSTALLED_KEYS=$(printf '%s' "$KEY_MATCHES" | tr '\n' ' ')
  case "$KEY_COUNT" in
    0) die 3 "plugin '$PLUGIN' is not installed for this configuration" ;;
    1) KEY=$(printf '%s' "$KEY_MATCHES" | head -n 1) ;;
    *)
      case "$ENABLED_COUNT" in
        0) die 4 "plugin '$PLUGIN' is installed from several marketplaces (${INSTALLED_KEYS% }) and none of them is enabled in this Claude configuration" ;;
        1) KEY=$ENABLED_KEYS ;;
        *) die 6 "plugin '$PLUGIN' is ambiguous: enabled from several marketplaces ($ENABLED_KEYS); disable all but one, or name it as <plugin>@<marketplace>" ;;
      esac
      ;;
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

case "$(plugin_enabled "$KEY")" in
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

# --- what the install offers -------------------------------------------------

declared_skills() {  # -> "<skill>\t<relative dir>" per declared entry
  jq -r '
    (if (.skills | type) == "array" then .skills else [] end)
    | map(select(type == "string"))
    | map(sub("^(\\./)+"; "") | sub("/+$"; ""))
    | .[]
    | "\(split("/") | last)\t\(.)"
  ' "$MANIFEST"
}

# Skills present in the source tree that the manifest does not declare, at
# skills/<skill>/SKILL.md or skills/<bucket>/<skill>/SKILL.md. A deprecated
# bucket is never offered, and a name the manifest declares is never offered a
# second time, because the declared skill always wins resolution.
undeclared_skills() {  # -> "<skill>\t<relative dir>" per undeclared entry
  [ -d "$INSTALL_PATH/skills" ] || return 0
  # Directory links are candidates even when dangling; never traverse them to
  # discover SKILL.md. Resolution rejects them before reading any skill bytes.
  # Values travel through the environment because awk -v rewrites backslashes.
  {
    find "$INSTALL_PATH/skills" -mindepth 2 -maxdepth 3 \( -type f -o -type l \) -name SKILL.md -print
    find "$INSTALL_PATH/skills" -mindepth 1 -maxdepth 2 -type l ! -name SKILL.md -print
  } | FM_SKILL_ROOT="$INSTALL_PATH/" FM_SKILL_DECLARED="$(declared_skills)" awk '
        BEGIN {
          root = ENVIRON["FM_SKILL_ROOT"]
          n = split(ENVIRON["FM_SKILL_DECLARED"], rows, "\n")
          for (i = 1; i <= n; i++) {
            if (split(rows[i], f, "\t") < 2) continue
            declared_name[f[1]] = 1
            declared_rel[f[2]] = 1
          }
        }
        index($0, root) == 1 {
          rel = substr($0, length(root) + 1)
          sub(/\/SKILL\.md$/, "", rel)
          if (("/" rel "/") ~ /\/deprecated\//) next
          name = rel
          sub(/.*\//, "", name)
          if ((name in declared_name) || (rel in declared_rel)) next
          printf "%s\t%s\n", name, rel
        }
      '
}

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

# --- one skill, offered by this version and intact ----------------------------
#
# The single place a skill name becomes a trusted directory. --list-skills runs
# it for every candidate, so a skill is listed only when it resolves.

resolve_skill() {  # <skill> -> sets REL, SKILL_DIR, SKILL_FILE, or dies
  local skill=$1 found count line declared_name

  found=$(declared_skills | awk -F '\t' -v s="$skill" '$1 == s { print $2 }')
  count=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    count=$((count + 1))
  done <<EOF
$found
EOF
  case "$count" in
    0)
      [ "$INCLUDE_UNDECLARED" -eq 1 ] || die 5 "skill '$skill' is not declared by $PLUGIN $VERSION"
      found=$(undeclared_skills | awk -F '\t' -v s="$skill" '$1 == s { print $2 }')
      count=0
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        count=$((count + 1))
      done <<EOF
$found
EOF
      case "$count" in
        0) die 5 "skill '$skill' is neither declared by $PLUGIN $VERSION nor present outside a deprecated bucket of its source tree" ;;
        1) : ;;
        *) die 6 "skill '$skill' is present more than once in the source tree of $PLUGIN $VERSION ($(printf '%s' "$found" | tr '\n' ' '))" ;;
      esac
      ;;
    1) : ;;
    *) die 6 "skill '$skill' is declared more than once by $PLUGIN $VERSION ($(printf '%s' "$found" | tr '\n' ' '))" ;;
  esac
  REL=$(printf '%s' "$found" | head -n 1)

  case "$REL" in
    /*) die 6 "skill '$skill' is declared with an absolute path: $REL" ;;
    ..|../*|*/..|*/../*) die 6 "skill '$skill' is declared with a traversing path: $REL" ;;
    '') die 6 "skill '$skill' is declared with an empty path" ;;
  esac

  SKILL_DIR="$INSTALL_PATH/$REL"
  [ -d "$SKILL_DIR" ] || die 6 "skill '$skill' directory is missing: $SKILL_DIR"

  if path_has_symlink_component "$INSTALL_PATH" "$REL"; then
    die 6 "skill '$skill' resolves through a symlink under $INSTALL_PATH"
  fi
  if [ -n "$(find "$SKILL_DIR" -type l -print 2>/dev/null | head -n 1)" ]; then
    die 6 "skill '$skill' support tree contains a symlink under $SKILL_DIR"
  fi

  INSTALL_REAL=$(CDPATH='' cd -- "$INSTALL_PATH" 2>/dev/null && pwd -P) \
    || die 6 "plugin '$KEY' install directory cannot be resolved: $INSTALL_PATH"
  SKILL_REAL=$(CDPATH='' cd -- "$SKILL_DIR" 2>/dev/null && pwd -P) \
    || die 6 "skill '$skill' directory cannot be resolved: $SKILL_DIR"
  case "$SKILL_REAL" in
    "$INSTALL_REAL"/*) : ;;
    *) die 6 "skill '$skill' resolves outside the plugin install: $SKILL_REAL" ;;
  esac

  SKILL_FILE="$SKILL_DIR/SKILL.md"
  [ -f "$SKILL_FILE" ] || die 6 "skill '$skill' has no SKILL.md at $SKILL_FILE"

  declared_name=$(awk '
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
  declared_name=${declared_name%\"}
  declared_name=${declared_name#\"}
  declared_name=${declared_name%\'}
  declared_name=${declared_name#\'}
  [ -n "$declared_name" ] \
    || die 6 "skill '$skill' front matter at $SKILL_FILE declares no name"
  [ "$declared_name" = "$skill" ] \
    || die 6 "skill file at $SKILL_FILE declares name '$declared_name', not '$skill'"
}

if [ "$LIST_SKILLS" -eq 1 ]; then
  # Each candidate resolves in its own subshell, so one that would be refused is
  # left out with its reason on stderr instead of taking the listing down, and
  # the distinct status keeps the gap from passing as a complete listing.
  LEFT_OUT=0
  CANDIDATES=$(
    {
      declared_skills
      [ "$INCLUDE_UNDECLARED" -eq 0 ] || undeclared_skills
    } | cut -f 1 | LC_ALL=C sort -u
  )
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if row=$(resolve_skill "$name" && printf '%s\t%s' "$name" "$REL"); then
      printf '%s\n' "$row"
    else
      printf 'fm-skill-path.sh: --list-skills leaves out %s, which does not resolve\n' "$name" >&2
      LEFT_OUT=$((LEFT_OUT + 1))
    fi
  done <<EOF
$CANDIDATES
EOF
  [ "$LEFT_OUT" -eq 0 ] || exit 7
  exit 0
fi

resolve_skill "$SKILL"

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
