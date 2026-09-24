# shellcheck shell=bash
# shellcheck disable=SC2016 # backticks in printf formats are literal Markdown.
# Wiki integration helpers for crewmate briefs and teardown.
# Sourced by bin/fm-brief.sh, bin/fm-project-mode.sh, bin/fm-teardown.sh, and
# bin/fm-guide-lander.sh.
# Everything here is opt-in: with no wikis root configured, briefs carry no wiki
# sections and teardown checks nothing (docs/configuration.md "Wiki context in
# briefs" owns the operator contract).
#
# fm_wiki_registry_names <registry> <project>
#   Prints the project's registry wiki token, one wiki name per line, or nothing.
#   Registry rows may carry a second bracket directly after the mode bracket, or
#   directly after the name when there is no mode bracket:
#     - <name> [<mode>] [wiki: A, B] - <desc> (added <date>)
#     - <name> [wiki: Some Wiki] - <desc> (added <date>)
#   Wiki names are comma-separated and may contain spaces.
# fm_wiki_root <config-dir>
#   Prints the configured wikis root (FM_WIKIS_ROOT wins over the first
#   non-comment line of <config-dir>/wikis-root; a leading ~/ expands to $HOME)
#   and succeeds only when it is a directory holding routing/estate.json.
# fm_wiki_context_section <wikis-root> <project> <registry>
#   Prints the brief's "# Wiki context" section. Never fails on missing or
#   malformed wiki data; it degrades to a single explanatory line instead.
# fm_wiki_estate_row <estate.json> <name>
#   Prints the first vault whose wiki name or card id matches <name> (case
#   insensitive) as unit-separator-joined fields: wiki, id, path, digest,
#   einstieg, cloud, modus, budget_klasse. Prints nothing when unmatched.
# fm_wiki_guide_section <guide-path>
#   Prints the brief's "# Wiki guide" section, which opens with the fixed
#   FM_WIKI_GUIDE_MARKER line bin/fm-teardown.sh keys its guide check on.
# fm_wiki_guide_header <guide-path>
#   Parses a guide draft's header into FM_WIKI_GUIDE_KIND and its fields.
#   The first non-blank line `no guide: <reason>` gives kind `none`.
#   Otherwise the first three non-blank lines must be, in any order, exactly
#   one each of `target: <vault name or card id>`, `topic: <kebab-slug>`, and
#   `action: new` or `action: update <page path>`, giving kind `draft` with
#   FM_WIKI_GUIDE_TARGET, FM_WIKI_GUIDE_TOPIC, and FM_WIKI_GUIDE_ACTION set.
#   Anything else gives kind `invalid` with FM_WIKI_GUIDE_ERROR naming why and
#   returns 1. A cloud flag in the draft is never read; the lander looks it up.

FM_WIKI_GUIDE_MARKER='Wiki guide contract: required'
FM_WIKI_MAX_PAGES=3
FM_WIKI_GUIDE_KIND=
FM_WIKI_GUIDE_TARGET=
FM_WIKI_GUIDE_TOPIC=
FM_WIKI_GUIDE_ACTION=
FM_WIKI_GUIDE_ERROR=

fm_wiki_registry_names() {
  local reg=$1 name=$2
  [ -f "$reg" ] || return 0
  awk -v n="$name" '
    $1 == "-" && $2 == n {
      rest = $0
      sub(/^[ \t]*-[ \t]+/, "", rest)
      rest = substr(rest, length(n) + 1)
      for (k = 0; k < 2; k++) {
        sub(/^[ \t]+/, "", rest)
        if (substr(rest, 1, 1) != "[") break
        close_at = index(rest, "]")
        if (close_at == 0) break
        body = substr(rest, 2, close_at - 2)
        rest = substr(rest, close_at + 1)
        if (body ~ /^wiki:/) {
          sub(/^wiki:/, "", body)
          m = split(body, parts, ",")
          for (i = 1; i <= m; i++) {
            w = parts[i]
            gsub(/^[ \t]+|[ \t]+$/, "", w)
            if (w != "") print w
          }
          exit
        }
      }
      exit
    }
  ' "$reg"
}

fm_wiki_expand_path() {  # <path> <base-for-relative>
  local p=$1 base=$2
  case "$p" in
    \~) printf '%s\n' "$HOME" ;;
    \~/*) printf '%s/%s\n' "$HOME" "${p#\~/}" ;;
    /*) printf '%s\n' "$p" ;;
    *) printf '%s/%s\n' "${base%/}" "$p" ;;
  esac
}

fm_wiki_root() {
  local config=$1 raw='' line root
  if [ -n "${FM_WIKIS_ROOT:-}" ]; then
    raw=$FM_WIKIS_ROOT
  elif [ -f "$config/wikis-root" ] && [ -r "$config/wikis-root" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        ''|\#*) continue ;;
        *) raw=$line; break ;;
      esac
    done < "$config/wikis-root"
  fi
  [ -n "$raw" ] || return 1
  root=$(fm_wiki_expand_path "$raw" "$PWD")
  root=${root%/}
  [ -d "$root" ] && [ -f "$root/routing/estate.json" ] || return 1
  printf '%s\n' "$root"
}

fm_wiki_estate_row() {
  jq -r --arg n "$2" '
    [.vaults[] | select(type == "object")
      | select(((.wiki // "") | tostring | ascii_downcase) == ($n | ascii_downcase)
            or ((.id // "") | tostring | ascii_downcase) == ($n | ascii_downcase))][0]
    | select(. != null)
    | [.wiki, .id, .path, .digest, .einstieg, .cloud, .modus, .budget_klasse]
    | map(if . == null then "" else tostring end) | join("\u001f")
  ' "$1" 2>/dev/null
}

fm_wiki_context_section() {
  local root=$1 project=$2 reg=$3 estate names name row line lines='' unresolved=''
  local wiki id path digest einstieg cloud modus budget vault_path entry label
  local project_page="$root/ProjektWiki/wiki/$project/$project.md"
  local cards="$root/routing/cards/"
  estate="$root/routing/estate.json"
  printf '# Wiki context\n'
  if [ -f "$project_page" ]; then
    printf 'Project page: `%s` - read it first.\n' "$project_page"
  fi
  names=$(fm_wiki_registry_names "$reg" "$project")
  if [ -z "$names" ]; then
    printf 'The registry carries no wiki token for %s; pick guide targets by the routing cards in `%s`.\n' "$project" "$cards"
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1 ||
    ! jq -e '.vaults | type == "array"' "$estate" >/dev/null 2>&1; then
    printf 'The wiki estate at `%s` is unreadable, so the registry wikis (%s) cannot be resolved; pick guide targets by the routing cards in `%s`.\n' \
      "$estate" "$(printf '%s\n' "$names" | paste -sd, - | sed 's/,/, /g')" "$cards"
    return 0
  fi
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    row=$(fm_wiki_estate_row "$estate" "$name") || row=
    if [ -z "$row" ]; then
      unresolved="$unresolved${unresolved:+, }$name"
      continue
    fi
    IFS=$'\037' read -r wiki id path digest einstieg cloud modus budget <<<"$row"
    label="${wiki:-$name} (card ${id:-unknown}, budget ${budget:-unknown})"
    vault_path=$(fm_wiki_expand_path "${path:-${wiki:-$name}}" "$root")
    if [ "$cloud" = nein ] || [ "$modus" = pointer ]; then
      printf -v line -- '- %s: private pointer vault - name only, do not open any of its files.' "$label"
    elif [ "$cloud" = nur-digest ]; then
      [ -n "$digest" ] && digest=$(fm_wiki_expand_path "$digest" "$vault_path")
      printf -v line -- '- %s at `%s`: read its digest `%s` only; do not open any other page.' \
        "$label" "$vault_path" "${digest:-none recorded}"
    elif [ "$cloud" = ja ]; then
      [ -n "$digest" ] && digest=$(fm_wiki_expand_path "$digest" "$vault_path")
      entry=
      [ -n "$einstieg" ] && entry=$(fm_wiki_expand_path "$einstieg" "$vault_path")
      printf -v line -- '- %s at `%s`: digest `%s`, entry page `%s`.' \
        "$label" "$vault_path" "${digest:-none recorded}" "${entry:-none recorded}"
    else
      printf -v line -- '- %s: unrecognized cloud flag "%s" - name only, do not open any of its files.' "$label" "$cloud"
    fi
    lines="$lines$line"$'\n'
  done <<<"$names"
  if [ -n "$lines" ]; then
    printf 'Read the backing wikis before building, cheapest first: a vault'"'"'s digest, then its entry page, then at most %s further pages the entry page points to.\n' "$FM_WIKI_MAX_PAGES"
    printf 'Skip any page with `private: true` in its front matter.\n'
    printf '%s' "$lines"
  fi
  if [ -n "$unresolved" ]; then
    printf 'Not in the wiki estate: %s; pick guide targets by the routing cards in `%s`.\n' "$unresolved" "$cards"
  fi
  return 0
}

fm_wiki_guide_section() {
  local guide=$1
  cat <<EOF
# Wiki guide
$FM_WIKI_GUIDE_MARKER
Before you append \`done:\`, write a guide draft to \`$guide\`; you may write this file even though it is outside your worktree.
Never write into a wiki vault yourself; a lander files the draft later.
Name the guide by its topic, not by this task, and check the target vault's entry page for an existing guide on that topic first so you update it rather than duplicate it.
Open the file with exactly these three header lines, before any other text: \`target: <vault name or card id>\`, \`topic: <kebab-case-slug>\`, and \`action: new\` or \`action: update <existing page path>\`; the lander looks up the vault's cloud flag itself.
Then write the body: how it works, what we did, what worked, pitfalls, sources, and the GitHub prior-art findings you checked, each marked adopt, adapt, or reject with why.
A trivial task may write a single line to add to an existing guide; a task with truly nothing reusable writes \`no guide: <reason>\`.
Cleanup refuses while this file is absent.
EOF
}

fm_wiki_guide_header() {
  local file=$1 line key value n=0 target='' topic='' action=''
  FM_WIKI_GUIDE_KIND=invalid
  FM_WIKI_GUIDE_TARGET=
  FM_WIKI_GUIDE_TOPIC=
  FM_WIKI_GUIDE_ACTION=
  FM_WIKI_GUIDE_ERROR=
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    FM_WIKI_GUIDE_ERROR='draft is not a readable file'
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    line=$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -n "$line" ] || continue
    if [ "$n" -eq 0 ] && [[ "$line" == 'no guide:'* ]]; then
      FM_WIKI_GUIDE_KIND=none
      return 0
    fi
    n=$((n + 1))
    key=${line%%:*}
    value=
    [ "$key" != "$line" ] && value=$(printf '%s' "${line#*:}" | sed 's/^[[:space:]]*//')
    case "$key" in
      target|topic|action)
        if [ -z "$value" ]; then
          FM_WIKI_GUIDE_ERROR="header line $n has an empty $key"
          return 1
        fi
        if [ -n "${!key}" ]; then
          FM_WIKI_GUIDE_ERROR="header repeats $key"
          return 1
        fi
        printf -v "$key" '%s' "$value"
        ;;
      *)
        FM_WIKI_GUIDE_ERROR="header line $n is not target, topic, or action"
        return 1
        ;;
    esac
    [ "$n" -lt 3 ] || break
  done < "$file"
  if [ -z "$target" ] || [ -z "$topic" ] || [ -z "$action" ]; then
    FM_WIKI_GUIDE_ERROR='header lacks target, topic, or action'
    return 1
  fi
  if ! [[ "$topic" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
    FM_WIKI_GUIDE_ERROR='topic is not a kebab-case slug'
    return 1
  fi
  if [ "$action" != new ] && ! [[ "$action" =~ ^update[[:space:]]+[^[:space:]] ]]; then
    FM_WIKI_GUIDE_ERROR='action is neither new nor update <page path>'
    return 1
  fi
  FM_WIKI_GUIDE_KIND=draft
  FM_WIKI_GUIDE_TARGET=$target
  FM_WIKI_GUIDE_TOPIC=$topic
  FM_WIKI_GUIDE_ACTION=$action
  return 0
}
