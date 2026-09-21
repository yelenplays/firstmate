#!/usr/bin/env bash
# fm-memory-migrate.sh - export an OpenViking workspace into the plain-markdown
# memory store, proving nothing is lost.
#
# Usage:
#   fm-memory-migrate.sh migrate [--source <dir>] [--dest <dir>]
#       [--archive <dir>] [--memories-dir <dir>] [--dry-run]
#   fm-memory-migrate.sh verify  [--dest <dir>] [--manifest <file>]
#
# docs/memory.md owns the operator contract and rollback story. This header
# owns flags, the source-discovery order, the manifest format, and exit codes.
#
# Source: the OpenViking data workspace, default $FM_OV_HOME/data with
# FM_OV_HOME defaulting to ~/.openviking. The memories tree is located by, in
# order: --memories-dir, <source>/user/default/memories, <source>/memories,
# <source>/data/user/default/memories, then the deepest-scoring directory
# named "memories" found within six levels (the one holding the most *.md
# files). Memories are copied into <dest> (default: fm-memory.sh's resolved
# store dir) preserving their relative layout, so preferences/x.md lands at
# <dest>/preferences/x.md.
#
# Every other *.md file under the source - sessions, wiki-layer, resources,
# skills, peers, privacy - is copied under <archive> (default
# $FM_HOME/data/memory-archive) preserving its source-relative path, except
# OpenViking internals (_system/, vectordb/, logs/) and dot-directories, which
# are skipped. Nothing outside *.md is exported; the vector index and queue
# are deliberately left behind.
#
# The migration never writes to or deletes from the source, and never deletes
# from the destination; re-running refreshes changed files and re-verifies.
# Each run writes <dest>/.migration/manifest-<utc>.txt: one row per exported
# file as "<src-rel>\t<sha256>\t<dest-rel>", plus a header. `verify`
# recomputes every destination hash in the newest (or --manifest) manifest and
# reports verified/missing/mismatch counts; the migrate run performs the same
# verification before reporting success.
#
# Exit codes: 0 success; 2 usage; 3 source or memories tree not found;
# 4 verification failed (missing or mismatched destination files).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
OV_HOME="${FM_OV_HOME:-$HOME/.openviking}"
work=

cleanup() {
  [ -n "${work:-}" ] && rm -rf -- "$work"
}
trap cleanup EXIT

usage() {
  cat >&2 <<'EOF'
Usage:
  fm-memory-migrate.sh migrate [--source <dir>] [--dest <dir>]
      [--archive <dir>] [--memories-dir <dir>] [--dry-run]
  fm-memory-migrate.sh verify  [--dest <dir>] [--manifest <file>]
EOF
}

die() {
  printf 'memory-migrate: %s\n' "$1" >&2
  exit "${2:-2}"
}

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

resolve_dest() {
  local raw=${FM_MEMORY_DIR:-}
  if [ -n "$raw" ]; then
    printf '%s' "$raw"
  else
    printf '%s' "$FM_HOME/data/memories"
  fi
}

find_memories_dir() {
  local src=$1 cand best='' best_n=-1 rel
  for rel in user/default/memories memories data/user/default/memories; do
    if [ -d "$src/$rel" ]; then
      printf '%s' "$src/$rel"
      return 0
    fi
  done
  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    local n
    n=$(find "$cand" -type f -name '*.md' | wc -l | tr -d ' ')
    if [ "$n" -gt "$best_n" ]; then
      best=$cand
      best_n=$n
    fi
  done <<EOF
$(find "$src" -maxdepth 6 -type d -name memories 2>/dev/null | sort)
EOF
  if [ -n "$best" ] && [ "$best_n" -gt 0 ]; then
    printf '%s' "$best"
    return 0
  fi
  return 1
}

is_internal_rel() {
  case "/$1/" in
    */_system/*|*/vectordb/*|*/logs/*|*/.*/*) return 0 ;;
  esac
  return 1
}

cmd_migrate() {
  local source="$OV_HOME/data" dest='' archive='' memories_dir='' dry_run=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --source) [ $# -ge 2 ] || die "--source needs a value"; source=$2; shift 2 ;;
      --dest) [ $# -ge 2 ] || die "--dest needs a value"; dest=$2; shift 2 ;;
      --archive) [ $# -ge 2 ] || die "--archive needs a value"; archive=$2; shift 2 ;;
      --memories-dir) [ $# -ge 2 ] || die "--memories-dir needs a value"; memories_dir=$2; shift 2 ;;
      --dry-run) dry_run=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) usage; die "unknown option: $1" ;;
    esac
  done
  [ -n "$dest" ] || dest=$(resolve_dest)
  [ -n "$archive" ] || archive=$FM_HOME/data/memory-archive
  [ -d "$source" ] || die "source not found: $source" 3

  if [ -z "$memories_dir" ]; then
    memories_dir=$(find_memories_dir "$source") \
      || die "no memories tree under $source; pass --memories-dir" 3
  fi
  [ -d "$memories_dir" ] || die "memories dir not found: $memories_dir" 3
  local memories_rel=${memories_dir#"$source"/}

  local manifest
  work=$(mktemp -d "${TMPDIR:-/tmp}/fm-mem-migrate.XXXXXX") || die "mktemp failed"

  # Plan: memories -> dest (relative to memories dir), other markdown ->
  # archive (relative to source root). Findings are relative paths so the
  # dot-component exclusion cannot trip on a dot-directory above the roots.
  : > "$work/plan"
  local count_mem=0 count_arc=0
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    rel=${rel#./}
    printf '%s\t%s\t%s\n' "$memories_dir/$rel" "$rel" "$dest/$rel" >> "$work/plan"
    count_mem=$((count_mem + 1))
  done <<EOF
$(cd "$memories_dir" && find . -type f -name '*.md' ! -path '*/.*' | sort)
EOF
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    rel=${rel#./}
    case "$rel" in "${memories_rel}"/*) continue ;; esac
    is_internal_rel "$rel" && continue
    printf '%s\t%s\t%s\n' "$source/$rel" "$rel" "$archive/$rel" >> "$work/plan"
    count_arc=$((count_arc + 1))
  done <<EOF
$(cd "$source" && find . -type f -name '*.md' ! -path '*/.*' | sort)
EOF

  printf 'source: %s\nmemories: %s (%s files)\ndest: %s\narchive: %s (%s files)\n' \
    "$source" "$memories_dir" "$count_mem" "$dest" "$archive" "$count_arc"
  [ "$count_mem" -gt 0 ] || die "memories tree holds no markdown: $memories_dir" 3
  if [ "$dry_run" -eq 1 ]; then
    printf 'dry-run: no files written\n'
    return 0
  fi

  # Copy, then record the manifest.
  manifest=$dest/.migration/manifest-$(date -u +%Y%m%dT%H%M%SZ).txt
  mkdir -p "$dest/.migration" || die "cannot create $dest/.migration"
  {
    printf '# fm-memory-migrate manifest\n'
    printf '# source: %s\n# memories-dir: %s\n# dest: %s\n# archive: %s\n' \
      "$source" "$memories_dir" "$dest" "$archive"
    printf '# at: %s\n' "$(date -u +%FT%TZ)"
  } > "$work/manifest.head"
  : > "$work/manifest.rows"

  local fails=0
  while IFS=$'\t' read -r src_f rel dst_f; do
    [ -n "$src_f" ] || continue
    local src_sum dst_dir dst_sum
    src_sum=$(sha256_file "$src_f")
    dst_dir=$(dirname "$dst_f")
    mkdir -p "$dst_dir" || { printf 'error: cannot create %s\n' "$dst_dir" >&2; fails=$((fails + 1)); continue; }
    cp -p "$src_f" "$dst_f" || { printf 'error: copy failed %s\n' "$src_f" >&2; fails=$((fails + 1)); continue; }
    dst_sum=$(sha256_file "$dst_f")
    printf '%s\t%s\t%s\n' "$rel" "$src_sum" "$dst_f" >> "$work/manifest.rows"
    if [ "$src_sum" != "$dst_sum" ]; then
      printf 'error: hash mismatch after copy: %s\n' "$dst_f" >&2
      fails=$((fails + 1))
    fi
  done < "$work/plan"

  cat "$work/manifest.head" > "$manifest"
  cat "$work/manifest.rows" >> "$manifest"
  printf 'manifest: %s\n' "$manifest"

  [ "$fails" -eq 0 ] || die "$fails file(s) failed to copy" 4
  verify_manifest "$manifest" || exit 4

  printf 'migrated: %s memories, %s archived; all hashes verified\n' "$count_mem" "$count_arc"

  if [ -x "$SCRIPT_DIR/fm-memory.sh" ] && command -v node >/dev/null 2>&1; then
    FM_MEMORY_DIR=$dest "$SCRIPT_DIR/fm-memory.sh" reindex >/dev/null 2>&1 \
      || printf 'warning: reindex failed; run fm-memory.sh reindex\n' >&2
  fi
}

verify_manifest() {
  local manifest=$1 total=0 ok=0 missing=0 mismatch=0 rel sum dst cur
  [ -f "$manifest" ] || die "manifest not found: $manifest" 2
  while IFS=$'\t' read -r rel sum dst; do
    case "$rel" in ''|\#*) continue ;; esac
    total=$((total + 1))
    if [ ! -f "$dst" ]; then
      missing=$((missing + 1))
      printf 'missing: %s\n' "$dst" >&2
      continue
    fi
    cur=$(sha256_file "$dst")
    if [ "$cur" = "$sum" ]; then
      ok=$((ok + 1))
    else
      mismatch=$((mismatch + 1))
      printf 'mismatch: %s\n' "$dst" >&2
    fi
  done < "$manifest"
  printf 'verify: %s/%s verified' "$ok" "$total"
  [ "$missing" -eq 0 ] || printf ', %s missing' "$missing"
  [ "$mismatch" -eq 0 ] || printf ', %s mismatched' "$mismatch"
  printf '\n'
  [ "$total" -gt 0 ] && [ "$ok" -eq "$total" ]
}

cmd_verify() {
  local dest='' manifest=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --dest) [ $# -ge 2 ] || die "--dest needs a value"; dest=$2; shift 2 ;;
      --manifest) [ $# -ge 2 ] || die "--manifest needs a value"; manifest=$2; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) usage; die "unknown option: $1" ;;
    esac
  done
  if [ -z "$manifest" ]; then
    [ -n "$dest" ] || dest=$(resolve_dest)
    manifest=$(find "$dest/.migration" -name 'manifest-*.txt' 2>/dev/null | sort | tail -n1)
    [ -n "$manifest" ] || die "no manifest under $dest/.migration" 2
  fi
  verify_manifest "$manifest"
}

cmd=${1:-migrate}
case "$cmd" in
  -h|--help) usage; exit 0 ;;
  migrate|verify) ;;
  *) usage; die "unknown command: $cmd" ;;
esac
shift
case "$cmd" in
  migrate) cmd_migrate "$@" ;;
  verify) cmd_verify "$@" ;;
esac
