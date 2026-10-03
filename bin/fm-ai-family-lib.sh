#!/usr/bin/env bash
# AI family resolution: which model maker an agent's model comes from.
#
# ONE owner for the question "which AI family produced this work?", asked by
# bin/fm-spawn.sh when it records a task's builder family and by
# bin/fm-cross-review.sh when it records the family of a reviewer. A family is
# the model maker (anthropic, openai, xai, moonshot, google, meta, mistral,
# deepseek, zai), never a harness, an account, or a quota provider: one
# harness can serve several makers, and two harnesses can serve one maker.
#
# The family is read from the harness's own catalog, never inferred from a model
# or seat name:
#   - A harness whose catalog serves exactly one maker's models names that maker
#     (claude, codex, grok, kimi, gemini, muse).
#   - A harness whose catalog is keyed by provider (pi, pi-signed, omp,
#     opencode) names the provider in the catalog row itself. A model given as
#     `<provider>/<id>` carries that catalog provider key verbatim (it is the
#     launch's provider selector). An unqualified id is looked up in the
#     harness's live catalog (fm_ai_family_catalog_provider below), and resolves
#     only when exactly one provider row lists it.
#   - A catalog provider key maps to a maker only when that provider serves one
#     maker. A gateway that serves several makers (openrouter, opencode-go,
#     github-copilot, amazon-bedrock, and every key not listed below) resolves
#     to `unknown`, because nothing in its catalog row proves the maker.
#   - Every other harness (cursor, devin, rovo, agy, and anything unlisted)
#     serves several makers without naming one per model, so it is `unknown`.
# `unknown` is a verdict, not a failure: a caller that needs two families to
# differ must treat `unknown` as "independence cannot be proven".
#
# A task can be driven by more than one family over its life (a relaunch may
# switch harness), so families are carried as a sorted, comma-separated set.

FM_AI_FAMILY_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/fm-timeout-lib.sh
. "$FM_AI_FAMILY_LIB_DIR/fm-timeout-lib.sh"

# Set by fm_ai_family_resolve.
FM_AI_FAMILY=
FM_AI_FAMILY_SOURCE=

# Catalog provider key -> maker. Only providers that serve exactly one maker.
# codex-native is Pi's provider for the Codex app server, whose catalog is
# OpenAI's alone.
fm_ai_family_of_provider() {  # <catalog-provider-key>
  case "$1" in
    anthropic|claude-bridge) printf 'anthropic\n' ;;
    openai|openai-codex|codex-native|azure-openai-responses) printf 'openai\n' ;;
    xai) printf 'xai\n' ;;
    kimi-coding|moonshot|moonshotai) printf 'moonshot\n' ;;
    google|google-gemini-cli|google-vertex) printf 'google\n' ;;
    mistral) printf 'mistral\n' ;;
    deepseek) printf 'deepseek\n' ;;
    zai) printf 'zai\n' ;;
    *) return 1 ;;
  esac
}

# The catalog provider for an unqualified model id, read from the harness's own
# live model listing. Prints the provider key only when exactly one provider row
# lists the id. FM_AI_FAMILY_PI_CATALOG may name a file holding a captured
# `pi --list-models` listing, used instead of running the CLI (tests and callers
# that already hold a listing).
fm_ai_family_catalog_provider() {  # <harness> <model-id>
  local harness=$1 model=$2 listing providers count
  case "$harness" in
    pi|pi-signed)
      if [ -n "${FM_AI_FAMILY_PI_CATALOG:-}" ]; then
        listing=$(cat -- "$FM_AI_FAMILY_PI_CATALOG" 2>/dev/null) || return 1
      else
        command -v pi >/dev/null 2>&1 || return 1
        listing=$(fm_run_timed "${FM_AI_FAMILY_CATALOG_TIMEOUT:-20}" pi --list-models 2>/dev/null) || return 1
      fi
      providers=$(printf '%s\n' "$listing" | awk -v m="$model" 'NR > 1 && $2 == m { print $1 }' | sort -u)
      ;;
    *) return 1 ;;
  esac
  count=$(printf '%s' "$providers" | grep -c . || true)
  [ "$count" = 1 ] || return 1
  printf '%s\n' "$providers"
}

# Resolve one (harness, model) pair. Sets FM_AI_FAMILY to the maker or
# `unknown`, and FM_AI_FAMILY_SOURCE to a short plain-text reason that names
# the catalog fact used. Always returns 0.
# shellcheck disable=SC2034 # FM_AI_FAMILY*: output globals, read by the sourcing caller.
fm_ai_family_resolve() {  # <harness> [<model>]
  local harness=$1 model=${2:-} provider id fam
  case "$model" in default|-) model= ;; esac
  FM_AI_FAMILY=unknown
  FM_AI_FAMILY_SOURCE=
  case "$harness" in
    claude) FM_AI_FAMILY=anthropic; FM_AI_FAMILY_SOURCE="claude catalog serves only Anthropic models" ;;
    codex) FM_AI_FAMILY=openai; FM_AI_FAMILY_SOURCE="codex catalog serves only OpenAI models" ;;
    grok) FM_AI_FAMILY=xai; FM_AI_FAMILY_SOURCE="grok catalog serves only xAI models" ;;
    kimi) FM_AI_FAMILY=moonshot; FM_AI_FAMILY_SOURCE="kimi catalog serves only Moonshot models" ;;
    gemini) FM_AI_FAMILY=google; FM_AI_FAMILY_SOURCE="gemini catalog serves only Google models" ;;
    muse) FM_AI_FAMILY=meta; FM_AI_FAMILY_SOURCE="muse catalog serves only Meta models" ;;
    pi|pi-signed|omp|opencode)
      if [ -z "$model" ]; then
        FM_AI_FAMILY_SOURCE="$harness serves several makers and no model was recorded"
        return 0
      fi
      case "$model" in
        */*)
          provider=${model%%/*}
          id=${model#*/}
          ;;
        *)
          id=$model
          provider=$(fm_ai_family_catalog_provider "$harness" "$model") || {
            FM_AI_FAMILY_SOURCE="$harness catalog does not list model $model under exactly one provider"
            return 0
          }
          ;;
      esac
      if fam=$(fm_ai_family_of_provider "$provider"); then
        FM_AI_FAMILY=$fam
        FM_AI_FAMILY_SOURCE="$harness catalog provider $provider serves model $id"
      else
        FM_AI_FAMILY_SOURCE="$harness catalog provider $provider serves several makers"
      fi
      ;;
    *) FM_AI_FAMILY_SOURCE="${harness:-unnamed} harness catalog names no maker per model" ;;
  esac
  return 0
}

# Sorted, de-duplicated union of comma-separated family sets.
fm_ai_family_union() {  # <set>...
  printf '%s\n' "$@" | tr ',' '\n' | awk 'NF && !seen[$0]++' | sort | paste -sd, -
}

# 0 when two family sets are both fully known and share no family, which is the
# only case in which their work is provably from different AI families.
fm_ai_family_disjoint() {  # <set-a> <set-b>
  local a=$1 b=$2 f
  [ -n "$a" ] && [ -n "$b" ] || return 1
  case ",$a,$b," in *,unknown,*) return 1 ;; esac
  for f in $(printf '%s' "$a" | tr ',' ' '); do
    case ",$b," in *",$f,"*) return 1 ;; esac
  done
  return 0
}
