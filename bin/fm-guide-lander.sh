#!/usr/bin/env bash
# fm-guide-lander.sh - collect crew guide drafts for filing into the wikis.
#
# Usage:
#   fm-guide-lander.sh pending
#   fm-guide-lander.sh mark-filed <home> <task-id> <vault-commit>
#
# docs/configuration.md "Wiki context in briefs" owns the operator contract and
# the daily batch; bin/fm-wiki-lib.sh owns the draft header format. This script
# only lists and records drafts; it never writes into a vault.
#
# pending
#   Scans this home and every local secondmate home in data/secondmates.md for
#   data/<task-id>/guide.md drafts that have no data/<task-id>/guide.filed
#   receipt and are not `no guide: <reason>`. Each draft prints one
#   tab-separated row:
#     <home> <task-id> <target> <vault-path> <cloud> <lane>
#   <target> is the header's target as written. <vault-path> and <cloud> come
#   from <wikis-root>/routing/estate.json, never from the draft. Lanes:
#     bulk        cloud `ja` and modus not `pointer`
#     private     cloud `nur-digest` or `nein`, modus `pointer`, or any other
#                 cloud value, so a vault never reaches the bulk lane unless the
#                 estate says `ja`
#     unresolved  target names no estate vault; <vault-path> and <cloud> are `-`
#     invalid     the header does not parse; <target> is `-` and a notice on
#                 stderr names the reason
#   Remote secondmate homes and unreadable local homes are skipped with a
#   notice on stderr. Rows are sorted by home, then task id.
#
# mark-filed <home> <task-id> <vault-commit>
#   Writes data/<task-id>/guide.filed in <home> with the vault commit and a UTC
#   timestamp, so `pending` stops listing the draft. <home> must be this home
#   or a registered local secondmate home; <vault-commit> is a 7-40 character
#   hex commit id. A draft that already has a receipt is left unchanged and
#   reported as already filed. A `no guide:` or invalid draft is refused.
#
# Unconfigured: with no wikis root (bin/fm-wiki-lib.sh fm_wiki_root), both
# commands print `guide-lander: no wikis root configured` on stderr and exit 0.
# Exit 2 for usage, an unreadable estate, a missing jq, or a refused mark-filed.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-wiki-lib.sh
. "$SCRIPT_DIR/fm-wiki-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"

usage() {
  printf 'Usage: fm-guide-lander.sh pending\n       fm-guide-lander.sh mark-filed <home> <task-id> <vault-commit>\n' >&2
}

die() {
  printf 'guide-lander: %s\n' "$1" >&2
  exit 2
}

note() {
  printf 'guide-lander: %s\n' "$1" >&2
}

canonical_dir() {
  (cd "$1" 2>/dev/null && pwd -P)
}

# Prints "<canonical-home><TAB><data-dir>" for this home and every readable
# local secondmate home, deduplicated by canonical path.
homes() {
  local self line reg seen='' home
  self=$(canonical_dir "$FM_HOME") || die "home $FM_HOME is not a directory"
  printf '%s\t%s\n' "$self" "$DATA"
  seen=$'\n'"$self"$'\n'
  reg="$DATA/secondmates.md"
  [ -f "$reg" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    secondmate_registry_parse_line "$line" || continue
    if [ "$SECONDMATE_REGISTRY_REMOTE" -eq 1 ]; then
      note "skipping remote secondmate $SECONDMATE_REGISTRY_ID on $SECONDMATE_REGISTRY_HOST"
      continue
    fi
    home=$(canonical_dir "$SECONDMATE_REGISTRY_HOME") || {
      note "skipping secondmate $SECONDMATE_REGISTRY_ID: home $SECONDMATE_REGISTRY_HOME is unavailable"
      continue
    }
    case "$seen" in *$'\n'"$home"$'\n'*) continue ;; esac
    seen="$seen$home"$'\n'
    printf '%s\t%s\n' "$home" "$home/data"
  done < "$reg"
}

wiki_root() {
  local root
  root=$(fm_wiki_root "$CONFIG") || {
    note 'no wikis root configured'
    exit 0
  }
  command -v jq >/dev/null 2>&1 || die 'jq is required to read the wiki estate'
  jq -e '.vaults | type == "array"' "$root/routing/estate.json" >/dev/null 2>&1 \
    || die "wiki estate $root/routing/estate.json is unreadable"
  printf '%s\n' "$root"
}

lane_for() {  # <cloud> <modus>
  if [ "$2" = pointer ]; then
    printf 'private\n'
  elif [ "$1" = ja ]; then
    printf 'bulk\n'
  else
    printf 'private\n'
  fi
}

cmd_pending() {
  local root estate home data draft dir id row wiki card path digest einstieg cloud modus budget
  root=$(wiki_root) || exit $?
  [ -n "$root" ] || exit 0
  estate="$root/routing/estate.json"
  homes | while IFS=$'\t' read -r home data; do
    for draft in "$data"/*/guide.md; do
      [ -f "$draft" ] && [ ! -L "$draft" ] || continue
      dir=${draft%/guide.md}
      id=${dir##*/}
      [ -e "$dir/guide.filed" ] && continue
      if ! fm_wiki_guide_header "$draft"; then
        note "invalid draft $draft: $FM_WIKI_GUIDE_ERROR"
        printf '%s\t%s\t-\t-\t-\tinvalid\n' "$home" "$id"
        continue
      fi
      [ "$FM_WIKI_GUIDE_KIND" = none ] && continue
      row=$(fm_wiki_estate_row "$estate" "$FM_WIKI_GUIDE_TARGET") || row=
      if [ -z "$row" ]; then
        printf '%s\t%s\t%s\t-\t-\tunresolved\n' "$home" "$id" "$FM_WIKI_GUIDE_TARGET"
        continue
      fi
      # shellcheck disable=SC2034 # digest, einstieg, and budget are unused fields of the row.
      IFS=$'\037' read -r wiki card path digest einstieg cloud modus budget <<<"$row"
      path=$(fm_wiki_expand_path "${path:-${wiki:-$FM_WIKI_GUIDE_TARGET}}" "$root")
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$home" "$id" "$FM_WIKI_GUIDE_TARGET" "$path" \
        "${cloud:--}" "$(lane_for "$cloud" "$modus")"
    done
  done | LC_ALL=C sort -t "$(printf '\t')" -k1,1 -k2,2
}

cmd_mark_filed() {
  local want=$1 id=$2 commit=$3 root home data found='' dir receipt tmp
  case "$id" in ''|.|..|*[!A-Za-z0-9._-]*) die "invalid task id: $id" ;; esac
  [[ "$commit" =~ ^[0-9a-fA-F]{7,40}$ ]] || die "invalid vault commit: $commit"
  root=$(wiki_root) || exit $?
  [ -n "$root" ] || exit 0
  want=$(canonical_dir "$want") || die "home $1 is not a directory"
  while IFS=$'\t' read -r home data; do
    if [ "$home" = "$want" ]; then
      found=$data
      break
    fi
  done < <(homes 2>/dev/null)
  [ -n "$found" ] || die "home $want is neither this home nor a registered local secondmate home"
  dir="$found/$id"
  [ -f "$dir/guide.md" ] && [ ! -L "$dir/guide.md" ] || die "no guide draft at $dir/guide.md"
  receipt="$dir/guide.filed"
  if [ -e "$receipt" ]; then
    printf 'guide-lander: %s/%s already filed\n' "$want" "$id"
    return 0
  fi
  fm_wiki_guide_header "$dir/guide.md" || die "draft $dir/guide.md is invalid: $FM_WIKI_GUIDE_ERROR"
  [ "$FM_WIKI_GUIDE_KIND" = draft ] || die "draft $dir/guide.md is a no-guide note and has nothing to file"
  tmp=$(mktemp "$dir/.guide.filed.XXXXXX") || die "cannot write in $dir"
  printf 'commit: %s\nfiled: %s\n' "$commit" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$tmp" \
    || { rm -f "$tmp"; die "cannot write $receipt"; }
  # A hard link publishes the receipt only if none exists, so two landers
  # racing on one draft cannot both claim it.
  if ! ln "$tmp" "$receipt" 2>/dev/null; then
    rm -f "$tmp"
    [ -e "$receipt" ] || die "cannot write $receipt"
    printf 'guide-lander: %s/%s already filed\n' "$want" "$id"
    return 0
  fi
  rm -f "$tmp"
  printf 'guide-lander: filed %s/%s at %s\n' "$want" "$id" "$commit"
}

case "${1:-}" in
  pending)
    [ "$#" -eq 1 ] || { usage; exit 2; }
    cmd_pending
    ;;
  mark-filed)
    [ "$#" -eq 4 ] || { usage; exit 2; }
    cmd_mark_filed "$2" "$3" "$4"
    ;;
  -h|--help)
    sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'
    ;;
  *)
    usage
    exit 2
    ;;
esac
