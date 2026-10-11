#!/usr/bin/env bash
# Model-routing boundary for no-mistakes in Firstmate worker launch environments.
# Usage: fm-no-mistakes.sh <normal no-mistakes arguments>
# Spawn installs this executable as no-mistakes on the worker's PATH and binds
# FM_NO_MISTAKES_REAL to the original executable, FM_MODEL_ROUTER_HOME to the
# owning Firstmate home, and FM_MODEL_ROUTER_BRIEF to the exact task instructions. Non-model-changing operations pass through.
# Runs and gate responses check runtime pins and both global and repository agent policies
# through fm-dispatch-resolve.sh before calling the real tool. Fixed native
# agent chains remain fixed policies, recorded as deterministic exceptions;
# this boundary neither changes global config nor administers the daemon.
set -eu
SCRIPT_DIR=$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)
# shellcheck source=bin/fm-model-denylist-lib.sh
. "$SCRIPT_DIR/fm-model-denylist-lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"
REAL=${FM_NO_MISTAKES_REAL:-}
[ -n "$REAL" ] && [ -x "$REAL" ] && [ "$(realpath "$REAL")" != "$(realpath "${BASH_SOURCE[0]}")" ] || {
  echo 'model-route: original no-mistakes executable is not bound' >&2
  exit 1
}
case "${1:-} ${2:-}" in
  'axi run'|'axi rerun'|'axi respond'|run\ *|rerun\ *|' '|--skip\ *|--skip=*|--yes\ *|-y\ *)
    # Help does not select a model and must stay usable without task state.
    for arg in "$@"; do case "$arg" in -h|--help) exec "$REAL" "$@";; esac; done
    ;;
  *) exec "$REAL" "$@";;
esac
HOME_DIR=${FM_MODEL_ROUTER_HOME:?model routing requires the owning Firstmate home}
CONFIG=${FM_CONFIG_OVERRIDE:-$HOME_DIR/config}
BRIEF=${FM_MODEL_ROUTER_BRIEF:-$HOME_DIR/data/${FM_TASK_ID:-}/brief.md}
[ -r "$BRIEF" ] || { echo 'model-route: task instructions required for no-mistakes selection' >&2; exit 1; }
fm_model_denylist_load "$CONFIG" || { echo "$FM_MODEL_DENYLIST_ERROR" >&2; exit 1; }
# Recheck at run time, not only when the worker was spawned: a mid-run steer
# or worker-chosen immutable Pi pin must not evade a changed ban list.
model='' effort='' provider=''
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[i]}" in
    --model) i=$((i+1)); model=${args[i]:-};;
    --model=*) model=${args[i]#--model=};;
    --effort) i=$((i+1)); effort=${args[i]:-};;
    --effort=*) effort=${args[i]#--effort=};;
    --provider) i=$((i+1)); provider=${args[i]:-};;
    --provider=*) provider=${args[i]#--provider=};;
  esac
done
if [ -n "$provider" ] && [ -n "$model" ] && [[ "$model" != */* ]]; then model="$provider/$model"; fi
pin_sources=()
GLOBAL="${NM_HOME:-$HOME/.no-mistakes}/config.yaml"

route_pin() { # <harness> <model> <effort> <policy> [source-file] [context-hash]
  local profile policy_args=()
  [ -z "${5:-}" ] || policy_args=(--policy-file "$5")
  [ -z "${6:-}" ] || policy_args+=(--context-hash "$6")
  local source
  for source in ${pin_sources[@]+"${pin_sources[@]}"}; do policy_args+=(--policy-file "$source"); done
  profile=$(jq -nc --arg h "$1" --arg m "$2" --arg e "$3" '{harness:$h,model:$m,effort:$e}')
  FM_HOME="$HOME_DIR" FM_CONFIG_OVERRIDE="$CONFIG" "$SCRIPT_DIR/fm-dispatch-resolve.sh" "$BRIEF" \
    --decision-kind no-mistakes --policy-profile "$profile" --policy-reason "$4" ${policy_args[@]+"${policy_args[@]}"} >/dev/null
  "$SCRIPT_DIR/fm-model-route-receipt.py" check --home "$HOME_DIR" --config "$CONFIG" --brief "$BRIEF" \
    --kind no-mistakes --selected "$profile" ${policy_args[@]+"${policy_args[@]}"} >/dev/null
}
resolve_immutable_fields() {
  local cfg line value cfg_model='' cfg_provider='' cfg_effort=''
  [ -z "$model" ] || [ -z "$effort" ] || return 0
  for cfg in "$GLOBAL" "$PWD/.no-mistakes.yaml"; do
    [ -f "$cfg" ] || continue
    pin_sources+=("$cfg")
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      value=$(printf '%s\n' "$line" | awk '{for(i=1;i<NF;i++) if($i=="--model") print $(i+1)}')
      [ -z "$value" ] || cfg_model=$value
      value=$(printf '%s\n' "$line" | awk '{for(i=1;i<NF;i++) if($i=="--provider") print $(i+1)}')
      [ -z "$value" ] || cfg_provider=$value
      value=$(printf '%s\n' "$line" | awk '{for(i=1;i<NF;i++) if($i=="--effort") print $(i+1)}')
      [ -z "$value" ] || cfg_effort=$value
    done < <(fm_model_denylist_yaml_commands "$cfg" agent_config.pi)
  done
  if [ -z "$model" ]; then
    model=$cfg_model
    case "$model" in */*) ;; *) [ -z "$cfg_provider" ] || model="$cfg_provider/$model" ;; esac
  fi
  [ -n "$effort" ] || effort=$cfg_effort
  if [ -z "$model" ] || [ -z "$effort" ] || [[ "$model$effort" == *$'\n'* ]]; then
    echo 'model-route: provide a complete immutable Pi model/effort or inspectable agent_config.pi defaults' >&2
    exit 1
  fi
}

# A saved immutable pin outranks edited disk config. Read only the current
# branch's named run, never the unrelated overview rows shown for an empty
# branch, and never administer the shared daemon.
native_status=$(fm_nm_bounded "$PWD" 5 "$REAL" axi status 2>/dev/null) || {
  echo 'model-route: current run metadata is unavailable; no pipeline selection was launched' >&2
  exit 1
}
saved=$(fm_nm_saved_model_profile "$PWD" "$native_status") || exit 1
if [ "$(jq -r .state <<<"$saved")" = pinned ]; then
  saved_model=$(jq -r .selected.model <<<"$saved")
  saved_effort=$(jq -r .selected.effort <<<"$saved")
  if { [ -n "$model" ] && [ "$model" != "$saved_model" ]; } ||
    { [ -n "$effort" ] && [ "$effort" != "$saved_effort" ]; }; then
    echo 'model-route: a different selection cannot change an active immutable run' >&2
    exit 1
  fi
  saved_hash=$(printf '%s' "$saved" | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')
  route_pin pi "$saved_model" "$saved_effort" 'existing immutable no-mistakes Pi run pin' '' "$saved_hash"
  exec "$REAL" "$@"
fi
if [ -n "$model" ] || [ -n "$effort" ]; then
  resolve_immutable_fields
  route_pin pi "$model" "$effort" 'explicit immutable no-mistakes Pi run pin'
  # Native Pi-only validation remains the real tool's authority; unused
  # review-role config cannot replace this immutable pin.
  exec "$REAL" "$@"
fi
# The daemon's existing configured native-agent chain is deterministic. Every
# model in it is routed and checked, including reviewer-role override blocks.
count=0
for file in "$GLOBAL" "$PWD/.no-mistakes.yaml"; do
  fm_model_denylist_check_nm_config "$file" || { echo "$FM_MODEL_DENYLIST_ERROR" >&2; exit 1; }
  while IFS= read -r command; do
    harness=${command%% *}
    declared_harness=$(awk '{for(i=1;i<NF;i++) if($i=="--harness") print $(i+1)}' <<<"$command")
    [ -z "$declared_harness" ] || harness=$declared_harness
    pin=$(fm_model_denylist_command_pins "$command")
    [ -n "$pin" ] || continue
    # A YAML block cannot safely pin multiple models to the same agent.
    [[ "$pin" != *$'\n'* ]] || { echo 'model-route: conflicting pipeline model pins' >&2; exit 1; }
    pin_effort=$(awk '{ for (i=1; i<NF; i++) if ($i == "--effort" || $i == "--thinking") print $(i+1) }' <<<"$command")
    [[ "$pin_effort" != *$'\n'* ]] || { echo 'model-route: conflicting pipeline effort pins' >&2; exit 1; }
    case "$harness" in
      claude|pi|pi-signed|codex|grok|cursor|opencode|kimi|muse|omp|agy|gemini|rovo|devin)
        route_pin "$harness" "$pin" "$pin_effort" 'configured no-mistakes native agent/reviewer chain' "$file" ;;
      *) route_pin no-mistakes "$pin" "$pin_effort" 'uninspectable no-mistakes role policy' "$file" ;;
    esac
    count=$((count+1))
  done < <(fm_model_denylist_yaml_commands "$file")
done
if [ -z "$model" ] && [ "$count" -eq 0 ]; then
  echo 'model-route: no inspectable pipeline model pin; configure an explicit agent model before starting no-mistakes' >&2
  exit 1
fi
exec "$REAL" "$@"
