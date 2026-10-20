#!/usr/bin/env bash
# fm-memory.sh - plain-markdown memory store with a light BM25 search index.
#
# Usage:
#   fm-memory.sh remember [--category <cat>] [--expires <YYYY-MM-DD>]
#                         [--sensitivity normal|private] [--task <task-id>]
#                         <topic> [body...]
#   fm-memory.sh complete-task <task-id> [--report <path>] [--pr <url>]
#                              [--outcome <text>]
#   fm-memory.sh recall [--json] [--limit <n>] <query>
#   fm-memory.sh now [--max-chars <n>] [--exclude-private]
#   fm-memory.sh merge-from <other-store-dir>
#   fm-memory.sh list
#   fm-memory.sh reindex
#   fm-memory.sh stats
#   fm-memory.sh dir
#
# docs/memory.md owns the operator contract, the migration from OpenViking,
# and the retirement of the old server. This header owns flags, the store-dir
# resolution, the on-disk record format, and exit codes.
#
# Store directory resolution, first match wins:
#   1. FM_MEMORY_DIR environment override
#   2. first non-comment non-blank line of gitignored config/memory-dir
#      (under FM_CONFIG_OVERRIDE when set, else $FM_HOME/config)
#   3. $FM_HOME/data/memories
#
# A memory is one markdown file. `remember` writes
# <category>/<slug>.md with frontmatter (category, created, updated, plus
# optional expires and sensitivity) and a `# <topic>` title. Re-writing the
# same category+topic preserves `created:` but replaces the body and optional
# metadata; omitted expires/sensitivity values are not carried forward.
# --expires accepts YYYY-MM-DD; --sensitivity accepts normal or private.
# Every option must precede the topic. `body` comes
# from the remaining arguments joined by spaces, or from stdin when no body
# argument is given. Categories normalize the OpenViking names
# (preference->preferences, entity->entities, event->events); any other value
# must match ^[a-z0-9][a-z0-9-]*$ (or `.` for the store root). The topic is
# slugified to a filename (lowercase, non-alphanumeric runs collapse to `-`).
#
# --task <task-id> links a running-work note to the firstmate task it
# describes (frontmatter `task: <id>`, ^[A-Za-z0-9][A-Za-z0-9._-]*$). The link
# is optional and only meaningful for now/ notes. `complete-task` is the
# mechanical close of that link: bin/fm-teardown.sh calls it once a ship or
# scout task is cleaned up. Every now/ note whose `task:` equals <task-id> and
# that has no `completed:` yet is rewritten in place: the body becomes
# "Erledigt <date> (<task-id>): <outcome>" plus the report path or PR URL, so
# no "running" or "pending" wording survives, and `completed: <date>` is added
# next to `updated:`. Notes without a matching link are never touched, and a
# note is never deleted or moved. No match is a silent success.
#
# `recall` runs BM25 over the store through bin/fm-memory-bm25.mjs and
# prints ranked `score  relpath  title` lines with a snippet; --json prints one
# JSON envelope for programmatic consumers. The index is the disposable cache
# <store>/.index.json owned by the engine; it self-rebuilds whenever the tree
# drifts from the recorded manifest, so recall never answers from stale bytes.
#
# `now` prints now/*.md entries newest updated date first, excluding entries
# whose expires date is before today (local date). --exclude-private also
# excludes sensitivity: private. --max-chars bounds the whole output including
# its omission notice; default FM_MEMORY_NOW_MAX_CHARS, else 6000 (~1.5K tokens).
# Each entry's body is flattened and clipped to 600 characters.
#
# `merge-from` copies missing relative Markdown paths from another store,
# leaves identical files alone, reports differing files without overwriting,
# and rebuilds the index if it copied anything. Conflicts return exit 1 even
# when other files were copied successfully.
#
# `reindex` forces a rebuild, `list` prints store-relative paths, `stats`
# prints the resolved dir, document count, and index freshness, and `dir`
# prints the resolved store path.
#
# Exit codes: 0 success (including zero recall hits); 1 merge conflicts;
# 2 usage error, a node runtime problem, or a missing/unusable store component;
# 3 an invalid category, topic slug, expires date shape, or sensitivity.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
ENGINE="$SCRIPT_DIR/fm-memory-bm25.mjs"

usage() {
  cat >&2 <<'EOF'
Usage:
  fm-memory.sh remember [--category <cat>] [--expires <YYYY-MM-DD>] [--sensitivity normal|private] [--task <task-id>] <topic> [body...]
  fm-memory.sh complete-task <task-id> [--report <path>] [--pr <url>] [--outcome <text>]
  fm-memory.sh recall [--json] [--limit <n>] <query>
  fm-memory.sh now [--max-chars <n>] [--exclude-private]
  fm-memory.sh merge-from <other-store-dir>
  fm-memory.sh list
  fm-memory.sh reindex
  fm-memory.sh stats
  fm-memory.sh dir
EOF
}

die() {
  printf 'memory: %s\n' "$1" >&2
  exit "${2:-2}"
}

first_config_line() {
  local file=$1 line
  [ -f "$file" ] && [ -r "$file" ] && [ ! -L "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|\#*) continue ;;
      *) printf '%s' "$line"; return 0 ;;
    esac
  done < "$file"
  return 1
}

resolve_store_dir() {
  local raw
  raw=${FM_MEMORY_DIR:-}
  if [ -z "$raw" ]; then
    raw=$(first_config_line "$CONFIG/memory-dir") || raw=
  fi
  if [ -n "$raw" ]; then
    printf '%s' "$raw"
  else
    printf '%s' "$FM_HOME/data/memories"
  fi
}

slugify() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-{2,}/-/g'
}

normalize_category() {
  local raw=$1
  case "$raw" in
    preference) raw=preferences ;;
    entity) raw=entities ;;
    event) raw=events ;;
  esac
  printf '%s' "$raw"
}

require_node() {
  command -v node >/dev/null 2>&1 || die "node is required for the BM25 engine"
  [ -f "$ENGINE" ] || die "BM25 engine not found: $ENGINE"
}

cmd_dir() {
  resolve_store_dir
}

cmd_remember() {
  local category=preferences topic='' body='' arg expires='' sensitivity='' task=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --category)
        [ $# -ge 2 ] || die "--category needs a value"
        category=$2
        shift 2
        ;;
      --category=*)
        category=${1#--category=}
        shift
        ;;
      --expires)
        [ $# -ge 2 ] || die "--expires needs a value"
        expires=$2
        shift 2
        ;;
      --expires=*) expires=${1#--expires=}; shift ;;
      --sensitivity)
        [ $# -ge 2 ] || die "--sensitivity needs a value"
        sensitivity=$2
        shift 2
        ;;
      --sensitivity=*) sensitivity=${1#--sensitivity=}; shift ;;
      --task)
        [ $# -ge 2 ] || die "--task needs a value"
        task=$2
        shift 2
        ;;
      --task=*) task=${1#--task=}; shift ;;
      --) shift; break ;;
      -*) die "unknown option: $1" ;;
      *) topic=$1; shift; break ;;
    esac
  done
  if [ -z "$topic" ] && [ $# -gt 0 ]; then
    topic=$1
    shift
  fi
  [ -n "$topic" ] || { usage; die "remember needs a topic"; }
  for arg in "$@"; do
    case "$arg" in
      --category|--category=*|--expires|--expires=*|--sensitivity|--sensitivity=*|--task|--task=*|--from-file|--from-file=*)
        die "unexpected option after the body: $arg; supported form: 'remember [--category <cat>] [--expires <date>] [--sensitivity <level>] <topic> [body...]' with every option before the topic and the body from arguments or stdin (no --from-file)"
        ;;
    esac
  done
  body=$*
  if [ $# -eq 0 ] && [ ! -t 0 ]; then
    body=$(cat)
  fi
  [ -n "$body" ] || die "remember needs a body (arguments or stdin)"

  case "$expires" in
    '') ;;
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) die "invalid --expires date (want YYYY-MM-DD): $expires" 3 ;;
  esac
  case "$sensitivity" in
    ''|normal|private) ;;
    *) die "invalid --sensitivity (want normal or private): $sensitivity" 3 ;;
  esac

  valid_task_id "$task" || die "invalid --task id (want ^[A-Za-z0-9][A-Za-z0-9._-]*\$): $task" 3

  category=$(normalize_category "$category")
  if [ "$category" != "." ]; then
    case "$category" in
      *[!a-z0-9-]*|''|-*) die "invalid category: $category" 3 ;;
    esac
  fi

  local slug
  slug=$(slugify "$topic")
  [ -n "$slug" ] || die "topic has no usable characters: $topic" 3

  local store dir file today created=''
  store=$(resolve_store_dir)
  if [ "$category" = "." ]; then
    dir=$store
  else
    dir=$store/$category
  fi
  mkdir -p "$dir" || die "cannot create $dir"
  file=$dir/$slug.md
  today=$(date +%F)
  if [ -f "$file" ]; then
    created=$(awk '
      NR == 1 { if ($0 != "---") exit; next }
      /^---[[:space:]]*$/ { exit }
      /^created:/ { sub(/^created:[[:space:]]*/, ""); print; exit }
    ' "$file")
  fi
  [ -n "$created" ] || created=$today

  local tmp
  tmp=$(mktemp "$dir/.mem.XXXXXX") || die "mktemp failed"
  {
    printf -- '---\n'
    [ "$category" = "." ] || printf 'category: %s\n' "$category"
    printf 'created: %s\n' "$created"
    printf 'updated: %s\n' "$today"
    [ -z "$expires" ] || printf 'expires: %s\n' "$expires"
    [ -z "$sensitivity" ] || printf 'sensitivity: %s\n' "$sensitivity"
    [ -z "$task" ] || printf 'task: %s\n' "$task"
    printf -- '---\n'
    printf '# %s\n\n' "$topic"
    printf '%s\n' "$body"
  } > "$tmp" || { rm -f "$tmp"; die "write failed for $file"; }
  mv "$tmp" "$file" || { rm -f "$tmp"; die "write failed for $file"; }
  printf '%s\n' "${file#"$store"/}"

  require_node
  node "$ENGINE" build --dir "$store" >/dev/null || die "reindex failed"
}

# An empty id is valid here: it means "no task link".
valid_task_id() {
  case "$1" in
    '') return 0 ;;
    [A-Za-z0-9]*) ;;
    *) return 1 ;;
  esac
  case "$1" in
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

cmd_complete_task() {
  local task='' report='' pr='' outcome=''
  [ $# -gt 0 ] || die "complete-task needs a task id"
  task=$1
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --report) [ $# -ge 2 ] || die "--report needs a value"; report=$2; shift 2 ;;
      --report=*) report=${1#--report=}; shift ;;
      --pr) [ $# -ge 2 ] || die "--pr needs a value"; pr=$2; shift 2 ;;
      --pr=*) pr=${1#--pr=}; shift ;;
      --outcome) [ $# -ge 2 ] || die "--outcome needs a value"; outcome=$2; shift 2 ;;
      --outcome=*) outcome=${1#--outcome=}; shift ;;
      *) die "unknown option: $1" ;;
    esac
  done
  { [ -n "$task" ] && valid_task_id "$task"; } || die "invalid task id: $task" 3
  local store dir today file rewritten=0 tmp text
  store=$(resolve_store_dir)
  dir=$store/now
  [ -d "$dir" ] || return 0
  today=$(date +%F)
  text="Erledigt $today ($task): ${outcome:-Aufgabe abgeschlossen}"
  [ -z "$report" ] || text="$text. Bericht: $report"
  [ -z "$pr" ] || text="$text. PR: $pr"
  for file in "$dir"/*.md; do
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    [ "$(frontmatter_value "$file" task)" = "$task" ] || continue
    [ -z "$(frontmatter_value "$file" completed)" ] || continue
    tmp=$(mktemp "$dir/.mem.XXXXXX") || die "mktemp failed"
    awk -v today="$today" -v text="$text" '
      NR == 1 { print; fm = ($0 == "---"); next }
      fm == 1 && /^---[[:space:]]*$/ { print "completed: " today; print; fm = 2; next }
      fm == 1 && /^updated:/ { print "updated: " today; next }
      fm == 1 { print; next }
      fm == 2 && /^# / && !titled { print; titled = 1; print ""; print text; next }
      fm == 2 && titled { next }
      { print }
    ' "$file" > "$tmp" || { rm -f "$tmp"; die "rewrite failed for $file"; }
    mv "$tmp" "$file" || { rm -f "$tmp"; die "rewrite failed for $file"; }
    printf 'completed: %s\n' "${file#"$store"/}"
    rewritten=$((rewritten + 1))
  done
  if [ "$rewritten" -gt 0 ]; then
    require_node
    node "$ENGINE" build --dir "$store" >/dev/null || die "reindex failed"
  fi
}

cmd_recall() {
  local json_flag='' limit='' query=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json_flag=--json; shift ;;
      --limit)
        [ $# -ge 2 ] || die "--limit needs a value"
        limit=$2
        shift 2
        ;;
      --limit=*) limit=${1#--limit=}; shift ;;
      --) shift; break ;;
      -*) die "unknown option: $1" ;;
      *) query=$1; shift; break ;;
    esac
  done
  if [ -z "$query" ] && [ $# -gt 0 ]; then
    query=$1
    shift
  fi
  [ -n "$query" ] || { usage; die "recall needs a query"; }
  [ $# -eq 0 ] || die "pass the query as one argument"

  require_node
  local store
  store=$(resolve_store_dir)
  [ -d "$store" ] || die "memory store not found: $store"
  local args=(query --dir "$store" --query "$query")
  [ -n "$json_flag" ] && args+=(--json)
  [ -n "$limit" ] && args+=(--limit "$limit")
  node "$ENGINE" "${args[@]}"
}

# Frontmatter value of <key> in <file>, empty when absent.
frontmatter_value() {
  awk -v key="$2" '
    NR == 1 { if ($0 != "---") exit; next }
    /^---[[:space:]]*$/ { exit }
    index($0, key ":") == 1 { sub("^" key ":[[:space:]]*", ""); print; exit }
  ' "$1"
}

# Expiry filters presentation only; never delete a memory during digest reads.
cmd_now() {
  local max_chars=${FM_MEMORY_NOW_MAX_CHARS:-6000} exclude_private=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --max-chars)
        [ $# -ge 2 ] || die "--max-chars needs a value"
        max_chars=$2
        shift 2
        ;;
      --max-chars=*) max_chars=${1#--max-chars=}; shift ;;
      --exclude-private) exclude_private=1; shift ;;
      *) die "unknown option: $1" ;;
    esac
  done
  case "$max_chars" in ''|*[!0-9]*) die "--max-chars must be a whole number" ;; esac
  local store dir today file expires updated sensitivity rows=''
  store=$(resolve_store_dir)
  dir=$store/now
  [ -d "$dir" ] || return 0
  today=$(date +%F)
  for file in "$dir"/*.md; do
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    expires=$(frontmatter_value "$file" expires)
    if [ -n "$expires" ] && [[ "$expires" < "$today" ]]; then
      continue
    fi
    sensitivity=$(frontmatter_value "$file" sensitivity)
    [ "$exclude_private" = 1 ] && [ "$sensitivity" = private ] && continue
    updated=$(frontmatter_value "$file" updated)
    rows+="${updated:-0000-00-00}"$'\t'"${expires:--}"$'\t'"$file"$'\n'
  done
  [ -n "$rows" ] || return 0
  printf '%s' "$rows" | sort -r -t $'\t' -k1,1 | awk -F '\t' -v max="$max_chars" '
    function flush_entry(   line) {
      if (title == "") return
      gsub(/[[:space:]]+/, " ", body)
      sub(/^ /, "", body); sub(/ $/, "", body)
      if (length(body) > 600) body = substr(body, 1, 597) "..."
      line = "- " title (until == "-" ? "" : " (until " until ")") ": " body
      if (used + length(line) + 1 > max) { dropped++; return }
      lines[++count] = line
      used += length(line) + 1
    }
    {
      until = $2; title = ""; body = ""; fm = 0; file = $3
      while ((getline l < file) > 0) {
        if (fm < 2 && l ~ /^---[[:space:]]*$/) { fm++; continue }
        if (fm == 1) continue
        if (title == "" && l ~ /^# /) { title = substr(l, 3); continue }
        body = body " " l
      }
      close(file)
      flush_entry()
    }
    END {
      if (dropped) {
        notice = sprintf("(%d more now/ entries omitted by the size cap)", dropped)
        while (count > 0 && used + length(notice) + 1 > max) {
          used -= length(lines[count--]) + 1
          notice = sprintf("(%d more now/ entries omitted by the size cap)", ++dropped)
        }
      }
      for (i = 1; i <= count; i++) print lines[i]
      if (dropped && used + length(notice) + 1 <= max) print notice
    }
  '
}

# Copies every memory under <other-store-dir> whose relative path is absent
# from this store, leaves identical files alone, and reports a differing file
# as a conflict without touching either side. Reindexes when anything landed.
cmd_merge_from() {
  [ $# -eq 1 ] || die "merge-from takes one store directory"
  local src=${1%/} store rel copied=0 same=0 conflict=0
  [ -d "$src" ] && [ ! -L "$src" ] || die "not a store directory: $src"
  store=$(resolve_store_dir)
  [ "$(cd "$src" && pwd -P)" != "$(mkdir -p "$store" && cd "$store" && pwd -P)" ] \
    || die "merge-from source is this store"
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    if [ ! -e "$store/$rel" ]; then
      mkdir -p "$(dirname "$store/$rel")" || die "cannot create $(dirname "$store/$rel")"
      cp -p "$src/$rel" "$store/$rel" || die "copy failed for $rel"
      printf 'copied: %s\n' "$rel"
      copied=$((copied + 1))
    elif cmp -s "$src/$rel" "$store/$rel"; then
      same=$((same + 1))
    else
      printf 'conflict (kept this store): %s\n' "$rel"
      conflict=$((conflict + 1))
    fi
  done < <(cd "$src" && find . -type f -name '*.md' ! -path '*/.*' | sed 's|^\./||' | sort)
  printf 'merged: copied=%s identical=%s conflict=%s\n' "$copied" "$same" "$conflict"
  if [ "$copied" -gt 0 ]; then
    require_node
    node "$ENGINE" build --dir "$store" >/dev/null || die "reindex failed"
  fi
  [ "$conflict" -eq 0 ] || return 1
}

cmd_list() {
  [ $# -eq 0 ] || die "list takes no arguments"
  local store
  store=$(resolve_store_dir)
  [ -d "$store" ] || die "memory store not found: $store"
  (cd "$store" && find . -type f -name '*.md' ! -path '*/.*' \
    | sed 's|^\./||' | sort) || true
}

cmd_reindex() {
  require_node
  local store
  store=$(resolve_store_dir)
  mkdir -p "$store" || die "cannot create $store"
  node "$ENGINE" build --dir "$store"
}

cmd_stats() {
  local store
  store=$(resolve_store_dir)
  printf 'dir: %s\n' "$store"
  if [ ! -d "$store" ]; then
    printf 'documents: 0\nindex: absent (store missing)\n'
    return 0
  fi
  local count
  count=$(cmd_list | grep -c . || true)
  printf 'documents: %s\n' "${count:-0}"
  if command -v node >/dev/null 2>&1 && [ -f "$store/.index.json" ]; then
    if node "$ENGINE" stale --dir "$store"; then
      printf 'index: stale\n'
    else
      printf 'index: fresh\n'
    fi
  else
    printf 'index: absent\n'
  fi
}

cmd=${1:-}
case "$cmd" in
  ''|-h|--help)
    usage
    [ -n "$cmd" ] || exit 2
    exit 0
    ;;
esac
shift

case "$cmd" in
  dir) cmd_dir "$@" ;;
  remember) cmd_remember "$@" ;;
  complete-task) cmd_complete_task "$@" ;;
  recall) cmd_recall "$@" ;;
  now) cmd_now "$@" ;;
  merge-from) cmd_merge_from "$@" ;;
  list) cmd_list "$@" ;;
  reindex) cmd_reindex "$@" ;;
  stats) cmd_stats "$@" ;;
  *) usage; die "unknown command: $cmd" ;;
esac
