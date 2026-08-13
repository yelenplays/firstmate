#!/usr/bin/env bash
# Firstmate's harness-neutral, read-only Megamind preflight surface (pilot).
# Usage: fm-megamind-preflight.sh classify "<request text>"
#                                        print exactly substantive|bypass
#        fm-megamind-preflight.sh classify-stdin
#                                        classify one private request from stdin
#        fm-megamind-preflight.sh classify-provenance credential-submission
#                                        print bypass without accepting or reading
#                                        the credential payload
#        fm-megamind-preflight.sh run --request "<text>" [--model-class local|cloud]
#                                        [--today YYYY-MM-DD]
#        fm-megamind-preflight.sh run --request-stdin [--model-class local|cloud]
#                                        [--today YYYY-MM-DD]
#                                        run Megamind preflight and print one typed
#                                        fm/megamind-preflight/v1 JSON document
#        fm-megamind-preflight.sh continue --selection-id <id> --offer <wiki>
#                                        consume one private ambiguous offer and
#                                        print one typed authorization projection
#        fm-megamind-preflight.sh check print the same document shape describing
#                                        configuration, executable, and version
#                                        availability without routing a request
#
# Contract (owner: this header; policy owner: .agents/skills/megamind-preflight):
# - Every substantive Firstmate AI request goes through `run` BEFORE the answer,
#   plan, dispatch, or investigation relies on model knowledge. `classify` is the
#   deterministic conservative screen: it prints bypass ONLY for traffic that is
#   never substantive (empty input, a bare single-token harness slash command,
#   the four explicitly named control and monitoring kinds that the protocol
#   owner bin/fm-operational-input.sh resolves for a message - session-start,
#   watcher, turn-end-guard, away-supervisor, each including its landed legacy
#   prefix - and exact single acknowledgments) and substantive for everything
#   else. Slash-leading or path-leading prose, any operational input carrying a
#   task brief, and every shape the owner can only place in its untyped
#   `legacy-operational` catch-all - an unrecognized kind, a future version
#   token, a bare untyped prefix - stay substantive, so an unrecognized message
#   always takes the mandatory path. A credential supplied through an active,
#   trusted credential exchange takes the separate `classify-provenance
#   credential-submission` path: callers pass only that provenance token and
#   never the credential payload, so secret text cannot reach classify, run,
#   Megamind argv, or proof logging. Every unknown provenance is substantive.
# - `run` resolves the Megamind executable from the first line of local gitignored
#   config/megamind-executable (absent: plain `megamind-axi` on PATH) and the
#   pilot wiki estate from the first line of config/megamind-estate (absent:
#   not_configured failure - wiki roots are never guessed). Config values are
#   whitespace-trimmed and a leading `~` is expanded to $HOME; no other shell
#   expansion, globbing, or eval is applied to them. The model class comes
#   from --model-class, then config/megamind-model-class, then the restrictive
#   default `cloud` (every verified primary harness is a cloud model). Megamind
#   versions 0.3.x, 0.4.x, 0.5.x, and 0.6.x are accepted because all four
#   preserve the host-consumed `megamind/preflight-result/v2` fields; malformed,
#   older, and future versions remain version_incompatible until their
#   compatibility is established. The probe is anchored on identity: it parses
#   only a `megamind-axi <token>` line of `--version`, requires exactly one such
#   line, and bounds that token's length and character set. Other output lines
#   are ignored, raw executable output never reaches the typed document, and
#   failure.detected carries that bounded token or `unknown`.
# - The accepted v2 result must retain the host-consumed typed fields and their
#   required container types: identity strings, model class, status, thresholds,
#   result arrays, and match/offer confidence and path fields. The privacy
#   fields `filtered` and `redacted_count` are optional: a present one is type-
#   and range-checked, and an absent one keeps its existing safe default.
#   Additive upstream fields remain ignored or privacy-filtered by the existing
#   normalization boundary; missing or incompatible consumed fields are
#   malformed_output.
# - The Megamind call is read-only, and the request is passed after `--` so a
#   dash-leading request is never parsed as an option: `megamind-axi preflight
#   --model-class <class> --estate <dir> --today <date> --format json
#   --no-help-hints -- <request>`. Every flag sits after its subcommand, the one
#   placement Megamind's own command reference spells for both `preflight` and
#   `select-offer`; docs/verification/runtime-backends.md records the end-to-end
#   evidence for that exact argv on every accepted line - 0.3.0, 0.4.0, 0.5.0,
#   and 0.6.0 all answer it identically - so one argv serves all four and no
#   accepted release loses preflight. Megamind owns routing, thresholds, privacy
#   filtering, and budgets; this script never reimplements them.
# - `preflight` answers at the catalog level, so the widest surface it can name
#   is the card, digest, and index a wiki declares, and its `follow_up` asks the
#   host to open that index and follow its links. That sentence stays
#   informational and is never executed or parsed. Instead, every authorized
#   full-access root - a threshold match and an explicitly selected offer alike
#   - descends Megamind's own governed ladder once: `megamind-axi --root <root>
#   --format json --no-help-hints route --fields path,kind,score,confidence --
#   <request>`, with global flags before the subcommand, `--fields` where
#   `route` declares it, and the request last after `--`.
#   The ladder returns ranked candidate paths, kinds, scores, and per-candidate
#   route confidences and
#   never page content or file sizes, so it widens no content boundary. Its
#   root-contained `page` candidates, validated by the same path rule as any
#   declared allows, become eligible only when Megamind's own per-candidate
#   route confidence reaches the explicit local ROUTE_RELEVANCE_FLOOR below,
#   then are capped by that
#   authorization's own max_candidates and cut back to the ranked prefix whose
#   own bytes fit its own max_context_chars, because the bounded reader refuses a
#   whole over-budget admission and emits nothing partial. Byte counts are read
#   here from the candidates themselves, never their content, and for UTF-8 are
#   never smaller than the characters the reader will count. `route` takes no
#   model class and so cannot
#   re-apply the per-class restriction `preflight` already applied, which is why
#   an access this model class had narrowed below full - digest-only - never
#   descends at all and keeps the exact paths Megamind declared. A ladder that
#   is unusable, fails, returns an unrecognized document, cannot report a
#   per-candidate confidence, ranks no page, or ranks only below-floor pages
#   likewise leaves the declared card paths exactly as
#   they were, so this can only narrow an authorization onto pages Megamind
#   ranked above the local floor for a surface it already opened in full, and
#   never widen one past what Megamind returned.
# - The date is host-owned: it is always this host's current UTC date. The
#   optional `--today` is an assertion, not an override - a value that is not
#   that date is invalid_today - so no caller can forge the freshness,
#   staleness, or selection-binding semantics of a preflight. Deterministic
#   date behavior is reachable only by editing the private pending record on
#   disk, which no production path writes with a non-host date.
# - Outcome statuses pass through exactly: matched, ambiguous, no-match,
#   unavailable, privacy-filtered; any other status is malformed_output. A
#   matched document carries each match's validated relative `allows` paths plus
#   a non-disclosing wiki identity hash; absolute roots never enter the public
#   projection. That holds for the one field forwarded as upstream prose too:
#   Megamind's `follow_up` is by its own shape the route command carrying the
#   wiki root, so every estate and wiki root this host resolved for itself is
#   substituted out of it literally before it is emitted.
#   Offers carry names only - never paths to load. Filtered wiki
#   names are never echoed; only filtered_count is. The self-describing decision
#   thresholds pass through and are required: output without reliance_floor,
#   offer_floor, and ambiguity_band all present as numbers in 0..1 is
#   malformed_output. Matches carry validated freshness, a non-verbatim
#   provenance summary, and optional positive numeric context-budget fields.
#   `notes` is host-owned: one fixed line chosen here per outcome, never
#   Megamind's own notes, which can name below-floor wikis, out-of-band
#   candidates, and absolute roots. A no-match that withheld a candidate for
#   this model class (filtered_count > 0) is coverage denied rather than absent
#   and takes the privacy-filtered line, so no note ever tells an agent to
#   proceed from priors over a withheld wiki. A host-owned content-binding
#   object carries only opaque identities and current executable/model/catalog
#   facts; the bounded reader binds current root/card/file facts before content
#   admission.
# - Any missing, incompatible, malformed, or failed preflight prints the typed
#   document with outcome=error and a stable failure.code instead of a result:
#   not_configured, estate_missing, invalid_model_class, invalid_today,
#   executable_missing, version_incompatible, jq_missing, megamind_error (with
#   upstream_code), malformed_output, selection_pending_write_failed. The typed
#   document and the proof line are also emitted without jq, so jq_missing can
#   disclose itself. Exit code is 0 for definitive outcomes, 1 for errors.
# - An ambiguous `run` retains the complete original v2 JSON packet, exact
#   request, and binding identity in one mode-0600 record under the private
#   state/megamind-offer-selections directory. The normalized result exposes
#   only an opaque selection_id; the request and packet never enter chat, proof,
#   status, metadata, or worker instructions. The record binds request_hash,
#   preflight_id, catalog_hash, model class, executable and version, estate
#   identity, date semantics, and the current session identity.
# - Session identity is the owning home's authoritative session lock,
#   state/.lock, and nothing else: no environment token and no parent pid
#   invents a second one. A home with no readable lock cannot own an offer, so
#   the ambiguous result is emitted as usual with no selection_id and no
#   retained record, and continuation is simply unavailable there.
# - `select-offer` and the selection contract arrive at 0.6.x, while preflight
#   itself is proven on every accepted line. A 0.3.x, 0.4.x, or 0.5.x home keeps
#   its full mandatory preflight and takes that same uncontinuable path: the
#   ambiguous result stands with no selection_id and no retained record, because
#   an offer routed there could never be spent. The command is therefore never
#   sent to a release that does not publish it, and `continue` refuses with
#   selection_unsupported before invoking anything if the build changed under it.
# - The private selection store is bounded and script-owned, with no daemon: an
#   ambiguous `run` and a completed `continue` first retire every pending record
#   whose bound date is no longer this host's UTC date - such a record can never
#   authorize again - drop authorization tombstones older than a day, and keep
#   at most the newest SELECTION_RETENTION_MAX pending records. The bound covers
#   everything the script writes there, not just the two published names: the
#   packet extract and the publish temporaries carry the same original packet and
#   verbatim request, so a day-old one is retired too, and a lock directory with
#   no live recorded owner is released rather than left behind.
# - `continue` accepts only that opaque selection_id and the exact offered wiki.
#   It resolves every executable, estate, packet, request, and model value from
#   the private record, invokes the same executable's `select-offer` command,
#   validates the complete `megamind/preflight-selection-result/v1` result, and
#   emits only a fixed host-owned authorization projection. Validation checks the
#   typed shape and the governed refusals - provisional, pointer, no-load, unsafe
#   path, invalid budget - and never restates a decision Megamind already owns:
#   `selected.score` is upstream's own non-negative rank rather than a 0..1
#   confidence, `confidence.meets_floor` passes through as the boolean upstream
#   reports (an ambiguity decided inside the band can carry a true one), and the
#   ladder's `follow_up` is passed through exactly as the `run` path already
#   passes it, request text included and host-resolved roots redacted out of it
#   the same way. That an explicit selection is not a
#   threshold match is asserted where it belongs, in the projection's own
#   `selection.basis` and `threshold_matched`. Its failure codes
#   are selection_id_invalid, offer_invalid, jq_missing, state_invalid,
#   selection_missing, selection_replayed, selection_invalid, selection_busy,
#   selection_malformed, packet_malformed, packet_unavailable,
#   session_unavailable, selection_unsupported, binding_changed, upstream_error,
#   malformed_result, projection_failed, and retirement_failed.
#   Consumption is one-time twice
#   over: a per-selection owner-recorded lock serializes it and reclaims only a
#   provably dead owner, and the authorization is published through an
#   exclusive link that no second continuation can win. The pending record is
#   retired only after the projection is durably published, and preserved when
#   retry remains safe. A plain ambiguous worker preflight remains unauthorized.
# - Proof logging is minimal and non-verbatim: each `run` appends one JSON line
#   to state/megamind-preflight.jsonl with ts, preflight_id, request_hash,
#   model_class, catalog_hash, outcome, matched wiki names, and failure code.
#   Request text, wiki content, and bypass traffic are never logged.
# - Harness and runtime-backend neutral: the script depends only on bash, jq,
#   the resolved megamind-axi, and the POSIX tooling every supported host
#   already ships - `shasum` or `sha256sum` for the selection hashes, `ps` for
#   lock ownership, and `od` over /dev/urandom for the selection nonce. It reads
#   no harness, backend, or terminal state. `bin/fm-megamind-content.sh` is the
#   separate host-owned reader for every supported primary and worker surface.
#   tests/fm-megamind-preflight.test.sh and tests/fm-megamind-content.test.sh pin
#   those neutral contracts.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-operational-input.sh
. "$SCRIPT_DIR/fm-operational-input.sh"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

SCHEMA="fm/megamind-preflight/v1"
SELECTION_SCHEMA="fm/megamind-preflight-selection/v1"
MEGAMIND_SCHEMA="megamind/preflight-result/v2"
MEGAMIND_SELECTION_SCHEMA="megamind/preflight-selection-result/v1"
SUPPORTED_VERSION_LINES='0.3.x, 0.4.x, 0.5.x, or 0.6.x'
LOG_FILE="$STATE/megamind-preflight.jsonl"
SELECTION_DIR="$STATE/megamind-offer-selections"
SELECTION_RETENTION_MAX=32
# The local floor a ranked page must clear before it may replace an authorized
# declared index, expressed on Megamind's own per-candidate route-confidence
# scale (0..1) rather than on its raw lexical score. Score is the wrong unit
# here: it is an unbounded sum of fixed weights, it is not comparable across
# queries or wikis, and its smallest emittable value for a page candidate is
# already 2 - a wiki that scored at all plus an index entry that scored at all -
# so no score cutoff at or below 2 can reject anything the producer can emit.
# Confidence is bounded, comparable, and reported per candidate: for a page it
# is 0.6 * strongest matched signal class + 0.4 * query-token coverage, and the
# weakest signal class an index entry can carry is 0.5, so a page candidate can
# never sit at or below 0.3 and this floor is provably reachable from both
# sides. Calibrated against the real producer: an unrelated tax page surfaced
# for a portfolio-rebalancing question by a single index-path token reports
# 0.3571 and is refused, while the page that actually answers it reports 0.7143
# and the real-shape guard's on-topic pages report 1.0. This is a host-local
# admission floor only; Megamind's own reliance, offer, and ambiguity
# thresholds are its own and are never restated or changed here.
ROUTE_RELEVANCE_FLOOR=0.5
READ_POLICY="Use bin/fm-megamind-content.sh admit with this owning home's task authorization, then use its content channel; never read wiki paths directly, execute follow_up, or widen beyond validated allows and budgets."
RUN_USAGE='usage: fm-megamind-preflight.sh run --request "<text>" | --request-stdin [--model-class local|cloud] [--today YYYY-MM-DD]'
CONTINUE_USAGE='usage: fm-megamind-preflight.sh continue --selection-id <id> --offer <wiki>'

# The one privacy-minimization vocabulary every filter that projects upstream
# retrieval evidence prepends. Holding it here rather than restating it per
# filter is what keeps the `run` normalization and the `continue` authorization
# projection from drifting apart on what upstream evidence may be disclosed.
# shellcheck disable=SC2016 # jq owns these bindings; the shell must not expand them.
SAFE_JQ_DEFS='
  def safe_path: (type == "string") and (length > 0)
    and (startswith("/") | not) and (startswith("~") | not)
    and (test("(^|/)\\.\\.(/|$)") | not);
  # Upstream prose the host forwards verbatim - the ladder follow_up above all -
  # is the one place an absolute estate or wiki root can still reach the public
  # projection, so every root this host itself resolved is substituted out of it
  # literally. Literal, because a path is not a pattern: split/join never lets a
  # regex metacharacter in a captain path change what is matched.
  def redact_host_paths($paths):
    if (type == "string") and ($paths | type == "array")
    then reduce ($paths[] | select(type == "string" and length > 0)) as $path
      (.; split($path) | join("<path>"))
    else . end;
  def safe_date:
    if type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$") then . else null end;
  def positive_number: type == "number" and . > 0;
  def positive_integer: positive_number and floor == .;
  def safe_freshness:
    if type == "object" then {
      half_life_days: (.half_life_days | if positive_number then . else null end),
      last_confirmed: (.last_confirmed | safe_date),
      stale: (.stale | if type == "boolean" then . else null end)
    } else null end;
  def safe_budget:
    if type == "object" then {
      max_candidates: (.max_candidates | if positive_integer then . else null end),
      max_context_chars: (.max_context_chars | if positive_integer then . else null end)
    } | with_entries(select(.value != null)) else null end;
  def safe_signal_counts:
    if type == "object"
       and ((keys | sort) == ["name", "scope", "trigger"])
       and all(.[]; type == "number" and floor == . and . >= 0)
    then {trigger: .trigger, name: .name, scope: .scope}
    else null end;
  def safe_lexical_classes($counts):
    (["trigger", "name", "scope"] | map(select($counts[.] > 0))) as $derived |
    if type == "array" and (sort == ($derived | sort)) then $derived else null end;
  def safe_evidence:
    (if type == "object" then . else null end) as $evidence |
    ($evidence.signal_counts | safe_signal_counts) as $counts |
    ($evidence.lexical_classes | safe_lexical_classes($counts)) as $classes |
    ({semantic_score: ($evidence.semantic
       | if type == "number" then . else null end)}
     + if $counts != null and $classes != null then {
         lexical_classes: $classes,
         signal_counts: $counts,
         lexical_signal_count: ([$counts[]] | add)
       } else {
         lexical_classes: [],
         signal_counts: null,
         lexical_signal_count: null
       } end);
'

is_supported_version() {  # <version> - accept only proven complete 0.3.x/0.4.x/0.5.x/0.6.x releases
  local version="$1"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  case "$version" in
    0.3.*|0.4.*|0.5.*|0.6.*) return 0 ;;
    *) return 1 ;;
  esac
}

is_selection_capable_version() {  # <version> - only the line that publishes select-offer
  # Every accepted line routes a preflight, but `select-offer` and the
  # megamind/preflight-selection-result/v1 contract arrive at 0.6.x: an older
  # accepted build answers that subcommand with usage_error, so an offer routed
  # there is never continuable and the command is never sent to it.
  is_supported_version "$1" || return 1
  case "$1" in
    0.6.*) return 0 ;;
    *) return 1 ;;
  esac
}

detect_version() {  # <executable> - print its one anchored megamind-axi version token, or nothing
  # Identity is required and the disclosure is bounded: the raw stream is never
  # captured, only whole `megamind-axi <token>` lines are parsed, and a probe
  # that prints no such line - or more than one - names no single build and
  # yields nothing, so the gate fails closed on it.
  local parsed="" candidate
  while IFS= read -r candidate; do
    [ -z "$parsed" ] || return 1
    parsed="$candidate"
  done < <("$1" --version 2>/dev/null |
    sed -n 's/^megamind-axi \([0-9A-Za-z][0-9A-Za-z.+-]\{0,31\}\)$/\1/p')
  [ -n "$parsed" ] || return 1
  printf '%s\n' "$parsed"
}

file_bytes() {  # <path> - print a regular non-symlink file's byte count, or nothing
  # Metadata only, through the POSIX counter every supported host already ships:
  # no wiki byte is read here, and the bounded reader stays the only path any
  # content takes to a model.
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  local size
  size="$(wc -c < "$1" 2>/dev/null)" || return 1
  size="${size//[[:space:]]/}"
  case "$size" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$size"
}

route_page_allows() {  # <executable> <wiki root> <request> <max candidates> <max context chars> - print a JSON array of above-floor ranked page paths
  # Megamind answers `preflight` at the catalog level, so the widest surface it
  # can name is the card, digest, and index a wiki already declares. Its
  # follow_up sentence therefore asks the host to open that index and follow its
  # links, and firstmate never executes a follow_up - which left the descent
  # with no implementation at all: an authorization named a routing index and
  # nothing the index pointed at. `route` is Megamind's own governed ladder for
  # exactly that step. It resolves index links into ranked, root-contained page
  # candidates under the same declared budgets and returns paths, kinds, scores,
  # and per-candidate confidences - never page content, and never a file size -
  # so running it
  # widens no content boundary and the bounded reader stays the only way any
  # wiki byte reaches a model.
  #
  # An empty array is printed whenever the ladder is unusable, fails, returns a
  # document this host does not recognize, cannot report a per-candidate
  # confidence, surfaces no page at all, or ranks
  # every page below ROUTE_RELEVANCE_FLOOR. The caller then keeps the declared
  # card paths it already had, so this can only narrow an authorization onto
  # specific pages Megamind ranked above the local floor, never widen one past
  # what Megamind returned. Callers descend only for a full-access
  # authorization: `route` takes no model class, so it cannot restate the
  # restriction that produced a digest-only access, and trading that digest for
  # ranked pages would be the one substitution that widens.
  #
  # Both halves of the authorization's own declared budget bound the result, not
  # just max_candidates. The bounded reader refuses a whole admission that runs
  # past max_context_chars and emits nothing partial, so ranked pages that do not
  # fit would return the matched wiki to the exact failure this descent exists to
  # fix - an authorization that admits no content at all. `route` reports paths,
  # kinds, scores, and confidences and never a file size, so the fit is measured here
  # from each candidate's own byte count, which for UTF-8 is never smaller than
  # its character count and therefore only ever keeps a prefix that provably fits.
  # A candidate this host cannot size is one the reader could not open either, so
  # it is dropped rather than allowed to refuse the whole admission.
  local exe="$1" root="$2" request="$3" max_candidates="$4" max_chars="$5" raw rc=0 ranked path bytes total=0
  local -a fitted=()
  case "$max_candidates" in ''|*[!0-9]*) printf '%s' '[]'; return 0 ;; esac
  case "$max_chars" in ''|*[!0-9]*) printf '%s' '[]'; return 0 ;; esac
  if [ "$max_candidates" -le 0 ] || [ "$max_chars" -le 0 ] || [ -z "$root" ] || [ ! -d "$root" ]; then
    printf '%s' '[]'
    return 0
  fi
  # Global flags precede the subcommand, which is where every proven release
  # declares them for `route`, `--fields` follows it because that is the parser
  # that owns it, and the request goes last after `--` so a
  # dash-leading request stays a request rather than becoming an option. The
  # default candidate projection carries only path, kind, score, and reason, so
  # the confidence this floor gates on has to be asked for by name; a build that
  # cannot report it refuses the field, exits non-zero, and keeps the declared
  # paths rather than descending on a signal it never emitted. Its
  # stdin is closed explicitly: this runs inside the caller's record loop, and a
  # build that ever read stdin during `route` would otherwise swallow the
  # remaining match records and silently skip the ladder for every later wiki.
  raw="$("$exe" --root "$root" --format json --no-help-hints route \
    --fields path,kind,score,confidence -- "$request" </dev/null 2>/dev/null)" && rc=0 || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s' '[]'
    return 0
  fi
  # Control characters are refused with the unsafe paths, so the ranked set is a
  # plain line-delimited stream no candidate can misframe.
  ranked="$(printf '%s' "$raw" | jq -r --argjson max "$max_candidates" \
      --argjson floor "$ROUTE_RELEVANCE_FLOOR" "$SAFE_JQ_DEFS"'
      if (.schema_version | type == "string")
         and (.schema_version | startswith("megamind/route-result/"))
         and (.candidates | type == "array")
      then
        [.candidates[]?
          | select(type == "object" and .kind == "page")
          | select(.confidence | type == "number" and . >= $floor)
          | .path
          | select(safe_path and (test("[[:cntrl:]]") | not))]
        | reduce .[] as $path ([]; if index($path) then . else . + [$path] end)
        | .[0:$max]
      else [] end
      | .[]
    ' 2>/dev/null)" || { printf '%s' '[]'; return 0; }
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    bytes="$(file_bytes "$root/$path")" || continue
    [ $((total + bytes)) -le "$max_chars" ] || break
    total=$((total + bytes))
    fitted+=("$path")
  done <<< "$ranked"
  [ "${#fitted[@]}" -gt 0 ] || { printf '%s' '[]'; return 0; }
  jq -cn '$ARGS.positional' --args -- "${fitted[@]}" 2>/dev/null || printf '%s' '[]'
}

# Operational-input kinds that are pure control or routine monitoring. Every
# entry is a kind the protocol owner recognizes explicitly, so each landed legacy
# monitoring prefix still resolves here through its own kind. The kinds that
# carry a real task brief - from-firstmate and launch-brief - and the owner's
# untyped `legacy-operational` catch-all are deliberately absent: dispatched work
# is substantive, and a shape the owner could not subtype is unrecognized traffic
# that belongs on the mandatory path.
BYPASS_OPERATIONAL_KINDS='session-start watcher turn-end-guard away-supervisor'

trim_ws() {  # <text> - print it without leading or trailing whitespace
  local text="$1"
  text="${text#"${text%%[![:space:]]*}"}"
  text="${text%"${text##*[![:space:]]}"}"
  printf '%s' "$text"
}

expand_leading_tilde() {  # <path> - expand a leading ~ or ~/ to $HOME, nothing else
  # The tilde is held in a variable so every use below is an unambiguously
  # literal one-character match rather than something a shell might expand.
  local path="$1" tilde='~'
  if [ -z "${HOME:-}" ]; then
    printf '%s' "$path"
    return 0
  fi
  case "$path" in
    "$tilde") printf '%s' "$HOME" ;;
    "$tilde"/*) printf '%s' "$HOME/${path#"$tilde"/}" ;;
    *) printf '%s' "$path" ;;
  esac
}

first_line() {  # <file> - print first non-empty, non-comment line trimmed, or nothing
  [ -f "$1" ] || return 1
  local line trimmed
  while IFS= read -r line || [ -n "$line" ]; do
    trimmed="$(trim_ws "$line")"
    case "$trimmed" in
      ''|'#'*) continue ;;
      *) printf '%s\n' "$trimmed"; return 0 ;;
    esac
  done < "$1"
  return 1
}

config_path() {  # <file> - first_line plus leading-tilde expansion, no other expansion
  local raw
  raw="$(first_line "$1")" || return 1
  printf '%s\n' "$(expand_leading_tilde "$raw")"
}

json_escape() {  # <text> - print it escaped for use inside a JSON string
  local text="$1"
  text="${text//\\/\\\\}"
  text="${text//\"/\\\"}"
  text="${text//$'\n'/\\n}"
  text="${text//$'\r'/\\r}"
  text="${text//$'\t'/\\t}"
  printf '%s' "$text"
}

emit_error() {  # <code> <message> [extra-jq-filter-as-json]
  local code="$1" message="$2" extra="${3:-}"
  [ -n "$extra" ] || extra='{}'
  # jq_missing is the one failure that must be disclosable without jq, so the
  # typed document has a literal fallback. Only that path can reach it: every
  # other failure is raised after the jq probe has already succeeded.
  if ! command -v jq >/dev/null 2>&1; then
    printf '{"schema_version":"%s","outcome":"error","failure":{"code":"%s","message":"%s"},"model_class":null,"preflight_id":null,"catalog_hash":null,"request_hash":null,"confidence":null,"matches":[],"offers":[],"filtered_count":0,"redacted_count":0,"dropped_allows":0,"notes":[],"read_policy":null}\n' \
      "$(json_escape "$SCHEMA")" "$(json_escape "$code")" "$(json_escape "$message")"
    return 0
  fi
  jq -cn \
    --arg schema "$SCHEMA" \
    --arg code "$code" \
    --arg message "$message" \
    --argjson extra "$extra" \
    '{
      schema_version: $schema,
      outcome: "error",
      failure: ({code: $code, message: $message} + $extra),
      model_class: null,
      preflight_id: null,
      catalog_hash: null,
      request_hash: null,
      confidence: null,
      matches: [],
      offers: [],
      filtered_count: 0,
      redacted_count: 0,
      dropped_allows: 0,
      notes: [],
      read_policy: null
    }'
}

log_proof() {  # <outcome> <failure-code-or-empty> <preflight_id> <request_hash> <model_class> <catalog_hash> <wikis-json-array>
  local outcome="$1" failure="$2" preflight_id="$3" request_hash="$4" model_class="$5" catalog_hash="$6" wikis="$7"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p "$STATE" 2>/dev/null || return 0
  [ -e "$LOG_FILE" ] || : > "$LOG_FILE"
  chmod 600 "$LOG_FILE" 2>/dev/null || true
  # A run without jq never reaches Megamind, so it never has matched wikis.
  if ! command -v jq >/dev/null 2>&1; then
    local failure_json='null'
    [ -z "$failure" ] || failure_json="\"$(json_escape "$failure")\""
    printf '{"ts":"%s","preflight_id":"%s","request_hash":"%s","model_class":"%s","catalog_hash":"%s","outcome":"%s","wikis":[],"failure":%s}\n' \
      "$(json_escape "$ts")" "$(json_escape "$preflight_id")" "$(json_escape "$request_hash")" \
      "$(json_escape "$model_class")" "$(json_escape "$catalog_hash")" "$(json_escape "$outcome")" \
      "$failure_json" >> "$LOG_FILE" 2>/dev/null || true
    return 0
  fi
  jq -cn \
    --arg ts "$ts" \
    --arg outcome "$outcome" \
    --arg failure "$failure" \
    --arg preflight_id "$preflight_id" \
    --arg request_hash "$request_hash" \
    --arg model_class "$model_class" \
    --arg catalog_hash "$catalog_hash" \
    --argjson wikis "$wikis" \
    '{ts: $ts, preflight_id: $preflight_id, request_hash: $request_hash,
      model_class: $model_class, catalog_hash: $catalog_hash, outcome: $outcome,
      wikis: $wikis, failure: (if $failure == "" then null else $failure end)}' \
    >> "$LOG_FILE" 2>/dev/null || true
}

resolve_executable() {  # print the configured executable or the PATH default
  local configured
  if configured="$(config_path "$CONFIG/megamind-executable")"; then
    printf '%s\n' "$configured"
  else
    printf '%s\n' "megamind-axi"
  fi
}

resolve_model_class() {  # <flag-value-or-empty> - print class or fail loudly
  local flag="$1" configured
  if [ -n "$flag" ]; then
    printf '%s\n' "$flag"
    return 0
  fi
  if configured="$(first_line "$CONFIG/megamind-model-class")"; then
    printf '%s\n' "$configured"
    return 0
  fi
  printf '%s\n' "cloud"
}

hash_text() {  # <text> - print a portable SHA-256 digest
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    return 1
  fi
}

hash_file() {  # <file> - print a portable SHA-256 digest
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    return 1
  fi
}

valid_today() {  # <date> - accept the upstream command's explicit ISO date shape
  [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]
}

current_today() {  # this host's own UTC date; no caller can substitute another one
  date -u +%Y-%m-%d
}

current_session_identity() {  # the owning home's authoritative session lock, or nothing
  # state/.lock is the one session identity Firstmate already publishes, so the
  # binding asks it rather than accepting an environment token or inferring a
  # parent pid, either of which would be a second, forgeable session system.
  local pid
  [ -f "$STATE/.lock" ] && [ ! -L "$STATE/.lock" ] || return 1
  { IFS= read -r pid < "$STATE/.lock"; } 2>/dev/null || return 1
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$pid" -gt 1 ] || return 1
  printf 'lock:%s\n' "$pid"
}

resolved_executable() {  # <configured executable> - print the exact executable path used
  local found="$1"
  if [[ "$found" = /* ]]; then
    [ -x "$found" ] || return 1
    CDPATH='' cd -P -- "$(dirname -- "$found")" 2>/dev/null || return 1
    printf '%s/%s\n' "$PWD" "$(basename -- "$found")"
  else
    command -v "$found"
  fi
}

estate_identity() {  # <estate> - hash the canonical estate identity, never expose its path
  local real
  real="$(CDPATH='' cd -P -- "$1" 2>/dev/null && pwd -P)" || return 1
  hash_text "megamind-estate/v1\n$real"
}

new_nonce() {
  local nonce
  nonce="$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d '[:space:]' || true)"
  [ -n "$nonce" ] || nonce="$(hash_text "$$:$PPID:$(date +%s%N)")"
  printf '%s\n' "$nonce"
}

selection_path() {  # <selection-id> - script-owned private pending path
  printf '%s/%s.pending.json\n' "$SELECTION_DIR" "$1"
}

authorization_path() {  # <selection-id> - script-owned private consumed result path
  printf '%s/%s.authorization.json\n' "$SELECTION_DIR" "$1"
}

selection_lock_path() {  # <selection-id> - per-selection mutex, so one abandoned lock cannot wedge the home
  printf '%s/.%s.lock\n' "$SELECTION_DIR" "$1"
}

prune_selections() {  # <today> [records about to be written] - bound the private store
  # Pending evidence is bound to the date it was captured on, so a record from
  # another date is already refused by `continue` and only occupies the store.
  # This runs on the two paths that change the store, so no daemon is involved.
  # Pruning precedes the write it makes room for, so the caller states how many
  # records are incoming and the cap holds afterwards rather than one short.
  local today="$1" incoming="${2:-0}" entry stored excess oldest
  local -a kept=()
  [ -d "$SELECTION_DIR" ] && [ ! -L "$SELECTION_DIR" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  for entry in "$SELECTION_DIR"/*.pending.json; do
    [ -f "$entry" ] && [ ! -L "$entry" ] || continue
    stored="$(jq -r 'if type == "object" and (.today | type == "string")
      then .today else "" end' "$entry" 2>/dev/null || true)"
    if [ "$stored" != "$today" ]; then
      rm -f -- "$entry" 2>/dev/null || true
      continue
    fi
    kept+=("$entry")
  done
  # An authorization is only a replay tombstone for a pending record that could
  # still exist, and no pending record outlives its date, so a day is enough.
  find "$SELECTION_DIR" -maxdepth 1 -type f -name '*.authorization.json' -mtime +0 \
    -exec rm -f -- '{}' + 2>/dev/null || true
  # The packet extract and every publish temporary hold the same original packet
  # and verbatim request as a pending record, so the bound covers them too: each
  # belongs to one live invocation and a day-old one was abandoned by a crash.
  find "$SELECTION_DIR" -maxdepth 1 -type f \( -name '.*.packet.*' -o -name '*.tmp.*' \) \
    -mtime +0 -exec rm -f -- '{}' + 2>/dev/null || true
  for entry in "$SELECTION_DIR"/.*.lock; do
    [ -d "$entry" ] && [ ! -L "$entry" ] || continue
    selection_lock_owner_alive "$entry" && continue
    [ -n "$(find "$entry" -maxdepth 0 -mmin +5 2>/dev/null)" ] || continue
    rm -rf -- "$entry" 2>/dev/null || true
  done
  for entry in "$SELECTION_DIR"/.*.lock.stale.*; do
    [ -d "$entry" ] && [ ! -L "$entry" ] || continue
    rm -rf -- "$entry" 2>/dev/null || true
  done
  excess=$(( ${#kept[@]} + incoming - SELECTION_RETENTION_MAX ))
  [ "$excess" -gt 0 ] || return 0
  while IFS= read -r oldest; do
    [ -n "$oldest" ] || continue
    rm -f -- "$oldest" 2>/dev/null || true
  done < <(
    for entry in "${kept[@]}"; do
      printf '%s\t%s\n' "$(file_mtime "$entry" 2>/dev/null || printf 0)" "$entry"
    done | LC_ALL=C sort -n | head -n "$excess" | cut -f2-
  )
  return 0
}

process_start() {  # <pid> - the process's own start stamp, or nothing
  local ps_bin value
  if [ -x /bin/ps ]; then ps_bin=/bin/ps; elif [ -x /usr/bin/ps ]; then ps_bin=/usr/bin/ps; else return 1; fi
  value="$("$ps_bin" -p "$1" -o lstart= 2>/dev/null)" || return 1
  [ -n "$value" ] || return 1
  case "$value" in *$'\n'*|*$'\r'*) return 1 ;; esac
  printf '%s\n' "$value"
}

process_command() {  # <pid> - the process's own command line, or nothing
  local ps_bin value
  if [ -x /bin/ps ]; then ps_bin=/bin/ps; elif [ -x /usr/bin/ps ]; then ps_bin=/usr/bin/ps; else return 1; fi
  value="$("$ps_bin" -p "$1" -o command= 2>/dev/null)" || return 1
  [ -n "$value" ] || return 1
  case "$value" in *$'\n'*|*$'\r'*) return 1 ;; esac
  printf '%s\n' "$value"
}

read_lock_field() {  # <lock dir> <field> - one bounded single-line owner value
  local file="$1/$2" value
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  { IFS= read -r value < "$file"; } 2>/dev/null || return 1
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

selection_lock_owner_recorded() {  # <lock dir> - the owner record is complete
  read_lock_field "$1" pid >/dev/null 2>&1 \
    && read_lock_field "$1" start >/dev/null 2>&1 \
    && read_lock_field "$1" command >/dev/null 2>&1
}

selection_lock_owner_alive() {  # <lock dir> - the recorded owner is provably the live process
  local lock="$1" pid recorded actual
  pid="$(read_lock_field "$lock" pid)" || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$pid" -gt 1 ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  recorded="$(read_lock_field "$lock" start)" || return 1
  actual="$(process_start "$pid")" || return 1
  [ "$recorded" = "$actual" ] || return 1
  recorded="$(read_lock_field "$lock" command)" || return 1
  actual="$(process_command "$pid")" || return 1
  [ "$recorded" = "$actual" ]
}

record_selection_lock_owner() {  # <lock dir> - name the owner so a stale lock is recognizable
  local lock="$1" pid start command
  pid="${BASHPID:-$$}"
  start="$(process_start "$pid")" || return 1
  command="$(process_command "$pid")" || return 1
  printf '%s\n' "$pid" > "$lock/pid" 2>/dev/null || return 1
  printf '%s\n' "$start" > "$lock/start" 2>/dev/null || return 1
  printf '%s\n' "$command" > "$lock/command" 2>/dev/null || return 1
}

acquire_selection_lock() {  # <lock dir> - take the mutex, reclaiming only a provably abandoned one
  local lock="$1" stale
  if mkdir -- "$lock" 2>/dev/null; then
    record_selection_lock_owner "$lock" && return 0
    rm -rf -- "$lock" 2>/dev/null || true
    return 1
  fi
  [ -d "$lock" ] && [ ! -L "$lock" ] || return 1
  if selection_lock_owner_recorded "$lock"; then
    # A live owner keeps the lock; only a provably gone one is reclaimed.
    ! selection_lock_owner_alive "$lock" || return 1
  else
    # An owner record is written immediately after the mkdir, so an incomplete
    # one is a live acquisition until it is far too old to be one.
    [ -n "$(find "$lock" -maxdepth 0 -mmin +5 2>/dev/null)" ] || return 1
  fi
  # Only one reclaimer can win the rename, so the loser stays refused instead of
  # tearing down the lock the winner is about to take.
  stale="$lock.stale.${BASHPID:-$$}"
  rm -rf -- "$stale" 2>/dev/null || true
  mv -- "$lock" "$stale" 2>/dev/null || return 1
  rm -rf -- "$stale" 2>/dev/null || true
  mkdir -- "$lock" 2>/dev/null || return 1
  record_selection_lock_owner "$lock" && return 0
  rm -rf -- "$lock" 2>/dev/null || true
  return 1
}

valid_selection_id() {
  [ "${#1}" -ge 16 ] && [ "${#1}" -le 128 ] && [[ "$1" =~ ^[A-Fa-f0-9]+$ ]]
}

private_mode() {  # <file> - print portable numeric permission bits
  if [ "$(uname)" = Darwin ]; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}

file_mtime() {  # <file> - print portable modification time in epoch seconds
  if [ "$(uname)" = Darwin ]; then
    stat -f '%m' "$1"
  else
    stat -c '%Y' "$1"
  fi
}

private_publish() {  # <destination> - publish stdin as mode-0600 in its existing private directory
  local destination="$1" tmp old_umask
  tmp="${destination}.tmp.${BASHPID:-$$}"
  old_umask="$(umask)"
  umask 077
  if ! cat > "$tmp" || ! chmod 600 "$tmp" || ! mv -f -- "$tmp" "$destination"; then
    umask "$old_umask"
    rm -f -- "$tmp" 2>/dev/null || true
    return 1
  fi
  umask "$old_umask"
}

private_publish_exclusive() {  # <destination> - the same publish, but only the first writer can ever win
  # `ln` onto an existing name fails atomically, so one-time consumption does
  # not rest on the lock alone or on a check that a racer could pass first.
  local destination="$1" tmp old_umask
  tmp="${destination}.tmp.${BASHPID:-$$}"
  old_umask="$(umask)"
  umask 077
  if ! cat > "$tmp" || ! chmod 600 "$tmp" || ! ln -- "$tmp" "$destination" 2>/dev/null; then
    umask "$old_umask"
    rm -f -- "$tmp" 2>/dev/null || true
    return 1
  fi
  umask "$old_umask"
  rm -f -- "$tmp" 2>/dev/null || true
}

selection_error() {  # <code> <message> [extra JSON object]
  local code="$1" message="$2" extra="${3:-}"
  [ -n "$extra" ] || extra='{}'
  if ! command -v jq >/dev/null 2>&1; then
    printf '{"schema_version":"%s","outcome":"error","failure":{"code":"%s","message":"%s"}}\n' \
      "$SELECTION_SCHEMA" "$(json_escape "$code")" "$(json_escape "$message")"
    return 1
  fi
  jq -cn --arg schema "$SELECTION_SCHEMA" --arg code "$code" --arg message "$message" \
    --argjson extra "$extra" \
    '{schema_version:$schema,outcome:"error",failure:({code:$code,message:$message} + $extra)}'
  return 1
}

classify_provenance() {  # <trusted-provenance> - print substantive|bypass, never read payload text
  case "$1" in
    credential-submission) printf 'bypass\n' ;;
    *) printf 'substantive\n' ;;
  esac
}

retain_ambiguous() {  # <raw upstream packet> <request> <normalized document> - write one private pending selection
  # Returns 2 when nothing here could ever consume the offer - this home owns no
  # authoritative session, or the resolved build publishes no `select-offer`.
  # Neither is a failure: the ambiguous result stands, only uncontinuable.
  local raw="$1" request="$2" normalized="$3"
  local preflight_id request_hash catalog_hash model_class nonce session_id exe estate today
  local exe_path exe_hash estate_hash selection_id pending record
  if ! printf '%s' "$raw" | jq -e \
      '. | type == "object" and .schema_version == "megamind/preflight-result/v2"
       and .status == "ambiguous"' >/dev/null 2>&1; then
    return 1
  fi
  today="${RUN_TODAY:-}"
  # Retirement is store hygiene, not a privilege of a home that can still hold
  # offers, so it precedes every reason this may decline to retain another one.
  prune_selections "$today"
  is_selection_capable_version "${RUN_VERSION:-}" || return 2
  session_id="$(current_session_identity)" || return 2
  preflight_id="$(printf '%s' "$normalized" | jq -r '.preflight_id')"
  request_hash="$(printf '%s' "$normalized" | jq -r '.request_hash')"
  catalog_hash="$(printf '%s' "$normalized" | jq -r '.catalog_hash')"
  model_class="$(printf '%s' "$normalized" | jq -r '.model_class')"
  exe="$(resolve_executable)"
  estate="$(config_path "$CONFIG/megamind-estate" 2>/dev/null || true)"
  exe_path="$(resolved_executable "$exe" 2>/dev/null || true)"
  exe_hash="$(hash_file "$exe_path" 2>/dev/null || true)"
  estate_hash="$(estate_identity "$estate" 2>/dev/null || true)"
  [ -n "$exe_path" ] && [ -n "$exe_hash" ] && [ -n "$estate_hash" ] \
    || return 1
  nonce="$(new_nonce)" || return 1
  selection_id="$(hash_text "$(jq -cn --arg request_hash "$request_hash" \
    --arg preflight_id "$preflight_id" --arg catalog_hash "$catalog_hash" \
    --arg model_class "$model_class" --arg executable "$exe_path" \
    --arg version "$RUN_VERSION" --arg estate "$estate_hash" --arg today "$today" \
    --arg session "$session_id" --arg nonce "$nonce" \
    '{request_hash:$request_hash,preflight_id:$preflight_id,catalog_hash:$catalog_hash,
      model_class:$model_class,executable:$executable,version:$version,estate:$estate,
      today:$today,session:$session,nonce:$nonce}' )")" || return 1
  mkdir -p -- "$SELECTION_DIR" 2>/dev/null || return 1
  chmod 700 "$SELECTION_DIR" 2>/dev/null || return 1
  prune_selections "$today" 1
  pending="$(selection_path "$selection_id")"
  [ ! -L "$pending" ] || return 1
  # The record is composed before it is published so a jq that dies partway is
  # a write failure rather than a truncated record a pipeline reported as good.
  record="$(jq -cn --arg schema "$SELECTION_SCHEMA" --arg selection_id "$selection_id" \
      --arg request "$request" --arg request_hash "$request_hash" \
      --arg preflight_id "$preflight_id" --arg catalog_hash "$catalog_hash" \
      --arg model_class "$model_class" --arg executable "$exe_path" \
      --arg executable_hash "$exe_hash" --arg version "$RUN_VERSION" \
      --arg estate_identity "$estate_hash" --arg today "$today" \
      --arg session_identity "$session_id" --arg nonce "$nonce" \
      --argjson packet "$raw" \
      '{schema_version:$schema,status:"pending",selection_id:$selection_id,
        request:$request,request_hash:$request_hash,preflight_id:$preflight_id,
        catalog_hash:$catalog_hash,model_class:$model_class,
        executable:{path:$executable,sha256:$executable_hash,version:$version},
        estate_identity:$estate_identity,today:$today,session_identity:$session_identity,
        nonce:$nonce,packet:$packet}')" || return 1
  printf '%s\n' "$record" | private_publish "$pending" || return 1
  PENDING_SELECTION_ID="$selection_id"
}

classify() {  # <request text> - print substantive|bypass
  local text="$1" lowered op_kind rest
  # Operational-input provenance is carried by exact bytes at position 0 and is
  # owned by bin/fm-operational-input.sh, so the kind is asked for rather than
  # restated here. Only its control and monitoring kinds bypass.
  if fm_operational_input_classify "$text" op_kind; then
    case " $BYPASS_OPERATIONAL_KINDS " in
      *" $op_kind "*) printf 'bypass\n'; return ;;
    esac
    printf 'substantive\n'; return
  fi
  text="$(trim_ws "$text")"
  # Empty input is never substantive.
  [ -n "$text" ] || { printf 'bypass\n'; return; }
  # A bare single-token harness slash command is a pure control message. Any
  # other slash-leading text - a leading absolute path, a command with prose
  # arguments - is a request and stays on the mandatory path.
  case "$text" in
    /[A-Za-z]*)
      rest="${text#/}"
      case "$rest" in
        *[!A-Za-z0-9_:-]*) : ;;
        *) printf 'bypass\n'; return ;;
      esac
      ;;
  esac
  # Exact single acknowledgments, case-insensitive.
  lowered="$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')"
  case "$lowered" in
    ok|okay|yes|no|yep|nope|nah|aye|thanks|thank\ you|thx|ack|lgtm|shipshape|done|continue|proceed|go\ ahead)
      printf 'bypass\n'; return ;;
  esac
  printf 'substantive\n'
}

cmd_check() {
  local exe estate model_class version
  exe="$(resolve_executable)"
  model_class="$(resolve_model_class "")"
  estate="$(config_path "$CONFIG/megamind-estate" 2>/dev/null || true)"
  if ! command -v jq >/dev/null 2>&1; then
    emit_error jq_missing "jq is required to parse Megamind preflight output"
    return 1
  fi
  if [ -z "$estate" ]; then
    emit_error not_configured "config/megamind-estate is absent; pilot wiki roots are never guessed"
    return 1
  fi
  if [ ! -d "$estate" ]; then
    emit_error estate_missing "configured estate is not a directory"
    return 1
  fi
  case "$model_class" in
    local|cloud) : ;;
    *) emit_error invalid_model_class "model class must be local or cloud"; return 1 ;;
  esac
  if ! command -v "$exe" >/dev/null 2>&1; then
    emit_error executable_missing "Megamind executable not found: $exe"
    return 1
  fi
  version="$(detect_version "$exe")"
  if ! is_supported_version "$version"; then
    emit_error version_incompatible "megamind-axi $SUPPORTED_VERSION_LINES are required" \
      "$(jq -cn --arg detected "${version:-unknown}" '{detected: $detected}')"
    return 1
  fi
  jq -cn \
    --arg schema "$SCHEMA" \
    --arg exe "$exe" \
    --arg version "$version" \
    --arg estate "$estate" \
    --arg model_class "$model_class" \
    '{schema_version: $schema, outcome: "available", failure: null,
      executable: $exe, version: $version, estate: $estate,
      model_class: $model_class}'
}

cmd_run() {
  local request="" request_stdin=0 model_class_flag="" today_flag=""
  # Every option value is arity-checked before the shift: `shift 2` with one
  # positional left shifts nothing and would spin this loop forever on the
  # mandatory path, so a missing value must fail closed here instead.
  while [ $# -gt 0 ]; do
    case "$1" in
      --request)
        [ "$request_stdin" -eq 0 ] && [ -z "$request" ] || { printf '%s\n' "$RUN_USAGE" >&2; return 2; }
        [ $# -ge 2 ] || { printf '%s\n' "$RUN_USAGE" >&2; return 2; }
        request="$2"; shift; shift ;;
      --request-stdin)
        [ -z "$request" ] && [ "$request_stdin" -eq 0 ] || { printf '%s\n' "$RUN_USAGE" >&2; return 2; }
        request_stdin=1; shift ;;
      --model-class)
        [ $# -ge 2 ] || { printf '%s\n' "$RUN_USAGE" >&2; return 2; }
        model_class_flag="$2"; shift; shift ;;
      --today)
        [ $# -ge 2 ] || { printf '%s\n' "$RUN_USAGE" >&2; return 2; }
        today_flag="$2"; shift; shift ;;
      *) printf '%s\n' "$RUN_USAGE" >&2; return 2 ;;
    esac
  done
  if [ "$request_stdin" -eq 1 ]; then
    request="$(cat)"
  fi
  [ -n "$request" ] || { printf '%s\n' "$RUN_USAGE" >&2; return 2; }

  local exe estate model_class version raw rc outcome today
  RUN_VERSION=
  exe="$(resolve_executable)"
  model_class="$(resolve_model_class "$model_class_flag")"
  estate="$(config_path "$CONFIG/megamind-estate" 2>/dev/null || true)"
  # The date is the host's own, never the caller's. `--today` may only assert
  # the date the caller believes it is running on, so a rollover or a forged
  # value is refused instead of quietly reshaping freshness and staleness.
  today="$(current_today 2>/dev/null || true)"
  if [ -z "$today" ] || ! valid_today "$today"; then
    emit_error invalid_today "could not establish the Megamind date"
    log_proof error invalid_today "" "" "$model_class" "" '[]'
    return 1
  fi
  if [ -n "$today_flag" ] && [ "$today_flag" != "$today" ]; then
    emit_error invalid_today "--today must state this host's current UTC date"
    log_proof error invalid_today "" "" "$model_class" "" '[]'
    return 1
  fi
  RUN_TODAY="$today"

  if ! command -v jq >/dev/null 2>&1; then
    emit_error jq_missing "jq is required to parse Megamind preflight output"
    log_proof error jq_missing "" "" "$model_class" "" '[]'
    return 1
  fi
  if [ -z "$estate" ]; then
    emit_error not_configured "config/megamind-estate is absent; pilot wiki roots are never guessed"
    log_proof error not_configured "" "" "$model_class" "" '[]'
    return 1
  fi
  if [ ! -d "$estate" ]; then
    emit_error estate_missing "configured estate is not a directory"
    log_proof error estate_missing "" "" "$model_class" "" '[]'
    return 1
  fi
  case "$model_class" in
    local|cloud) : ;;
    *)
      emit_error invalid_model_class "model class must be local or cloud"
      log_proof error invalid_model_class "" "" "" "" '[]'
      return 1
      ;;
  esac
  if ! command -v "$exe" >/dev/null 2>&1; then
    emit_error executable_missing "Megamind executable not found: $exe"
    log_proof error executable_missing "" "" "$model_class" "" '[]'
    return 1
  fi
  version="$(detect_version "$exe")"
  RUN_VERSION="$version"
  if ! is_supported_version "$version"; then
    emit_error version_incompatible "megamind-axi $SUPPORTED_VERSION_LINES are required" \
      "$(jq -cn --arg detected "${version:-unknown}" '{detected: $detected}')"
    log_proof error version_incompatible "" "" "$model_class" "" '[]'
    return 1
  fi

  # Read-only Megamind call. Megamind owns routing, thresholds, privacy
  # filtering, and budgets; nothing here widens what it returns. Every flag sits
  # after the subcommand, where each proven release declares it, and the request
  # goes last, after `--`, so a dash-leading request stays a request.
  raw="$("$exe" preflight --model-class "$model_class" --estate "$estate" --today "$today" --format json --no-help-hints -- "$request" 2>/dev/null)" && rc=0 || rc=$?
  if [ "$rc" -ne 0 ]; then
    local upstream
    upstream="$(printf '%s' "$raw" | jq -r 'select(.schema_version == "megamind/error/v1") | .code // empty' 2>/dev/null || true)"
    emit_error megamind_error "Megamind preflight failed (exit $rc)" \
      "$(jq -cn --arg code "${upstream:-unknown}" '{upstream_code: $code}')"
    log_proof error megamind_error "" "" "$model_class" "" '[]'
    return 1
  fi
  if ! printf '%s' "$raw" | jq -e --arg s "$MEGAMIND_SCHEMA" '
      def nonempty_string: type == "string" and length > 0;
      def score_object:
        type == "object"
        and (.score | type == "number" and . >= 0 and . <= 1);
      def valid_match:
        type == "object"
        and (.name | nonempty_string)
        and (.root | nonempty_string)
        and (.access | type == "string")
        and (.routing_mode | type == "string")
        and (.confidence | score_object)
        and (.allows | type == "array")
        and all(.allows[]; type == "string")
        and (.follow_up | type == "string");
      def valid_offer:
        type == "object"
        and (.name | nonempty_string)
        and (.root | nonempty_string)
        and (.confidence | score_object);
      (.schema_version == $s)
      and (.request_hash | nonempty_string)
      and (.model_class == "local" or .model_class == "cloud")
      and (.status | type == "string")
      and ((.confidence == null) or (.confidence | type == "number"))
      and ((.preflight_id | nonempty_string))
      and ((.catalog_hash | nonempty_string))
      and ((.thresholds | type) == "object")
      and ([.thresholds.reliance_floor, .thresholds.offer_floor, .thresholds.ambiguity_band]
        | all(type == "number" and . >= 0 and . <= 1))
      and (.matches | type == "array")
      and all(.matches[]; valid_match)
      and (.offers | type == "array")
      and all(.offers[]; valid_offer)
      and ((.filtered == null) or (.filtered | type == "array"))
      and ((.redacted_count == null)
        or (.redacted_count | type == "number" and floor == . and . >= 0))
    ' >/dev/null 2>&1; then
    emit_error malformed_output "Megamind preflight output is not a valid $MEGAMIND_SCHEMA document"
    log_proof error malformed_output "" "" "$model_class" "" '[]'
    return 1
  fi

  # Normalize to the smallest permitted evidence: never echo the request text,
  # never name privacy-filtered wikis, validate every allows path to stay
  # relative and root-contained before it may be read, and replace Megamind's
  # own notes - which can name below-floor wikis, out-of-band candidates, and
  # absolute roots - with one fixed host-owned line per outcome.
  local normalized owner_identity_value exe_path exe_file_hash exe_identity_value estate_identity_value root_ids
  local route_pages route_record route_name route_root route_max route_chars route_paths
  local estate_real host_paths
  local -a disclosing_paths=()
  owner_identity_value="$(CDPATH='' cd -P -- "$FM_HOME" 2>/dev/null && pwd -P)" || owner_identity_value=
  if [ -n "$owner_identity_value" ]; then
    owner_identity_value="$(hash_text "firstmate-home/v1
$owner_identity_value" 2>/dev/null || true)"
  fi
  exe_path="$(resolved_executable "$exe" 2>/dev/null || true)"
  exe_file_hash=
  [ -n "$exe_path" ] && exe_file_hash="$(hash_file "$exe_path" 2>/dev/null || true)"
  exe_identity_value=
  [ -n "$exe_path" ] && [ -n "$exe_file_hash" ] && exe_identity_value="$(hash_text "megamind-executable/v1
$exe_path
$exe_file_hash" 2>/dev/null || true)"
  estate_identity_value="$(estate_identity "$estate" 2>/dev/null || true)"
  # Every absolute path this host resolved for itself, collected so the one field
  # forwarded as upstream prose - follow_up - can be stripped of them. A root the
  # host could not resolve still contributes the declared string it was given, so
  # a broken or absent root discloses no more than a working one.
  disclosing_paths+=("$estate")
  estate_real="$(CDPATH='' cd -P -- "$estate" 2>/dev/null && pwd -P || true)"
  [ -n "$estate_real" ] && disclosing_paths+=("$estate_real")
  root_ids='{}'
  while IFS= read -r root_record; do
    root_name="$(printf '%s' "$root_record" | jq -r '.name')"
    root_path="$(printf '%s' "$root_record" | jq -r '.root')"
    case "$root_path" in ''|null) : ;; *) disclosing_paths+=("$root_path") ;; esac
    root_real="$(CDPATH='' cd -P -- "$root_path" 2>/dev/null && pwd -P || true)"
    [ -n "$root_real" ] || continue
    disclosing_paths+=("$root_real")
    root_hash="$(hash_text "wiki-root/v1
$root_real" 2>/dev/null || true)"
    [ -n "$root_hash" ] || continue
    root_ids="$(printf '%s' "$root_ids" | jq -c --arg name "$root_name" --arg hash "$root_hash" '. + {($name):$hash}')"
  done < <(printf '%s' "$raw" | jq -c '.matches[]? | {name,root}')
  host_paths='[]'
  [ "${#disclosing_paths[@]}" -gt 0 ] \
    && host_paths="$(jq -cn '$ARGS.positional' --args -- "${disclosing_paths[@]}" 2>/dev/null || printf '%s' '[]')"
  # Descend Megamind's own ladder once per authorized root, so a match resolves
  # to the pages that answer the request instead of only the routing index that
  # lists them. A root the ladder cannot serve, or a ladder whose candidates all
  # report a route confidence below ROUTE_RELEVANCE_FLOOR, keeps its declared
  # card paths.
  # Only a full-access match descends: `route` takes no model class, so it
  # cannot re-apply the per-class restriction preflight already applied, and a
  # digest-only match must keep the digest Megamind named rather than trade it
  # for pages this model class was never authorized to load.
  route_pages='{}'
  while IFS= read -r route_record; do
    route_name="$(printf '%s' "$route_record" | jq -r '.name')"
    route_root="$(printf '%s' "$route_record" | jq -r '.root')"
    route_max="$(printf '%s' "$route_record" | jq -r '.max')"
    route_chars="$(printf '%s' "$route_record" | jq -r '.chars')"
    route_paths="$(route_page_allows "$exe" "$route_root" "$request" "$route_max" "$route_chars")"
    [ -n "$route_paths" ] && [ "$route_paths" != '[]' ] || continue
    route_pages="$(printf '%s' "$route_pages" | jq -c --arg name "$route_name" --argjson paths "$route_paths" '. + {($name):$paths}')"
  done < <(printf '%s' "$raw" | jq -c '.matches[]? | select(.access == "full") | {name, root, max: (.context_budget.max_candidates // 0), chars: (.context_budget.max_context_chars // 0)}')
  normalized="$(printf '%s' "$raw" | jq -c \
    --argjson route_pages "$route_pages" \
    --argjson host_paths "$host_paths" \
    --arg schema "$SCHEMA" \
    --arg policy "$READ_POLICY" \
    --arg owner_identity "$owner_identity_value" \
    --arg executable_identity "$exe_identity_value" \
    --arg executable_version "$version" \
    --arg estate_identity "$estate_identity_value" \
    --argjson root_ids "$root_ids" \
    "$SAFE_JQ_DEFS"'
     # A "no-match" that withheld a candidate for this model class ($filtered_count
     # > 0) is coverage denied, not coverage absent: it must read exactly like
     # privacy-filtered so nothing tells the agent to proceed from priors over a
     # withheld wiki. host_note() takes filtered_count explicitly because the
     # bare status string alone cannot distinguish the two no-match shapes.
     def host_note($filtered_count):
       if . == "matched" then "Megamind matched at least one wiki: read only the listed allows paths, within any returned budget, and nothing else."
       elif . == "ambiguous" then "Megamind found no single confident wiki: offer the listed candidates as a choice and load nothing."
       elif . == "no-match" and $filtered_count > 0 then "Megamind withheld every candidate for this model class: only the count is disclosed, never a name."
       elif . == "no-match" then "Megamind matched no wiki: do the work ordinarily and stay quiet about the estate."
       elif . == "privacy-filtered" then "Megamind withheld every candidate for this model class: only the count is disclosed, never a name."
       elif . == "unavailable" then "Megamind has no usable wiki cards: disclose the gap instead of assuming coverage."
       else "Megamind returned an unrecognized status: treat it as a blocker for substantive work." end;
     # One owner for what a match may load, so the emitted allows and the
     # binding that the reader re-derives them from can never disagree. Ranked
     # ladder pages replace the declared card paths when Megamind surfaced any
     # for a full-access match, because those pages are what the index existed
     # to point at; with no page ranked, or with access narrowed below full for
     # this model class, the declared paths stand exactly as before.
     def effective_allows($pages):
       (reduce (.allows[]? | select(safe_path)) as $path
         ([]; if index($path) then . else . + [$path] end)) as $declared |
       if (.access == "full") and ($pages | type == "array") and ($pages | length) > 0
       then $pages else $declared end;
     ([.matches[]?.allows[]? | select(safe_path | not)] | length) as $dropped |
     ([.filtered[]?] | length) as $filtered_count |
     {
       schema_version: $schema,
       outcome: .status,
       failure: null,
       model_class: .model_class,
       preflight_id: .preflight_id,
       catalog_hash: .catalog_hash,
       request_hash: .request_hash,
       confidence: .confidence,
       thresholds: {
         reliance_floor: .thresholds.reliance_floor,
         offer_floor: .thresholds.offer_floor,
         ambiguity_band: .thresholds.ambiguity_band
       },
       matches: [.matches[]? |
         . as $match |
         ({
           wiki: $match.name,
           root_identity: ($root_ids[$match.name] // null),
           access: $match.access,
           routing_mode: $match.routing_mode,
           confidence: $match.confidence.score,
           freshness: ($match.freshness | safe_freshness),
           provenance: ($match.evidence | safe_evidence),
           allows: ($match | effective_allows($route_pages[$match.name])),
           follow_up: ($match.follow_up | redact_host_paths($host_paths))
         } + (if (($match.context_budget | type) == "object")
              then {context_budget: ($match.context_budget | safe_budget)}
              else {} end))
       ],
       offers: [.offers[]? | {wiki: .name, confidence: .confidence.score}],
       authorization_binding: {
         schema_version: "fm/megamind-content-binding/v1",
         owner_identity: $owner_identity,
         executable_identity: $executable_identity,
         executable_version: $executable_version,
         estate_identity: $estate_identity,
         model_class: .model_class,
         preflight_id: .preflight_id,
         request_hash: .request_hash,
         catalog_hash: .catalog_hash,
         declared_allows: [.matches[]? | {
           wiki: .name,
           allows: effective_allows($route_pages[.name]),
           access: .access,
           routing_mode: .routing_mode,
           context_budget: (if (.context_budget | type) == "object" then (.context_budget | safe_budget) else null end)
         }],
         authorization_id: .preflight_id,
         selection_id: null
       },
       filtered_count: $filtered_count,
       redacted_count: (.redacted_count // 0),
       dropped_allows: $dropped,
       notes: [(.status | host_note($filtered_count))],
       read_policy: $policy
     }' 2>/dev/null)" || {
    emit_error malformed_output "Megamind preflight output could not be normalized"
    log_proof error malformed_output "" "" "$model_class" "" '[]'
    return 1
  }

  outcome="$(printf '%s' "$normalized" | jq -r '.outcome')"
  case "$outcome" in
    matched|ambiguous|no-match|unavailable|privacy-filtered) : ;;
    *)
      emit_error malformed_output "Megamind preflight reported a status outside the $MEGAMIND_SCHEMA set"
      log_proof error malformed_output "" "" "$model_class" "" '[]'
      return 1
      ;;
  esac
  if [ "$outcome" = ambiguous ]; then
    local retain_rc=0
    retain_ambiguous "$raw" "$request" "$normalized" || retain_rc=$?
    case "$retain_rc" in
      0) normalized="$(printf '%s' "$normalized" | jq -c --arg id "$PENDING_SELECTION_ID" '. + {selection_id:$id}')" ;;
      # No owning session lock: the offer belongs to nobody, so it is presented
      # without a continuation identity rather than retained unowned.
      2) : ;;
      *)
        emit_error selection_pending_write_failed "the ambiguous offer could not be retained privately"
        log_proof error selection_pending_write_failed "" "" "$model_class" "" '[]'
        return 1
        ;;
    esac
  fi
  log_proof "$outcome" "" \
    "$(printf '%s' "$normalized" | jq -r '.preflight_id // ""')" \
    "$(printf '%s' "$normalized" | jq -r '.request_hash // ""')" \
    "$model_class" \
    "$(printf '%s' "$normalized" | jq -r '.catalog_hash // ""')" \
    "$(printf '%s' "$normalized" | jq -c '[.matches[]?.wiki]')"
  printf '%s\n' "$normalized"
}

cmd_continue() (
  local selection_id="" offer="" pending packet_tmp raw rc
  local request request_hash preflight_id catalog_hash model_class stored_today stored_session
  local stored_exe stored_exe_hash stored_version stored_estate_hash
  local exe estate version today exe_path exe_hash estate_hash offer_root offer_root_real offer_root_identity offer_count
  local owner_identity_value executable_identity_value session_identity packet
  local estate_real host_paths
  local -a disclosing_paths=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --selection-id)
        [ $# -ge 2 ] || { printf '%s\n' "$CONTINUE_USAGE" >&2; return 2; }
        selection_id="$2"; shift 2 ;;
      --offer)
        [ $# -ge 2 ] || { printf '%s\n' "$CONTINUE_USAGE" >&2; return 2; }
        offer="$2"; shift 2 ;;
      *) printf '%s\n' "$CONTINUE_USAGE" >&2; return 2 ;;
    esac
  done
  valid_selection_id "$selection_id" || { selection_error selection_id_invalid "selection identity is not valid"; return 1; }
  if [ -z "$offer" ] || [[ "$offer" = -* ]] \
    || printf '%s' "$offer" | LC_ALL=C grep -q '[[:cntrl:]]'; then
    selection_error offer_invalid "the selected offer is not a usable wiki name"
    return 1
  fi
  command -v jq >/dev/null 2>&1 || { selection_error jq_missing "jq is required to consume a selection"; return 1; }
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || { selection_error state_invalid "the owning state directory is unavailable"; return 1; }
  [ -d "$SELECTION_DIR" ] && [ ! -L "$SELECTION_DIR" ] || { selection_error selection_missing "the pending selection is unavailable"; return 1; }
  pending="$(selection_path "$selection_id")"
  [ -f "$pending" ] && [ ! -L "$pending" ] || {
    if [ -f "$(authorization_path "$selection_id")" ] && [ ! -L "$(authorization_path "$selection_id")" ]; then
      selection_error selection_replayed "the pending selection has already been consumed"
    else
      selection_error selection_missing "the pending selection is unavailable"
    fi
    return 1
  }
  [ "$(private_mode "$pending" 2>/dev/null)" = 600 ] \
    || { selection_error selection_invalid "the pending selection is not private"; return 1; }

  local continue_lock lock_held=0
  continue_lock="$(selection_lock_path "$selection_id")"
  if ! acquire_selection_lock "$continue_lock"; then
    selection_error selection_busy "another continuation of this selection is active"
    return 1
  fi
  lock_held=1
  trap '
    rm -f -- "${packet_tmp:-}" 2>/dev/null || true
    if [ "${lock_held:-0}" = 1 ]; then rm -rf -- "$continue_lock" 2>/dev/null || true; fi
  ' EXIT

  if ! jq -e --arg id "$selection_id" '
      type == "object" and .schema_version == "fm/megamind-preflight-selection/v1"
      and .status == "pending" and .selection_id == $id
      and (.request | type == "string" and length > 0)
      and (.request_hash | type == "string" and length > 0)
      and (.preflight_id | type == "string" and length > 0)
      and (.catalog_hash | type == "string" and length > 0)
      and (.model_class == "local" or .model_class == "cloud")
      and (.executable | type == "object")
      and (.executable.path | type == "string" and length > 0)
      and (.executable.sha256 | type == "string" and test("^[A-Fa-f0-9]{64}$"))
      and (.executable.version | type == "string" and length > 0)
      and (.estate_identity | type == "string" and length > 0)
      and (.today | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))
      and (.session_identity | type == "string" and length > 0)
      and (.nonce | type == "string" and length > 0)
      and (.packet | type == "object")
      and ((.packet.request == null) or (.packet.request == .request))' "$pending" >/dev/null 2>&1; then
    selection_error selection_malformed "the pending selection is malformed"
    return 1
  fi
  request="$(jq -r '.request' "$pending")"
  request_hash="$(jq -r '.request_hash' "$pending")"
  preflight_id="$(jq -r '.preflight_id' "$pending")"
  catalog_hash="$(jq -r '.catalog_hash' "$pending")"
  model_class="$(jq -r '.model_class' "$pending")"
  stored_exe="$(jq -r '.executable.path' "$pending")"
  stored_exe_hash="$(jq -r '.executable.sha256' "$pending")"
  stored_version="$(jq -r '.executable.version' "$pending")"
  stored_estate_hash="$(jq -r '.estate_identity' "$pending")"
  stored_today="$(jq -r '.today' "$pending")"
  stored_session="$(jq -r '.session_identity' "$pending")"
  if ! jq -e --arg request "$request" '.packet.request == $request' "$pending" >/dev/null 2>&1; then
    selection_error packet_malformed "the original packet is not bound to the original request"
    return 1
  fi

  exe="$(resolve_executable)"
  estate="$(config_path "$CONFIG/megamind-estate" 2>/dev/null || true)"
  version="$(detect_version "$exe" 2>/dev/null || true)"
  today="$(current_today 2>/dev/null || true)"
  exe_path="$(resolved_executable "$exe" 2>/dev/null || true)"
  exe_hash="$(hash_file "$exe_path" 2>/dev/null || true)"
  estate_hash="$(estate_identity "$estate" 2>/dev/null || true)"
  owner_identity_value="$(CDPATH='' cd -P -- "$FM_HOME" 2>/dev/null && pwd -P)" || owner_identity_value=
  if [ -n "$owner_identity_value" ]; then
    owner_identity_value="$(hash_text "firstmate-home/v1
$owner_identity_value" 2>/dev/null || true)"
  fi
  executable_identity_value=
  [ -n "$exe_path" ] && [ -n "$exe_hash" ] && executable_identity_value="$(hash_text "megamind-executable/v1
$exe_path
$exe_hash" 2>/dev/null || true)"
  [ "$model_class" = "$(resolve_model_class "")" ] \
    || { selection_error binding_changed "the model class changed since the offer"; return 1; }
  [ "$stored_exe" = "$exe_path" ] && [ "$stored_exe_hash" = "$exe_hash" ] \
    && [ "$stored_version" = "$version" ] \
    || { selection_error binding_changed "the Megamind executable or version changed since the offer"; return 1; }
  is_selection_capable_version "$version" \
    || { selection_error selection_unsupported "this Megamind release publishes no select-offer command"; return 1; }
  [ -n "$estate_hash" ] && [ "$stored_estate_hash" = "$estate_hash" ] \
    || { selection_error binding_changed "the Megamind estate changed since the offer"; return 1; }
  [ -n "$today" ] && [ "$stored_today" = "$today" ] \
    || { selection_error binding_changed "the Megamind date changed since the offer"; return 1; }
  session_identity="$(current_session_identity)" \
    || { selection_error session_unavailable "this home has no session lock to own a selection"; return 1; }
  [ "$stored_session" = "$session_identity" ] \
    || { selection_error binding_changed "the current Firstmate session does not own this offer"; return 1; }

  offer_count="$(jq -r --arg wiki "$offer" '[.packet.offers[]? | select(.name == $wiki)] | length' "$pending")"
  [ "$offer_count" = 1 ] \
    || { selection_error offer_invalid "the selected wiki is not exactly one current offer"; return 1; }
  offer_root="$(jq -r --arg wiki "$offer" '.packet.offers[] | select(.name == $wiki) | .root' "$pending")"
  offer_root_real="$(CDPATH='' cd -P -- "$offer_root" 2>/dev/null && pwd -P)" || offer_root_real=
  offer_root_identity=
  if [ -n "$offer_root_real" ]; then
    offer_root_identity="$(hash_text "wiki-root/v1
$offer_root_real" 2>/dev/null || true)"
  fi
  # The same collection the `run` path builds, so the selected wiki's follow_up
  # is stripped of every absolute root this host resolved for itself.
  [ -n "$estate" ] && disclosing_paths+=("$estate")
  estate_real="$(CDPATH='' cd -P -- "$estate" 2>/dev/null && pwd -P || true)"
  [ -n "$estate_real" ] && disclosing_paths+=("$estate_real")
  case "$offer_root" in ''|null) : ;; *) disclosing_paths+=("$offer_root") ;; esac
  [ -n "$offer_root_real" ] && disclosing_paths+=("$offer_root_real")
  host_paths='[]'
  [ "${#disclosing_paths[@]}" -gt 0 ] \
    && host_paths="$(jq -cn '$ARGS.positional' --args -- "${disclosing_paths[@]}" 2>/dev/null || printf '%s' '[]')"
  packet_tmp="$SELECTION_DIR/.$selection_id.packet.${BASHPID:-$$}"
  # Extracted before it is published so a jq that dies partway is a preparation
  # failure rather than a truncated packet a pipeline reported as good.
  packet="$(jq -c '.packet' "$pending")" && [ -n "$packet" ] || {
    selection_error packet_unavailable "the private original preflight packet could not be prepared"
    return 1
  }
  if ! printf '%s\n' "$packet" | private_publish "$packet_tmp"; then
    selection_error packet_unavailable "the private original preflight packet could not be prepared"
    return 1
  fi

  # The command, request, packet path, estate, model class, and date all come
  # from the private pending record or the current owning-home binding. Every
  # flag sits after the subcommand, where each proven release declares it.
  raw="$("$exe_path" select-offer "$offer" --request "$request" \
    --preflight-result "$packet_tmp" --model-class "$model_class" \
    --estate "$estate" --today "$today" --format json --no-help-hints 2>/dev/null)" && rc=0 || rc=$?
  if [ "$rc" -ne 0 ]; then
    local upstream
    upstream="$(printf '%s' "$raw" | jq -r 'select(.schema_version == "megamind/error/v1") | .code // empty' 2>/dev/null || true)"
    selection_error upstream_error "Megamind could not authorize the selected offer" \
      "$(jq -cn --arg code "${upstream:-unknown}" '{upstream_code:$code}')"
    return 1
  fi
  if ! printf '%s' "$raw" | jq -e --arg schema "$MEGAMIND_SELECTION_SCHEMA" \
      --arg preflight_id "$preflight_id" --arg request_hash "$request_hash" \
      --arg catalog_hash "$catalog_hash" --arg model_class "$model_class" \
      --arg offer "$offer" --arg root "$offer_root" \
      "$SAFE_JQ_DEFS"'
      def text: type == "string" and length > 0;
      def score: type == "number" and . >= 0 and . <= 1;
      def rank: type == "number" and . >= 0;
      def valid_context_budget: type == "object"
        and ((.max_candidates == null) or (.max_candidates | positive_integer))
        and ((.max_context_chars == null) or (.max_context_chars | positive_integer));
      (.schema_version == $schema) and (.status == "authorized")
      and (.preflight_id == $preflight_id) and (.request_hash == $request_hash)
      and (.catalog_hash == $catalog_hash) and (.model_class == $model_class)
      and (.selection_id | text) and (.root_facts_hash | text)
      and (.selection | type == "object" and .status == "explicit-user-selection"
        and .basis == "selected-current-offer" and .source_disposition == "offer"
        and .source_status == "ambiguous" and .preflight_id == $preflight_id
        and .confidence_changed == false)
      and (.selected | type == "object" and .name == $offer and .root == $root)
      and (.selected.score | rank)
      and (.selected.confidence | type == "object" and (.score | score)
        and (.meets_floor | type == "boolean"))
      and (.selected.access == "full" or .selected.access == "digest-only")
      and (.selected.routing_mode | text and . != "pointer")
      and (.selected.provisional == false)
      and (.selected.allows | type == "array" and length > 0 and all(.[]; safe_path))
      and (.selected.follow_up | text)
      and ((.selected.context_budget == null) or (.selected.context_budget | valid_context_budget))
      and ((.selected.catalog_visibility == null)
        or (.selected.catalog_visibility == "full" or .selected.catalog_visibility == "redacted"))
      and ((.selected.redacted == null) or (.selected.redacted | type == "boolean"))
      and ((.selected.trust == null) or (.selected.trust == "trusted" or .selected.trust == "untrusted"
        or .selected.trust == "unknown" or .selected.trust == true or .selected.trust == false))
      and ((.selected.freshness == null) or (.selected.freshness | type == "object"))
    ' >/dev/null 2>&1; then
    selection_error malformed_result "Megamind returned a malformed or unsafe selection result"
    return 1
  fi

  local projection result_file selected_pages selected_max selected_chars
  result_file="$(authorization_path "$selection_id")"
  [ ! -e "$result_file" ] && [ ! -L "$result_file" ] \
    || { selection_error selection_replayed "the selection authorization already exists"; return 1; }
  # An explicitly selected wiki descends the same ladder a threshold match does:
  # the captain picked the wiki, not a routing index, and the selection's own
  # declared budget still bounds what may be authorized. Selecting a wiki does
  # not raise its model-class access, so a selection Megamind narrowed below
  # full keeps the exact paths it declared.
  selected_max="$(printf '%s' "$raw" | jq -r '.selected.context_budget.max_candidates // 0')"
  selected_chars="$(printf '%s' "$raw" | jq -r '.selected.context_budget.max_context_chars // 0')"
  selected_pages='[]'
  if [ "$(printf '%s' "$raw" | jq -r '.selected.access // empty')" = full ]; then
    selected_pages="$(route_page_allows "$exe_path" "$offer_root" "$request" "$selected_max" "$selected_chars")"
  fi
  [ -n "$selected_pages" ] || selected_pages='[]'
  projection="$(printf '%s' "$raw" | jq -c --arg schema "$SELECTION_SCHEMA" \
    --argjson route_pages "$selected_pages" \
    --argjson host_paths "$host_paths" \
    --arg id "$selection_id" --arg policy "$READ_POLICY" \
    --arg owner_identity "$owner_identity_value" \
    --arg executable_identity "$executable_identity_value" \
    --arg executable_version "$version" \
    --arg estate_identity "$estate_hash" \
    --arg root_identity "$offer_root_identity" \
    --arg today "$today" \
    "$SAFE_JQ_DEFS"'
      # One owner for the load surface of the selected wiki, so the projection
      # and the binding the reader re-derives it from can never disagree.
      def effective_allows:
        (reduce (.selected.allows[]? | select(safe_path)) as $path
          ([]; if index($path) then . else . + [$path] end)) as $declared |
        if (.selected.access == "full") and ($route_pages | length) > 0
        then $route_pages else $declared end;
      {schema_version:$schema,outcome:"authorized",failure:null,
       preflight_id:.preflight_id,request_hash:.request_hash,catalog_hash:.catalog_hash,
       model_class:.model_class,selection_id:$id,upstream_selection_id:.selection_id,
       root_identity:$root_identity,
       selection:{status:"explicit-user-selection",basis:"selected-current-offer",
         source_disposition:"offer",source_status:"ambiguous",preflight_id:.preflight_id,
         confidence_changed:false,threshold_matched:false},
       authorization_binding:{schema_version:"fm/megamind-content-binding/v1",
         owner_identity:$owner_identity,executable_identity:$executable_identity,
         executable_version:$executable_version,estate_identity:$estate_identity,
         model_class:.model_class,preflight_id:.preflight_id,
         request_hash:.request_hash,catalog_hash:.catalog_hash,
         declared_allows:[{wiki:.selected.name,
           allows:effective_allows,
           access:.selected.access,routing_mode:.selected.routing_mode,
           context_budget:(if (.selected.context_budget | type) == "object"
             then (.selected.context_budget | safe_budget) else null end)}],
         authorization_id:$id,selection_id:$id,today:$today},
       selected:({wiki:.selected.name,root_identity:$root_identity,score:.selected.score,
         confidence:{score:.selected.confidence.score,
           meets_floor:.selected.confidence.meets_floor},
         freshness:(.selected.freshness | safe_freshness),
         evidence:(.selected.evidence | safe_evidence),
         access:.selected.access,routing_mode:.selected.routing_mode,
         allows:effective_allows,
         follow_up:(.selected.follow_up | redact_host_paths($host_paths)),
         provisional:false}
         + (if (.selected.context_budget | type) == "object"
            then {context_budget:(.selected.context_budget | safe_budget)} else {} end)
         + (if (.selected.catalog_visibility != null)
            then {catalog_visibility:.selected.catalog_visibility} else {} end)
         + (if (.selected.redacted != null) then {redacted:.selected.redacted} else {} end)
         + (if (.selected.trust != null) then {trust:.selected.trust} else {} end)),
       notes:["Explicit selection authorizes only the selected offer current bounded access surface; it is not a threshold match."],
       read_policy:$policy}' )" || {
    selection_error projection_failed "the selection authorization could not be projected safely"
    return 1
  }
  if ! printf '%s\n' "$projection" | private_publish_exclusive "$result_file"; then
    if [ -e "$result_file" ]; then
      selection_error selection_replayed "the selection authorization already exists"
      return 1
    fi
    selection_error projection_failed "the selection authorization could not be published privately"
    return 1
  fi
  rm -f -- "$pending" || {
    selection_error retirement_failed "the consumed selection could not be retired safely"
    return 1
  }
  prune_selections "$today"
  printf '%s\n' "$projection"
)

main() {
  [ $# -ge 1 ] || { printf 'usage: fm-megamind-preflight.sh classify|classify-stdin|classify-provenance|run|continue|check ...\n' >&2; return 2; }
  local cmd="$1"; shift
  case "$cmd" in
    classify)
      [ $# -eq 1 ] || { printf 'usage: fm-megamind-preflight.sh classify "<request text>"\n' >&2; return 2; }
      classify "$1"
      ;;
    classify-stdin)
      [ $# -eq 0 ] || { printf 'usage: fm-megamind-preflight.sh classify-stdin\n' >&2; return 2; }
      local classify_stdin_text
      classify_stdin_text="$(cat)"
      classify "$classify_stdin_text"
      ;;
    classify-provenance)
      [ $# -eq 1 ] || { printf 'usage: fm-megamind-preflight.sh classify-provenance credential-submission\n' >&2; return 2; }
      classify_provenance "$1"
      ;;
    run) cmd_run "$@" ;;
    continue) cmd_continue "$@" ;;
    check) cmd_check ;;
    *) printf 'usage: fm-megamind-preflight.sh classify|classify-stdin|classify-provenance|run|continue|check ...\n' >&2; return 2 ;;
  esac
}

main "$@"
