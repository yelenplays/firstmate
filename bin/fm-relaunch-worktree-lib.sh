#!/usr/bin/env bash
# fm-relaunch-worktree-lib.sh - the single owner of which clone a relaunched
# task's recorded worktree belongs to.
#
# Sourced, never executed. A task record names a project clone and a worktree.
# Normally the worktree is a linked worktree of that very clone. It can instead
# be a linked worktree of ANOTHER clone of the same repository - a task carried
# over from a different home, whose slot still hangs off that home's clone -
# and then every check that ties the worktree to the recorded project
# (bin/fm-claude-trust.sh's scope test above all) refuses, so the task cannot
# be relaunched at all.
#
# A relaunch never moves, re-homes, or rewrites a task's local copy, so this
# resolves the mismatch by proof instead: the recorded worktree is relaunched
# exactly as it is when
#   - its own clone's origin is the same repository as the recorded project's
#     origin (fm_relaunch_origin_same_repository), and
#   - for a ship, the worktree is still on the task's recorded branch.
# The clone that actually owns the worktree is then the one a per-worktree
# registration (Claude or agy workspace trust) must name, because both tools
# canonicalize a linked worktree to its own primary checkout. Anything that
# cannot be proven refuses with the concrete reason, and nothing here writes.
#
#   fm_relaunch_worktree_owner <kind> <project> <worktree> <branch>
#       Sets FM_RELAUNCH_WORKTREE_OWNER to the primary checkout that owns
#       <worktree>: <project> itself in the ordinary case, the worktree's own
#       clone when the proof above holds. Returns 1 and sets
#       FM_RELAUNCH_WORKTREE_ERROR otherwise. Call it directly, not in a
#       command substitution, so both results reach the caller. <branch> is
#       required for a ship and ignored for any other kind.
#
#   fm_relaunch_origin_same_repository <url-a> <url-b>
#       0 when both origin URLs name one repository: equal after
#       canonicalization (fm_relaunch_origin_key), or two github.com addresses
#       GitHub resolves to the same repository node - a transferred or renamed
#       repository keeps answering on its old address. Returns 1 and sets
#       FM_RELAUNCH_WORKTREE_ERROR otherwise, including when GitHub cannot be
#       asked.
#
# FM_RELAUNCH_GH_TIMEOUT bounds each GitHub lookup in seconds (default 20).

FM_RELAUNCH_WORKTREE_ERROR=
# shellcheck disable=SC2034 # read by the sourcing caller
FM_RELAUNCH_WORKTREE_OWNER=

_FM_RELAUNCH_WT_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/fm-timeout-lib.sh
declare -F fm_run_timed >/dev/null 2>&1 || . "$_FM_RELAUNCH_WT_LIB_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
declare -F fm_gh_run_timed >/dev/null 2>&1 || . "$_FM_RELAUNCH_WT_LIB_DIR/fm-pr-lib.sh"

# The physical common git dir of a checkout, or nothing.
_fm_relaunch_common_dir() {  # <dir>
  local common
  common=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  [ -n "$common" ] || return 1
  (CDPATH='' cd -P -- "$common" 2>/dev/null && pwd -P)
}

# A comparable key for an origin URL: host/path with the scheme, userinfo,
# default port, trailing slash, and .git suffix removed, and the host lowercased.
# Non-default ports remain part of the key. GitHub paths are case-insensitive,
# so a github.com path is lowercased too; no other forge's path is assumed to
# be. A local path or file: URL keys on its physical location when it exists.
fm_relaunch_origin_key() {  # <url>
  local url=${1-} host path rest scheme authority port default_port
  case "$url" in
    file://*)
      path=${url#file://}
      printf 'file:%s\n' "$(CDPATH='' cd -P -- "$path" 2>/dev/null && pwd -P || printf '%s' "${path%/}")"
      return 0
      ;;
    /*)
      printf 'file:%s\n' "$(CDPATH='' cd -P -- "$url" 2>/dev/null && pwd -P || printf '%s' "${url%/}")"
      return 0
      ;;
    *://*)
      scheme=${url%%://*}
      scheme=$(printf '%s' "$scheme" | tr '[:upper:]' '[:lower:]')
      rest=${url#*://}
      authority=${rest%%/*}
      path=${rest#"$authority"}
      authority=${authority##*@}
      case "$authority" in
        '['*']':*)
          host=${authority%%']'*}']'
          port=${authority#"]"}
          port=${port#:}
          ;;
        '['*']')
          host=$authority
          port=
          ;;
        *:*)
          host=${authority%%:*}
          port=${authority#*:}
          ;;
        *)
          host=$authority
          port=
          ;;
      esac
      case "$scheme" in
        https) default_port=443 ;;
        http) default_port=80 ;;
        ssh) default_port=22 ;;
        git) default_port=9418 ;;
        *) default_port= ;;
      esac
      [ "$port" != "$default_port" ] || port=
      [ -z "$port" ] || host="$host:$port"
      ;;
    *:*)
      host=${url%%:*}
      path=${url#*:}
      host=${host##*@}
      ;;
    *)
      return 1
      ;;
  esac
  [ -n "$host" ] || return 1
  path=/${path#/}
  path=${path%/}
  path=${path%.git}
  host=$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')
  [ "$host" != github.com ] || path=$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]')
  printf '%s%s\n' "$host" "$path"
}

# GitHub's node id for github.com/<owner>/<repo>, following a transfer or rename.
_fm_relaunch_github_node() {  # <owner/repo>
  local node
  node=$(fm_gh_run_timed "${FM_RELAUNCH_GH_TIMEOUT:-20}" gh api "repos/$1" --jq .node_id 2>/dev/null) || return 1
  [ -n "$node" ] && [ "$node" != null ] || return 1
  printf '%s\n' "$node"
}

fm_relaunch_origin_same_repository() {  # <url-a> <url-b>
  local a=${1-} b=${2-} key_a key_b node_a node_b
  FM_RELAUNCH_WORKTREE_ERROR=
  if ! key_a=$(fm_relaunch_origin_key "$a") || ! key_b=$(fm_relaunch_origin_key "$b"); then
    FM_RELAUNCH_WORKTREE_ERROR="origin '$a' or '$b' is not a recognizable repository address"
    return 1
  fi
  [ "$key_a" != "$key_b" ] || return 0
  case "$key_a:$key_b" in
    github.com/*/*:github.com/*/*) ;;
    *)
      FM_RELAUNCH_WORKTREE_ERROR="origin '$a' and origin '$b' are different repositories"
      return 1
      ;;
  esac
  if ! node_a=$(_fm_relaunch_github_node "${key_a#github.com/}") \
     || ! node_b=$(_fm_relaunch_github_node "${key_b#github.com/}"); then
    FM_RELAUNCH_WORKTREE_ERROR="origin '$a' and origin '$b' differ, and GitHub could not be asked whether they are one transferred or renamed repository"
    return 1
  fi
  [ "$node_a" = "$node_b" ] && return 0
  FM_RELAUNCH_WORKTREE_ERROR="origin '$a' and origin '$b' are different GitHub repositories"
  return 1
}

fm_relaunch_worktree_owner() {  # <kind> <project> <worktree> <branch>
  local kind=$1 project=$2 worktree=$3 branch=${4-} proj_common wt_common owner owner_git_dir
  local proj_url wt_url head_branch
  FM_RELAUNCH_WORKTREE_ERROR=
  FM_RELAUNCH_WORKTREE_OWNER=
  [ -n "$project" ] && [ -n "$worktree" ] || {
    FM_RELAUNCH_WORKTREE_ERROR="the task records no project or no worktree to relate"
    return 1
  }
  proj_common=$(_fm_relaunch_common_dir "$project") || {
    FM_RELAUNCH_WORKTREE_ERROR="recorded project '$project' is not a readable git checkout"
    return 1
  }
  wt_common=$(_fm_relaunch_common_dir "$worktree") || {
    FM_RELAUNCH_WORKTREE_ERROR="recorded worktree '$worktree' is not a readable git checkout"
    return 1
  }
  if [ "$proj_common" = "$wt_common" ]; then
    FM_RELAUNCH_WORKTREE_OWNER=$project
    return 0
  fi
  # The worktree hangs off another clone. Its primary checkout is the parent of
  # that clone's common dir in the standard non-bare layout, verified rather
  # than assumed: the candidate's own git dir must be that common dir.
  owner=$(CDPATH='' cd -P -- "$(dirname -- "$wt_common")" 2>/dev/null && pwd -P) || owner=
  owner_git_dir=
  if [ -n "$owner" ]; then
    owner_git_dir=$(git -C "$owner" rev-parse --absolute-git-dir 2>/dev/null) &&
      owner_git_dir=$(CDPATH='' cd -P -- "$owner_git_dir" 2>/dev/null && pwd -P) || owner_git_dir=
  fi
  [ -n "$owner_git_dir" ] && [ "$owner_git_dir" = "$wt_common" ] || {
    FM_RELAUNCH_WORKTREE_ERROR="recorded worktree '$worktree' belongs to a different clone than recorded project '$project', and that clone's own checkout could not be resolved"
    return 1
  }
  proj_url=$(git -C "$project" remote get-url origin 2>/dev/null) || proj_url=
  wt_url=$(git -C "$worktree" remote get-url origin 2>/dev/null) || wt_url=
  [ -n "$proj_url" ] && [ -n "$wt_url" ] || {
    FM_RELAUNCH_WORKTREE_ERROR="recorded worktree '$worktree' belongs to clone '$owner', not recorded project '$project', and one of them has no origin to prove they are the same repository"
    return 1
  }
  fm_relaunch_origin_same_repository "$proj_url" "$wt_url" || {
    FM_RELAUNCH_WORKTREE_ERROR="recorded worktree '$worktree' belongs to clone '$owner', not recorded project '$project': $FM_RELAUNCH_WORKTREE_ERROR"
    return 1
  }
  if [ "$kind" = ship ]; then
    head_branch=$(git -C "$worktree" symbolic-ref -q --short HEAD 2>/dev/null) || head_branch=
    [ -n "$branch" ] && [ "$head_branch" = "$branch" ] || {
      FM_RELAUNCH_WORKTREE_ERROR="recorded worktree '$worktree' belongs to clone '$owner', not recorded project '$project', and it is on '${head_branch:-a detached HEAD}' rather than the task's branch '${branch:-unrecorded}'"
      return 1
    }
  fi
  # shellcheck disable=SC2034 # read by the sourcing caller
  FM_RELAUNCH_WORKTREE_OWNER=$owner
}
