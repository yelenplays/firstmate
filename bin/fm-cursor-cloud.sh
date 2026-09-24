#!/usr/bin/env bash
# Opt-in pilot: dispatch one ship task to a Cursor cloud agent and supervise it
# through Cursor's official Cloud Agents API (https://api.cursor.com/v1), so the
# work keeps running while this machine sleeps.
#
# Usage:
#   fm-cursor-cloud.sh eligible <project>
#   fm-cursor-cloud.sh dispatch <task-id> <project> --prompt-file <file>
#                      [--ref <branch-or-sha>] [--model <model-id>] [--dry-run]
#   fm-cursor-cloud.sh status <task-id>
#   fm-cursor-cloud.sh pr <task-id>
#   fm-cursor-cloud.sh cancel <task-id>
#   fm-cursor-cloud.sh poll <task-id>
#   fm-cursor-cloud.sh cleanup <task-id> [--discard]
#
# OPT-IN ONLY. Nothing in firstmate routes work here; only an explicit dispatch
# call does. It is not an fm-spawn harness or runtime backend: there is no local
# endpoint, worktree, status log, or state/<id>.meta.
#
# BOUNDARY (enforced here, before any request leaves this machine; every check
# fails closed, and a dry run applies the same checks):
#   - <project> has a row in data/projects.md and its registered mode is not
#     local-only;
#   - its clone projects/<project> is a git repository whose origin is a
#     github.com repository;
#   - it is no wiki vault: the clone carries no vault scaffold (_meta/pruefe.sh
#     or _meta/einstieg.sh), and, when a wikis root is configured
#     (bin/fm-wiki-lib.sh fm_wiki_root), no vault in its routing/estate.json names
#     that repository, that project, or that path; a configured but unreadable
#     estate refuses;
#   - GitHub reports the repository's visibility as public, so private projects
#     and cloud: nein material never reach a vendor VM;
#   - the prompt file names neither this home's path nor the wikis root, since a
#     cloud VM cannot read either and the reference would only leak local layout.
# Exit codes: 0 ok, 2 usage, 3 boundary refusal, 4 missing credential, 1 other.
#
# CREDENTIAL. The API key is read from CURSOR_API_KEY in the environment, else
# from a CURSOR_API_KEY=<key> line in $FM_HOME/.env (parsed, never sourced). This
# script never creates, prints, or stores a key; the key reaches curl on stdin,
# never on its command line. Without one, every live call stops with the exact
# step the captain must take. A dry run needs no key.
#
# RECORDS. dispatch writes state/<id>.cloud (mode 0600, key=value: provider,
# project, repo, ref, agent_id, run_id, agent_url, created) and a watcher check
# state/<id>.check.sh that runs `poll <id>`, bound through fm-check-register.sh.
# poll prints one line only when a new outcome appears - a pull request URL, a
# terminal run status (FINISHED, ERROR, CANCELLED, EXPIRED), or a poll error -
# and remembers what it reported in state/<id>.cloud-notified. fm-spawn refuses
# a task id that has a state/<id>.cloud record.
#
# CLEANUP archives the Cursor agent (reversible; the pushed branch and PR stay
# on GitHub), retires the watcher check, and removes the local records. It
# refuses while the run is still active, and refuses when the agent pushed work
# whose pull request is not merged unless --discard is passed, which needs the
# captain's explicit discard authority exactly like fm-teardown.sh --force.
# Landing a cloud PR follows the ordinary merge authority; this pilot records no
# state/<id>.meta, so the PR is merged on the captain's explicit word.
#
# Environment: FM_CURSOR_API_BASE overrides the API base URL (tests only).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
API_BASE="${FM_CURSOR_API_BASE:-https://api.cursor.com}"
API_BASE=${API_BASE%/}

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wiki-lib.sh
. "$SCRIPT_DIR/fm-wiki-lib.sh"

usage() {
  sed -n '5,13p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

die() { echo "error: $*" >&2; exit 1; }
refuse() { echo "REFUSED: $*" >&2; exit 3; }

need_tools() {
  local t
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || die "$t is required but not installed"
  done
}

# --- boundary ---------------------------------------------------------------

# Sets ELIGIBLE_REPO_URL (https://github.com/<owner>/<repo>), ELIGIBLE_SLUG,
# ELIGIBLE_CLONE; refuses (exit 3) on any failed check.
check_eligible() {
  local name=$1 reg="$DATA/projects.md" mode origin slug clone real root estate
  local configured_root=0 visibility
  case "$name" in
    ''|*/*|.*|-*) refuse "project name '$name' is not a registry name" ;;
  esac
  [ -f "$reg" ] || refuse "no project registry at $reg"
  awk -v n="$name" '$1 == "-" && $2 == n { found = 1 } END { exit !found }' "$reg" \
    || refuse "project '$name' is not registered in data/projects.md"
  mode=$(FM_DATA_OVERRIDE="$DATA" "$SCRIPT_DIR/fm-project-mode.sh" --raw "$name" 2>/dev/null) \
    || refuse "project '$name' registry mode is unreadable"
  mode=${mode%% *}
  [ "$mode" != local-only ] || refuse "project '$name' is local-only; its work never leaves this machine"

  clone="$PROJECTS/$name"
  [ -d "$clone" ] && [ ! -L "$clone" ] || refuse "project '$name' has no clone at $clone"
  git -C "$clone" rev-parse --git-dir >/dev/null 2>&1 || refuse "$clone is not a git repository"
  origin=$(git -C "$clone" remote get-url origin 2>/dev/null) || refuse "project '$name' has no origin remote"
  case "$origin" in
    https://github.com/*) slug=${origin#https://github.com/} ;;
    ssh://git@github.com/*) slug=${origin#ssh://git@github.com/} ;;
    git@github.com:*) slug=${origin#git@github.com:} ;;
    *) refuse "project '$name' origin is not a github.com repository" ;;
  esac
  slug=${slug%.git}
  slug=${slug%/}
  printf '%s' "$slug" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' \
    || refuse "project '$name' origin is not a plain github.com/<owner>/<repo> URL"

  if [ -e "$clone/_meta/pruefe.sh" ] || [ -e "$clone/_meta/einstieg.sh" ]; then
    refuse "project '$name' is a wiki vault (vault scaffold present)"
  fi
  if [ -n "${FM_WIKIS_ROOT:-}" ] || [ -f "$CONFIG/wikis-root" ]; then
    configured_root=1
  fi
  if root=$(fm_wiki_root "$CONFIG"); then
    estate="$root/routing/estate.json"
    need_tools jq
    jq -e '.vaults | type == "array"' "$estate" >/dev/null 2>&1 \
      || refuse "wiki estate $estate is unreadable, so '$name' cannot be proven not to be a vault"
    real=$(cd -P -- "$clone" && pwd -P)
    if jq -e --arg slug "$slug" --arg name "$name" --arg real "$real" --arg home "$HOME" '
        def lc: ascii_downcase;
        def expand: if startswith("~/") then $home + .[1:] else . end;
        any(.vaults[];
          ((.repo // "") | lc) == ($slug | lc)
          or ((.wiki // "") | lc) == ($name | lc)
          or ((.path // "") | expand | rtrimstr("/")) == $real)
      ' "$estate" >/dev/null 2>&1; then
      refuse "project '$name' is a wiki vault listed in $estate"
    fi
  elif [ "$configured_root" -eq 1 ]; then
    refuse "a wikis root is configured but its routing/estate.json is unavailable, so '$name' cannot be proven not to be a vault"
  fi

  need_tools gh
  visibility=$(gh api "repos/$slug" --jq .visibility 2>/dev/null) \
    || refuse "GitHub visibility of $slug could not be read"
  [ "$visibility" = public ] || refuse "$slug is not public (visibility: ${visibility:-unknown})"

  ELIGIBLE_REPO_URL="https://github.com/$slug"
  ELIGIBLE_SLUG=$slug
  ELIGIBLE_CLONE=$clone
}

# --- credential and API -----------------------------------------------------

API_KEY=
find_key() {  # sets API_KEY; returns 1 when absent, 2 when malformed.
  local line
  API_KEY=${CURSOR_API_KEY:-}
  if [ -z "$API_KEY" ] && [ -f "$FM_HOME/.env" ]; then
    line=$(grep -E '^[[:space:]]*(export[[:space:]]+)?CURSOR_API_KEY=' "$FM_HOME/.env" | tail -1)
    line=${line#*=}
    line=${line#\"}; line=${line%\"}
    line=${line#\'}; line=${line%\'}
    API_KEY=$line
  fi
  case "$API_KEY" in *[[:space:]\"\\]*) API_KEY=; return 2 ;; esac
  [ -n "$API_KEY" ]
}

load_key() {
  local rc=0
  find_key || rc=$?
  [ "$rc" -ne 2 ] || die "CURSOR_API_KEY contains whitespace or quotes; fix the $FM_HOME/.env line"
  if [ "$rc" -ne 0 ]; then
    cat >&2 <<EOF
MISSING_CREDENTIAL: no Cursor API key is available to this home.
The captain must:
  1. Create a user API key at https://cursor.com/dashboard/api (Cursor Dashboard -> API Keys).
  2. Add the line CURSOR_API_KEY=<key> to $FM_HOME/.env (gitignored).
  3. Make sure the Cursor GitHub app can access the target repository (https://cursor.com/dashboard -> Integrations -> GitHub).
EOF
    exit 4
  fi
}

# api <METHOD> <path> [<json-body-file>]; sets API_CODE and API_BODY.
API_CODE=
API_BODY=
api() {
  local method=$1 path=$2 body=${3:-} out code
  need_tools curl
  out=$(mktemp "${TMPDIR:-/tmp}/fm-cursor-cloud.XXXXXX") || die "cannot create a temporary file"
  local -a args=(-sS -m 12 -o "$out" -w '%{http_code}' -X "$method"
    -H 'Accept: application/json' --config -)
  if [ -n "$body" ]; then
    args+=(-H 'Content-Type: application/json' --data-binary "@$body")
  fi
  code=$(printf 'user = "%s:"\n' "$API_KEY" | curl "${args[@]}" "$API_BASE$path" 2>/dev/null) || code=000
  API_CODE=$code
  API_BODY=$(cat "$out")
  rm -f -- "$out"
}

api_ok() { case "$API_CODE" in 2??) return 0 ;; esac; return 1; }

api_error() {  # <what>
  local msg
  msg=$(printf '%s' "$API_BODY" | jq -r '.error.message // .message // .error // empty' 2>/dev/null | head -1)
  echo "error: $1 failed (HTTP $API_CODE)${msg:+: $msg}" >&2
  if [ "$API_CODE" = 401 ] || [ "$API_CODE" = 403 ]; then
    echo "The Cursor API key was rejected; the captain must replace CURSOR_API_KEY in $FM_HOME/.env with a valid key from https://cursor.com/dashboard/api." >&2
    exit 4
  fi
  exit 1
}

# --- records ----------------------------------------------------------------

valid_id() {
  fm_task_id_creation_valid "$1" || { echo "error: invalid task id" >&2; exit 2; }
}

record_path() { printf '%s/%s.cloud' "$STATE" "$1"; }

record_get() {  # <id> <key>
  local rec
  rec=$(record_path "$1")
  grep "^$2=" "$rec" 2>/dev/null | tail -1 | cut -d= -f2-
}

record_valid() {  # <id>; sets REC_*, returns 1 when the record is unusable.
  local rec
  rec=$(record_path "$1")
  [ -f "$rec" ] && [ ! -L "$rec" ] || return 1
  REC_AGENT=$(record_get "$1" agent_id)
  REC_RUN=$(record_get "$1" run_id)
  REC_REPO=$(record_get "$1" repo)
  REC_URL=$(record_get "$1" agent_url)
  printf '%s' "$REC_AGENT" | grep -Eq '^bc-[A-Za-z0-9-]+$'
}

load_record() {  # <id>
  record_valid "$1" || die "task $1 has no valid Cursor cloud record at $(record_path "$1")"
}

# Reads the agent and its latest run; sets RUN_STATUS AGENT_STATUS RUN_ID
# BRANCH PR_URL RESULT.
read_live() {  # <id>
  local run
  api GET "/v1/agents/$REC_AGENT"
  api_ok || return 1
  AGENT_STATUS=$(printf '%s' "$API_BODY" | jq -r '.status // empty')
  RUN_ID=$(printf '%s' "$API_BODY" | jq -r '.latestRunId // empty')
  [ -n "$RUN_ID" ] || RUN_ID=$REC_RUN
  printf '%s' "$RUN_ID" | grep -Eq '^run-[A-Za-z0-9-]+$' || { API_CODE=invalid-run; return 1; }
  api GET "/v1/agents/$REC_AGENT/runs/$RUN_ID"
  api_ok || return 1
  run=$API_BODY
  RUN_STATUS=$(printf '%s' "$run" | jq -r '.status // empty')
  BRANCH=$(printf '%s' "$run" | jq -r '[.git.branches[]? | .branch // empty] | first // empty')
  PR_URL=$(printf '%s' "$run" | jq -r '[.git.branches[]? | .prUrl // empty] | first // empty')
  RESULT=$(printf '%s' "$run" | jq -r '.result // empty')
  return 0
}

run_terminal() {
  case "$1" in FINISHED|ERROR|CANCELLED|EXPIRED) return 0 ;; esac
  return 1
}

# --- commands ---------------------------------------------------------------

PREAMBLE='You are working on a firstmate ship task in the GitHub repository @REPO@, starting from @REF@.
Make the change described below on your own new branch and open a pull request for it.
Never push to the default branch and never merge anything.
Keep the change inside the task; note unrelated problems in the pull request description instead of fixing them.
Run the repository'"'"'s own tests and linters where they exist, and add behavioral tests where an executable contract exists.
Never add an agent name as a commit co-author.
The pull request description must say what changed, why, and how it was verified.

Task:
'

cmd_dispatch() {
  local id=${1-} name=${2-} prompt_file='' ref='' model='' dry=0 body text root
  [ -n "$id" ] && [ -n "$name" ] || usage
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --prompt-file) prompt_file=${2-}; shift 2 || usage ;;
      --ref) ref=${2-}; shift 2 || usage ;;
      --model) model=${2-}; shift 2 || usage ;;
      --dry-run) dry=1; shift ;;
      *) usage ;;
    esac
  done
  valid_id "$id"
  [ -n "$prompt_file" ] && [ -f "$prompt_file" ] && [ -s "$prompt_file" ] \
    || die "--prompt-file must name a non-empty file"
  need_tools jq git
  if [ -e "$STATE/$id.meta" ] || [ -L "$STATE/$id.meta" ]; then
    refuse "task $id already has a local task record (state/$id.meta)"
  fi
  if [ -e "$(record_path "$id")" ] || [ -L "$(record_path "$id")" ]; then
    refuse "task $id is already dispatched to a Cursor cloud agent"
  fi
  if [ -e "$STATE/$id.check.sh" ] || [ -L "$STATE/$id.check.sh" ]; then
    refuse "task $id already has a watcher check (state/$id.check.sh)"
  fi

  check_eligible "$name"

  if grep -qF -- "$FM_HOME" "$prompt_file"; then
    refuse "the prompt names this home's local path; a cloud agent cannot read it"
  fi
  if root=$(fm_wiki_root "$CONFIG") && grep -qF -- "$root" "$prompt_file"; then
    refuse "the prompt names the wikis root; wiki content never goes to a cloud agent"
  fi

  if [ -z "$ref" ]; then
    ref=$(git -C "$ELIGIBLE_CLONE" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)
    ref=${ref#origin/}
    [ -n "$ref" ] || die "cannot resolve the default branch of $ELIGIBLE_SLUG; pass --ref"
  fi
  case "$ref" in -*|*[[:space:]]*) die "invalid --ref" ;; esac

  text=${PREAMBLE//@REPO@/$ELIGIBLE_REPO_URL}
  text=${text//@REF@/$ref}$(cat -- "$prompt_file")
  body=$(mktemp "${TMPDIR:-/tmp}/fm-cursor-cloud-body.XXXXXX") || die "cannot create a temporary file"
  # shellcheck disable=SC2064 # expand now: the path is fixed for this process.
  trap "rm -f -- '$body'" EXIT
  jq -n --arg text "$text" --arg url "$ELIGIBLE_REPO_URL" --arg ref "$ref" \
    --arg name "fm $id" --arg model "$model" '
    {prompt: {text: $text},
     repos: [{url: $url, startingRef: $ref}],
     name: $name,
     autoCreatePR: true}
    + (if $model == "" then {} else {model: {id: $model}} end)' > "$body" \
    || die "could not build the request"

  if [ "$dry" -eq 1 ]; then
    printf 'DRY RUN: eligible %s (%s); would POST %s/v1/agents with:\n' \
      "$name" "$ELIGIBLE_REPO_URL" "$API_BASE"
    jq . "$body"
    printf 'DRY RUN: would write state/%s.cloud and register state/%s.check.sh\n' "$id" "$id"
    return 0
  fi

  load_key
  api POST /v1/agents "$body"
  api_ok || api_error "creating the Cursor cloud agent"
  local agent run url created rec tmp check lost=0
  agent=$(printf '%s' "$API_BODY" | jq -r '.agent.id // empty')
  run=$(printf '%s' "$API_BODY" | jq -r '.run.id // .agent.latestRunId // empty')
  url=$(printf '%s' "$API_BODY" | jq -r '.agent.url // empty')
  created=$(printf '%s' "$API_BODY" | jq -r '.agent.createdAt // empty')
  printf '%s' "$agent" | grep -Eq '^bc-[A-Za-z0-9-]+$' \
    || die "Cursor accepted the request but returned no agent id; check https://cursor.com/agents before retrying"

  rec=$(record_path "$id")
  umask 077
  tmp=$(mktemp "$STATE/.fm-cursor-cloud.XXXXXX") \
    || die "agent $agent ($url) is running but its record could not be written; cancel it or record it by hand"
  {
    printf 'provider=cursor\n'
    printf 'project=%s\n' "$name"
    printf 'repo=%s\n' "$ELIGIBLE_REPO_URL"
    printf 'ref=%s\n' "$ref"
    printf 'agent_id=%s\n' "$agent"
    printf 'run_id=%s\n' "$run"
    printf 'agent_url=%s\n' "$url"
    printf 'created=%s\n' "$created"
  } > "$tmp" || lost=1
  if [ "${lost:-0}" -eq 1 ] || ! mv -f -- "$tmp" "$rec"; then
    rm -f -- "$tmp"
    die "agent $agent ($url) is running but its record could not be written; cancel it or record it by hand"
  fi

  check="$STATE/$id.check.sh"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'FM_HOME=%q exec %q poll %q\n' "$FM_HOME" "$SCRIPT_DIR/fm-cursor-cloud.sh" "$id"
  } > "$check" || lost=1
  if [ "${lost:-0}" -eq 1 ] || ! chmod 0700 "$check" \
    || ! FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-check-register.sh" "$id" >/dev/null; then
    die "agent $agent is running and recorded, but its watcher check could not be registered; supervise it with '$0 status $id'"
  fi
  printf 'dispatched: %s agent=%s run=%s url=%s\n' "$id" "$agent" "$run" "$url"
}

cmd_status() {
  local id=${1-}
  [ -n "$id" ] || usage
  valid_id "$id"
  need_tools jq
  load_record "$id"
  load_key
  read_live "$id" || api_error "reading agent $REC_AGENT"
  printf 'task: %s\nrepo: %s\nagent: %s (%s)\nrun: %s %s\n' \
    "$id" "$REC_REPO" "$REC_AGENT" "${AGENT_STATUS:-unknown}" "$RUN_ID" "${RUN_STATUS:-unknown}"
  printf 'branch: %s\npr: %s\nurl: %s\n' "${BRANCH:-none}" "${PR_URL:-none}" "$REC_URL"
  [ -z "$RESULT" ] || printf 'result: %s\n' "$RESULT"
}

cmd_pr() {
  local id=${1-}
  [ -n "$id" ] || usage
  valid_id "$id"
  need_tools jq
  load_record "$id"
  load_key
  read_live "$id" || api_error "reading agent $REC_AGENT"
  [ -n "$PR_URL" ] || { echo "no pull request yet (run ${RUN_STATUS:-unknown})" >&2; exit 1; }
  printf '%s\n' "$PR_URL"
}

cmd_cancel() {
  local id=${1-}
  [ -n "$id" ] || usage
  valid_id "$id"
  need_tools jq
  load_record "$id"
  load_key
  read_live "$id" || api_error "reading agent $REC_AGENT"
  if run_terminal "$RUN_STATUS"; then
    printf 'already ended: %s run %s is %s\n' "$id" "$RUN_ID" "$RUN_STATUS"
    return 0
  fi
  api POST "/v1/agents/$REC_AGENT/runs/$RUN_ID/cancel"
  api_ok || api_error "cancelling run $RUN_ID"
  printf 'cancelled: %s run %s\n' "$id" "$RUN_ID"
}

# Watcher check body: silent unless there is a new outcome to report.
cmd_poll() {
  local id=${1-} notified line='' prev=''
  fm_task_id_creation_valid "$id" || exit 0
  [ -f "$(record_path "$id")" ] || exit 0
  notified="$STATE/$id.cloud-notified"
  [ -f "$notified" ] && prev=$(cat "$notified")
  if ! command -v jq >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
    line="cursor-cloud $id poll-error tools-missing"
  elif ! record_valid "$id"; then
    line="cursor-cloud $id poll-error record-invalid"
  elif ! find_key; then
    line="cursor-cloud $id poll-error missing-credential"
  elif ! read_live "$id"; then
    line="cursor-cloud $id poll-error http-$API_CODE"
  elif run_terminal "$RUN_STATUS"; then
    line="cursor-cloud $id $RUN_STATUS${PR_URL:+ pr=$PR_URL}"
  elif [ -n "$PR_URL" ]; then
    line="cursor-cloud $id pr-opened pr=$PR_URL"
  fi
  [ -n "$line" ] && [ "$line" != "$prev" ] || exit 0
  printf '%s\n' "$line" > "$notified" 2>/dev/null || true
  printf '%s\n' "$line"
}

cmd_cleanup() {
  local id=${1-} discard=0 pr_state
  [ -n "$id" ] || usage
  case "$#:${2-}" in
    1:) ;;
    2:--discard) discard=1 ;;
    *) usage ;;
  esac
  valid_id "$id"
  need_tools jq
  load_record "$id"
  load_key
  read_live "$id" || api_error "reading agent $REC_AGENT"
  run_terminal "$RUN_STATUS" \
    || refuse "task $id run $RUN_ID is still ${RUN_STATUS:-active}; cancel it first"
  if [ -n "$PR_URL" ]; then
    need_tools gh
    pr_state=$(gh pr view "$PR_URL" --json state --jq .state 2>/dev/null) || pr_state=unknown
    if [ "$pr_state" != MERGED ] && [ "$discard" -ne 1 ]; then
      refuse "task $id pull request $PR_URL is $pr_state, not merged; pass --discard only with the captain's explicit discard authority"
    fi
  elif [ -n "$BRANCH" ] && [ "$discard" -ne 1 ]; then
    refuse "task $id pushed branch $BRANCH with no pull request; pass --discard only with the captain's explicit discard authority"
  fi
  if [ "$AGENT_STATUS" != ARCHIVED ]; then
    api POST "/v1/agents/$REC_AGENT/archive"
    api_ok || api_error "archiving agent $REC_AGENT"
  fi
  if [ -e "$STATE/$id.check.sh" ] || [ -e "$STATE/$id.check-trust" ]; then
    FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-check-unregister.sh" "$id" >/dev/null \
      || die "agent archived, but the watcher check for $id could not be retired"
  fi
  rm -f -- "$STATE/$id.cloud-notified" "$(record_path "$id")"
  printf 'cleaned up: %s (agent %s archived)\n' "$id" "$REC_AGENT"
}

cmd_eligible() {
  local name=${1-}
  [ -n "$name" ] && [ "$#" -eq 1 ] || usage
  need_tools git
  check_eligible "$name"
  printf 'eligible: %s %s\n' "$name" "$ELIGIBLE_REPO_URL"
}

sub=${1-}
[ -n "$sub" ] || usage
shift
case "$sub" in
  eligible) cmd_eligible "$@" ;;
  dispatch) cmd_dispatch "$@" ;;
  status) cmd_status "$@" ;;
  pr) cmd_pr "$@" ;;
  cancel) cmd_cancel "$@" ;;
  poll) cmd_poll "$@" ;;
  cleanup) cmd_cleanup "$@" ;;
  -h|--help|help) sed -n '2,56p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) usage ;;
esac
