#!/usr/bin/env bash
# Shared wake classifier: the common source of truth for captain-relevant status
# tests, declared-external-wait vocabulary, and the working/paused absorb
# classification that makes no-verb signal and stale-pane wakes safe to absorb.
# Sourced by BOTH the always-on watcher
# (bin/fm-watch.sh) and the away-mode daemon (bin/fm-supervise-daemon.sh) so the
# overlapping triage policy lives in one place instead of two copies that can
# drift apart.
#
# Most functions are pure, side-effect-free reads of status files: each takes
# what it needs as arguments and touches no globals beyond the optional
# FM_CAPTAIN_RE override. Consumers layer their own dedup/marker state on top (the
# daemon keeps its escalation-digest seen-markers; the watcher keeps its .seen-*
# signatures).
#
# The one exception is the absorb classification (crew_absorb_class and its
# working/paused wrappers). It is NOT a pure status-file read: it reuses
# bin/fm-crew-state.sh, which may make a bounded no-mistakes call, to decide
# whether a crew that just stopped its turn or went stale is working, deliberately
# paused, or neither. Callers run it ONLY on no-verb signal handling and first
# sighting of a stale hash, never on every wake, so the per-wake triage stays
# cheap.

# Directory of this library, used to locate the sibling fm-crew-state.sh reader.
# Resolved at source time from BASH_SOURCE so it works whether sourced by a
# bin/ script (which sets its own SCRIPT_DIR) or directly by a test.
_FM_CLASSIFY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_CLASSIFY_LIB_DIR="."

# The crew current-state reader used for the "provably working" decision.
# Overridable so tests can stub the run-step/pane verdict without a real worktree
# or no-mistakes install; absent, it points at the real sibling script.
FM_CREW_STATE_BIN="${FM_CREW_STATE_BIN:-$_FM_CLASSIFY_LIB_DIR/fm-crew-state.sh}"

# Captain-relevant status verbs. A status line carrying any of these is work
# firstmate must see. Lines without these verbs are no-verb signals: the watcher
# absorbs them only with positive provably-working evidence, while the daemon uses
# its away-mode classification. FM_CAPTAIN_RE overrides the whole set when a home
# needs a custom verb vocabulary; absent, this default applies.
#
# Free-text tokens (PR ready, checks green, ready in branch, merged) exist only for
# legacy lines that lack a standard terminal verb. status_is_captain_relevant is
# verb-aware: a nonterminal working: or paused: line never becomes captain-relevant
# merely because its prose contains one of those tokens (for example
# "working: rebased onto merged #76").
FM_CLASSIFY_CAPTAIN_RE_DEFAULT='done:|needs-decision:|blocked:|failed:|PR ready|checks green|ready in branch|merged'

# The deliberate-external-wait verb. A crew (or firstmate steering it) appends
#   paused: <reason>
# to declare it is intentionally idling on a KNOWN external dependency - an
# upstream release, a vendor rate-limit reset, a scheduled window. Unlike
# `blocked:` (stuck, firstmate must help) an idle `paused:` pane is EXPECTED, so
# the stale path absorbs it instead of escalating a possible wedge. It is
# deliberately NOT in the captain-relevant set above: a pause is a "stop
# wedge-nagging this idle pane" signal, not work to keep surfacing. This constant
# is the ONE definition of the verb; both the watcher and the daemon read it here
# (status_is_paused) rather than hardcoding the literal, so the vocabulary cannot
# drift between the two consumers. FM_CLASSIFY_PAUSED_VERB overrides it.
FM_CLASSIFY_PAUSED_VERB_DEFAULT='paused'

# Bounded re-surface cadence for a declared pause or a dead-agent captain hold.
# Far longer than the wedge threshold (FM_STALE_ESCALATE_SECS, default 240s), it
# avoids nagging a deliberate wait while ensuring a forgotten hold cannot rot
# invisibly - it re-surfaces once for a recheck every window. One hour by default;
# both consumers read FM_PAUSE_RESURFACE_SECS with this default so the cadence has
# one owner.
# shellcheck disable=SC2034 # Read by the watcher and daemon (fm-watch.sh, fm-supervise-daemon.sh), not this lib.
FM_PAUSE_RESURFACE_SECS_DEFAULT=3600

# The resolution verb and durable-backlog-transfer verb that CLOSE a keyed
# status decision opened by needs-decision or blocked. See status_open_decisions
# below for the status-fold contract. The transfer verb is written only after
# fm-decision-hold.sh has verified the corresponding captain-held backlog item.
FM_CLASSIFY_RESOLVE_VERB_DEFAULT='resolved'
FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT='captain-held'

# Return the last non-blank line of a status file (empty if missing/blank).
last_status_line() {
  local f=$1
  [ -e "$f" ] || return 0
  grep -v '^[[:space:]]*$' "$f" 2>/dev/null | tail -1
}

# 0 if the given (last) status line's leading verb is a real terminal captain verb
# (done, needs-decision, blocked, failed). Free-text tokens alone never count here;
# callers that need legacy free-text matching use status_is_captain_relevant.
status_is_terminal_verb() {
  local line=$1 verb
  [ -n "$line" ] || return 1
  verb=$(status_line_verb "$line")
  case "$verb" in
    done|needs-decision|blocked|failed) return 0 ;;
    *) return 1 ;;
  esac
}

# 0 if the given (last) status line matches a captain-relevant verb.
# Verb-aware by default: terminal verbs always match; nonterminal progress verbs
# (working, resolved, captain-held) and paused never match from free-text prose;
# only lines without those leading verbs may still match free-text tokens for
# legacy bare lines such as "merged" or "PR ready".
status_is_captain_relevant() {
  local line=$1 verb
  [ -n "$line" ] || return 1
  status_is_paused "$line" && return 1
  verb=$(status_line_verb "$line")
  case "$verb" in
    working|resolved|captain-held|"${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}")
      return 1
      ;;
  esac
  if [ -z "${FM_CAPTAIN_RE+x}" ]; then
    case "$verb" in
      done|needs-decision|blocked|failed) return 0 ;;
    esac
  fi
  printf '%s' "$line" | grep -qiE "${FM_CAPTAIN_RE:-$FM_CLASSIFY_CAPTAIN_RE_DEFAULT}"
}

# 0 if a status line's leading verb is the pause verb (paused: <reason>). A pure
# read of the line itself, so the daemon's classify_stale can reuse the last line
# it already read without a fm-crew-state.sh call. Matches only the verb before the
# first colon, so a reason mentioning "paused" elsewhere does not false-match.
status_is_paused() {  # <status-line>
  local line=$1 verb
  [ -n "$line" ] || return 1
  verb=$(status_line_verb "$line")
  [ "$verb" = "${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}" ]
}

# 0 if a status line declares either an external-wait pause or a verified
# captain-held transfer.
# Both declarations can intentionally leave an exited crew's endpoint idle, so
# the watcher applies its bounded pause cadence when agent death confirms that
# no live decision gate is being silenced.
status_is_paused_or_captain_held() {  # <status-line>
  local line=$1 verb
  status_is_paused "$line" && return 0
  [ -n "$line" ] || return 1
  verb=$(status_line_verb "$line")
  [ "$verb" = "${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}" ]
}

# --- durable keyed decisions ------------------------------------------------
#
# The status stream is an append-only EVENT log. Reading it last-event-wins
# (last_status_line above) cannot represent "an earlier decision is still open
# after a later, unrelated event": a subsequent done/paused/working line silently
# masks a still-open needs-decision. status_open_decisions is the ONE authoritative
# statement of the status-fold contract that fixes this - a needs-decision/blocked
# line OPENS a keyed decision, and only an explicit resolution or a verified
# captain-held backlog transfer referencing that key CLOSES it; a later unrelated
# terminal line never clears an open captain decision.
#
# Decision key grammar (backward-compatible with the existing "<verb>: <note>"
# format): an OPTIONAL "[key=<slug>]" token sits between the verb and the colon,
#   needs-decision [key=api-shape]: <summary>
#   resolved       [key=api-shape]: <how it was decided>
# A line with no token uses the key "default", preserving the historical
# one-open-decision-per-task behavior (a bare "resolved:" closes "default").
# The three parsers are pure reads of a single line; the verb parser strips any
# key token before the colon so the leading word is recovered cleanly.
status_line_verb() {  # <status-line> -> leading verb word
  local v=${1%%:*}
  v=${v%%\[key=*}
  v=${v#"${v%%[![:space:]]*}"}
  v=${v%"${v##*[![:space:]]}"}
  printf '%s' "$v"
}
status_line_note() {  # <status-line> -> prose note after the first colon, trimmed
  local n
  case "$1" in
    *:*) n=${1#*:} ;;
    *) n=$1 ;;
  esac
  n=${n#"${n%%[![:space:]]*}"}
  # A structured decision record (below) sits in front of the prose why. Strip it
  # so every existing consumer keeps displaying the same human-readable summary.
  if _fm_record_note_has_block "$n"; then
    n=${n#*\}}
    n=${n#"${n%%[![:space:]]*}"}
  fi
  printf '%s' "$n"
}
_fm_decision_key() {  # <status-line> -> key slug, or "default" when no token
  local prefix=${1%%:*} k
  case "$prefix" in
    *\[key=*\]*)
      k=${prefix#*\[key=}
      k=${k%%\]*}
      case "$k" in
        ''|*[!A-Za-z0-9._-]*) return 1 ;;
        *) printf '%s' "$k" ;;
      esac
      ;;
    *) printf 'default' ;;
  esac
}

# --- structured decision record (v1) ----------------------------------------
#
# This library is the single owner of the record's WIRE FORM, its field names,
# and its length ceilings. bin/fm-decision-hold.sh owns authoring, storage, and
# rendering; it validates through decision_record_validate below rather than
# restating any limit.
#
# A needs-decision or blocked status line MAY carry an authored, machine-readable
# record in front of its prose why, as one brace-delimited block of field=value
# pairs joined by "|":
#
#   needs-decision [key=one-send]: {question=...|consequence=...|recommend=hold
#   |option=hold/Hold|option=send/Send it/destructive|sensitivity=private
#   |safe_preview=...} the existing prose, unchanged, as the why disclosure
#
# (always one physical line; wrapped here only for legibility.)
#
# The block sits AFTER the first colon, so every pre-record parser - the verb
# parser, the key parser, the decision fold, the watcher and the daemon - reads a
# record-carrying line exactly as it reads a prose-only line. A line with no block
# is today's line and stays valid forever; that is what keeps every already
# recorded decision working untouched.
#
# The ceilings are the measured phone budget, not taste: a collapsed notification
# body holds about 80 characters, a decision card question about 52, a
# notification title about 42, and two 44pt action buttons side by side at 320 CSS
# px hold about 16 characters each. A field that overflows its ceiling cannot be
# rendered at all, so the ceilings are enforced at authoring time.
FM_DECISION_MAX_QUESTION=52
FM_DECISION_MAX_CONSEQUENCE=100
FM_DECISION_MAX_OPTION_LABEL=16
FM_DECISION_MAX_SAFE_PREVIEW=42
FM_DECISION_MIN_OPTIONS=2
FM_DECISION_MAX_OPTIONS=4
# sensitivity CLASSIFIES a decision so a renderer can pick which authored text may
# leave the trusted session. It NEVER grants authority: who may answer which
# decision is owned by AGENTS.md section 7 and the ask-user-authority skill, and
# nothing in this library or its callers may read sensitivity to widen that.
FM_DECISION_SENSITIVITIES='normal private secret'

decision_record_field_known() {  # <field-name>
  case "$1" in
    question|consequence|recommend|option|expires_at|sensitivity|safe_preview) return 0 ;;
    *) return 1 ;;
  esac
}

# 0 when a status note OPENS with a syntactically well-formed record block.
# Pure, fork-free, and deliberately strict: an unknown field name, a missing "=",
# or a missing question means "this is prose that happens to start with a brace",
# and the note is left exactly as written.
_fm_record_note_has_block() {  # <status-note>
  local rest pair name seen_question=0
  case "$1" in '{'*) ;; *) return 1 ;; esac
  case "$1" in *'}'*) ;; *) return 1 ;; esac
  rest=${1#\{}
  rest=${rest%%\}*}
  [ -n "$rest" ] || return 1
  while [ -n "$rest" ]; do
    case "$rest" in
      *'|'*) pair=${rest%%|*}; rest=${rest#*|} ;;
      *) pair=$rest; rest='' ;;
    esac
    case "$pair" in *'='*) ;; *) return 1 ;; esac
    name=${pair%%=*}
    decision_record_field_known "$name" || return 1
    [ "$name" != question ] || seen_question=1
  done
  [ "$seen_question" = 1 ]
}

# Print the record block carried by a status line, or nothing when it carries none.
status_line_record() {  # <status-line>
  local n
  case "$1" in
    *:*) n=${1#*:} ;;
    *) n=$1 ;;
  esac
  n=${n#"${n%%[![:space:]]*}"}
  _fm_record_note_has_block "$n" || return 0
  n=${n#\{}
  printf '%s' "${n%%\}*}"
}

# Print the value of <field> in a record block, one line per occurrence. Repeated
# only for `option`; every other field appears at most once.
decision_record_get() {  # <record-block> <field>
  local rest=$1 field=$2 pair name out=''
  while [ -n "$rest" ]; do
    case "$rest" in
      *'|'*) pair=${rest%%|*}; rest=${rest#*|} ;;
      *) pair=$rest; rest='' ;;
    esac
    case "$pair" in *'='*) ;; *) continue ;; esac
    name=${pair%%=*}
    [ "$name" = "$field" ] || continue
    out="${out}${pair#*=}"$'\n'
  done
  printf '%s' "$out"
}

# 0 when a record field value is safe to carry through every surface the record
# reaches. The block separators and the body quoting/escaping of the backlog are
# structural, so a value may not contain them; the invisible separators are
# rejected because a record field is re-displayed elsewhere and U+2063 is the
# operational-input marker (bin/fm-operational-input.sh).
_fm_record_value_ok() {  # <value>
  [ -n "$1" ] || return 1
  case "$1" in
    *'|'*|*'{'*|*'}'*|*'"'*|*\\*) return 1 ;;
  esac
  case "$1" in
    *$'\xE2\x81\xA3'*|*$'\xE2\x80\x8B'*|*$'\xE2\x80\x8C'*|*$'\xE2\x80\x8D'*|*$'\xEF\xBB\xBF'*) return 1 ;;
  esac
  case "$1" in
    *[$'\x01'-$'\x1f']*|*$'\x7f'*) return 1 ;;
  esac
  return 0
}

_fm_record_slug_ok() {  # <slug>
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

_fm_record_lower() {  # <text>
  printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]'
}

_fm_record_err() {  # <message>
  printf 'decision record: %s\n' "$1" >&2
  return 1
}

# safe_preview is the ONLY field that may be rendered outside the trusted session
# - a lock screen, a redacted notification twin, a screen share. So it is checked
# for the shapes that carry evidence by accident rather than by intent: a link, an
# address or handle, a path, an identifier or amount, an opaque token, and a
# phrase lifted straight out of the evidence prose. An authored line survives all
# of these; a truncated copy of the why does not.
_fm_record_preview_ok() {  # <safe-preview> <why>
  local preview=$1 why=$2 rest word slashes=0 tail
  case "$preview" in
    *'://'*) _fm_record_err "safe_preview must not contain a link" || return 1 ;;
    *'@'*) _fm_record_err "safe_preview must not contain an address or handle" || return 1 ;;
    *'~/'*) _fm_record_err "safe_preview must not contain a path" || return 1 ;;
  esac
  case "$preview" in
    *[0-9][0-9][0-9][0-9][0-9][0-9]*)
      _fm_record_err "safe_preview must not contain an identifier or amount" || return 1 ;;
  esac
  tail=$preview
  while [ -n "$tail" ]; do
    case "$tail" in
      */*) slashes=$((slashes + 1)); tail=${tail#*/} ;;
      *) tail='' ;;
    esac
  done
  [ "$slashes" -le 1 ] || _fm_record_err "safe_preview must not contain a path" || return 1
  rest=$preview
  while [ -n "$rest" ]; do
    case "$rest" in
      *' '*) word=${rest%% *}; rest=${rest#* } ;;
      *) word=$rest; rest='' ;;
    esac
    [ "${#word}" -le 19 ] \
      || _fm_record_err "safe_preview must not contain an opaque token" || return 1
  done
  if [ -n "$why" ]; then
    case "$(_fm_record_lower "$why")" in
      *"$(_fm_record_lower "$preview")"*)
        _fm_record_err "safe_preview must be authored, not copied out of the why prose" || return 1 ;;
    esac
  fi
  return 0
}

# Validate a complete record block. Prints the first violation to stderr and
# returns 1. <why> is optional; pass the hold reason so the safe_preview leak
# checks can see the evidence the preview must not repeat.
decision_record_validate() {  # <record-block> [why]
  local block=$1 why=${2:-} rest pair name val
  local question='' consequence='' recommend='' expires='' sensitivity='' preview=''
  local opt_ids='' opt_count=0 first_safe='' id label flag

  [ -n "$block" ] || _fm_record_err "record is empty" || return 1
  rest=$block
  while [ -n "$rest" ]; do
    case "$rest" in
      *'|'*) pair=${rest%%|*}; rest=${rest#*|} ;;
      *) pair=$rest; rest='' ;;
    esac
    case "$pair" in *'='*) ;; *) _fm_record_err "field is not name=value: $pair" || return 1 ;; esac
    name=${pair%%=*}
    val=${pair#*=}
    decision_record_field_known "$name" || _fm_record_err "unknown field: $name" || return 1
    _fm_record_value_ok "$val" \
      || _fm_record_err "$name must be non-empty single-line text without | { } \" \\ or invisible characters" \
      || return 1
    case "$name" in
      option)
        opt_count=$((opt_count + 1))
        case "$val" in
          */*) ;;
          *) _fm_record_err "option must be <id>/<label>[/destructive]: $val" || return 1 ;;
        esac
        id=${val%%/*}
        label=${val#*/}
        flag=''
        case "$label" in
          */*) flag=${label#*/}; label=${label%%/*} ;;
        esac
        _fm_record_slug_ok "$id" || _fm_record_err "option id must be a slug: $id" || return 1
        case ",$opt_ids," in
          *",$id,"*) _fm_record_err "duplicate option id: $id" || return 1 ;;
        esac
        opt_ids="${opt_ids}${opt_ids:+,}$id"
        [ -n "$label" ] || _fm_record_err "option $id has no label" || return 1
        [ "${#label}" -le "$FM_DECISION_MAX_OPTION_LABEL" ] \
          || _fm_record_err "option $id label is ${#label} characters, ceiling is $FM_DECISION_MAX_OPTION_LABEL" \
          || return 1
        case "$flag" in
          ''|destructive) ;;
          *) _fm_record_err "option $id has an unknown flag: $flag" || return 1 ;;
        esac
        if [ "$opt_count" = 1 ]; then
          [ "$flag" != destructive ] || first_safe=no
        fi
        ;;
      question) [ -z "$question" ] || _fm_record_err "question is repeated" || return 1; question=$val ;;
      consequence) [ -z "$consequence" ] || _fm_record_err "consequence is repeated" || return 1; consequence=$val ;;
      recommend) [ -z "$recommend" ] || _fm_record_err "recommend is repeated" || return 1; recommend=$val ;;
      expires_at) [ -z "$expires" ] || _fm_record_err "expires_at is repeated" || return 1; expires=$val ;;
      sensitivity) [ -z "$sensitivity" ] || _fm_record_err "sensitivity is repeated" || return 1; sensitivity=$val ;;
      safe_preview) [ -z "$preview" ] || _fm_record_err "safe_preview is repeated" || return 1; preview=$val ;;
    esac
  done

  [ -n "$question" ] || _fm_record_err "question is required" || return 1
  [ "${#question}" -le "$FM_DECISION_MAX_QUESTION" ] \
    || _fm_record_err "question is ${#question} characters, ceiling is $FM_DECISION_MAX_QUESTION" || return 1
  [ -n "$consequence" ] || _fm_record_err "consequence is required" || return 1
  [ "${#consequence}" -le "$FM_DECISION_MAX_CONSEQUENCE" ] \
    || _fm_record_err "consequence is ${#consequence} characters, ceiling is $FM_DECISION_MAX_CONSEQUENCE" || return 1
  [ -n "$preview" ] || _fm_record_err "safe_preview is required" || return 1
  [ "${#preview}" -le "$FM_DECISION_MAX_SAFE_PREVIEW" ] \
    || _fm_record_err "safe_preview is ${#preview} characters, ceiling is $FM_DECISION_MAX_SAFE_PREVIEW" || return 1
  [ "$opt_count" -ge "$FM_DECISION_MIN_OPTIONS" ] \
    || _fm_record_err "a decision needs at least $FM_DECISION_MIN_OPTIONS options" || return 1
  [ "$opt_count" -le "$FM_DECISION_MAX_OPTIONS" ] \
    || _fm_record_err "a decision carries at most $FM_DECISION_MAX_OPTIONS options" || return 1
  # The first action is the one an Apple Watch double tap fires with no
  # confirmation, so it must never be the destructive answer.
  [ "$first_safe" != no ] || _fm_record_err "the first option must not be destructive" || return 1
  [ -n "$recommend" ] || _fm_record_err "recommend is required" || return 1
  case ",$opt_ids," in
    *",$recommend,"*) ;;
    *) _fm_record_err "recommend must name one of the options: $recommend" || return 1 ;;
  esac
  [ -n "$sensitivity" ] || _fm_record_err "sensitivity is required" || return 1
  case " $FM_DECISION_SENSITIVITIES " in
    *" $sensitivity "*) ;;
    *) _fm_record_err "sensitivity must be one of $FM_DECISION_SENSITIVITIES" || return 1 ;;
  esac
  if [ -n "$expires" ]; then
    case "$expires" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
      *) _fm_record_err "expires_at must be absolute UTC, YYYY-MM-DDTHH:MM:SSZ: $expires" || return 1 ;;
    esac
  fi
  _fm_record_preview_ok "$preview" "$why" || return 1
  # A private or secret decision renders its preview INSTEAD of its question, so
  # the preview has to be a deliberate redaction rather than the question again.
  if [ "$sensitivity" != normal ] && [ "$preview" = "$question" ]; then
    _fm_record_err "a $sensitivity decision needs a safe_preview distinct from its question" || return 1
  fi
  return 0
}

# Drop the record for <key> from a newline-terminated "<key>\t<verb>\t<note>" set.
# Portable (no associative arrays) so the fold runs on bash 3.2 as well as 4+.
_fm_decision_drop() {  # <open-set> <key>
  local set=$1 key=$2 line out=''
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      "$key"$'\t'*) : ;;
      *) out="${out}${line}"$'\n' ;;
    esac
  done <<EOF
$set
EOF
  printf '%s' "$out"
}
# Fold the WHOLE status stream into the set of decisions still open. Prints one
# TAB-separated "<key>\t<verb>\t<summary>" line per still-open decision, in
# most-recently-opened-last order; prints nothing when none are open. Pure read of
# the file, no globals beyond the optional FM_CLASSIFY_RESOLVE_VERB override. This
# is the durable open-set the fleet snapshot and any point-in-time consumer must use
# instead of trusting the last status line.
status_open_decisions() {  # <status-file>
  local f=$1 line verb key note resolve held open='' stripped
  [ -f "$f" ] || return 0
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  held=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
  while IFS= read -r line || [ -n "$line" ]; do
    stripped=${line//[[:space:]]/}
    [ -n "$stripped" ] || continue
    verb=$(status_line_verb "$line")
    key=$(_fm_decision_key "$line") || continue
    case "$verb" in
      needs-decision|blocked)
        note=$(status_line_note "$line")
        open=$(_fm_decision_drop "$open" "$key")
        [ -n "$open" ] && open="${open}"$'\n'
        open="${open}${key}"$'\t'"${verb}"$'\t'"${note}"$'\n'
        ;;
      "$resolve"|"$held")
        open=$(_fm_decision_drop "$open" "$key")
        [ -n "$open" ] && open="${open}"$'\n'
        ;;
    esac
  done < "$f"
  printf '%s' "$open"
}

# Fold material routed-work phases in the same keyed event stream.
# A working or declared-pause event opens or replaces one phase for its key.
# A later done, failed, needs-decision, blocked, or resolved event carrying that
# key closes the phase, because it has moved to a terminal or separately tracked
# state.
# A bare legacy event uses the default key, preserving one-phase behavior.
# This fold is evidence about whether a parent event was explicitly superseded.
# It is never authoritative current crew state, and consumers must not let an open
# phase outrank a structured home snapshot or fm-crew-state result.
_fm_status_open_activities_stream() {
  local line verb key note resolve held open='' stripped pause
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  held=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
  pause=${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}
  while IFS= read -r line || [ -n "$line" ]; do
    stripped=${line//[[:space:]]/}
    [ -n "$stripped" ] || continue
    verb=$(status_line_verb "$line")
    key=$(_fm_decision_key "$line") || continue
    case "$verb" in
      working|"$pause")
        note=$(status_line_note "$line")
        open=$(_fm_decision_drop "$open" "$key")
        [ -n "$open" ] && open="${open}"$'\n'
        open="${open}${key}"$'\t'"${verb}"$'\t'"${note}"$'\n'
        ;;
      done|failed|needs-decision|blocked|"$resolve"|"$held")
        open=$(_fm_decision_drop "$open" "$key")
        [ -n "$open" ] && open="${open}"$'\n'
        ;;
    esac
  done
  printf '%s' "$open"
}

status_open_activities() {  # <status-file-or-dash>
  local f=$1
  if [ "$f" = - ]; then
    _fm_status_open_activities_stream
    return 0
  fi
  [ -f "$f" ] || return 0
  _fm_status_open_activities_stream < "$f"
}

# task id from a recorded window target, falling back to the tmux-shaped
# "<session>:fm-<id>" form when no metadata state is available.
window_to_task() {
  local w=$1 state=${2:-${STATE:-${FM_STATE_OVERRIDE:-}}} meta mw mt t
  if [ -n "$state" ]; then
    for meta in "$state"/*.meta; do
      [ -e "$meta" ] || continue
      mw=$(grep '^window=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
      mt=$(grep '^terminal=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
      [ "$mw" = "$w" ] || [ "$mt" = "$w" ] || continue
      t=$(basename "$meta")
      t=${t%.meta}
      printf '%s' "$t"
      return 0
    done
  fi
  t="${w##*:}"; t="${t#fm-}"; printf '%s' "$t"
}

# 0 (actionable) if ANY status file listed in a "signal:" wake carries a
# captain-relevant last line; 1 otherwise. Pass the space-separated file list that
# follows the "signal:" prefix. Non-.status arguments (e.g. .turn-ended markers,
# which never carry a verb) are skipped. A 1 here is NOT "benign" on its own: a
# no-verb signal (a bare turn-end, a working: note) is only benign when the crew is
# also provably working (signal_crew_provably_working below); otherwise it surfaces.
signal_reason_is_actionable() {  # <file> ...
  local f last
  for f in "$@"; do
    [ -e "$f" ] || continue
    case "$f" in *.status) ;; *) continue ;; esac
    last=$(last_status_line "$f")
    [ -n "$last" ] || continue
    status_is_captain_relevant "$last" && return 0
  done
  return 1
}

# Classify WHY an idle/stale crew MIGHT be safely absorbed instead of surfaced,
# from bin/fm-crew-state.sh's one authoritative current-state line
# ("state: <s> · source: <src> · <detail>"). Prints exactly one token:
#   working - an actively-running no-mistakes step (running/fixing/ci) or a busy
#             pane; the crew is legitimately mid-work on a static-looking pane
#             (e.g. waiting on CI);
#   paused  - the crew's authoritative current state is a declared external-wait
#             pause (paused:), which is EXPECTED to idle;
#   none    - neither, so the wake must surface (a stopped/finished/parked/failed/
#             torn-down/unknown crew, or an unreadable verdict).
# One fm-crew-state.sh read serves BOTH absorb reasons at once. Reading the state
# authoritatively (not the status log) is what keeps run-step precedence: a crew
# that appended paused: but then STARTED a run reports working, never paused.
# NOT a pure read: fm-crew-state.sh may make a bounded no-mistakes call, so callers
# run it only on no-verb signal and first-sighting stale paths, never every wake.
# FM_CREW_STATE_BIN lets tests stub the verdict.
crew_absorb_class() {  # <id>
  local id=$1 line state src
  [ -n "$id" ] || { printf 'none'; return; }
  line=$("$FM_CREW_STATE_BIN" "$id" 2>/dev/null) || true
  case "$line" in state:*) ;; *) printf 'none'; return ;; esac
  state=${line#state: }; state=${state%% *}
  if [ "$state" = paused ]; then printf 'paused'; return; fi
  if [ "$state" = working ]; then
    src=${line#*source: }; src=${src%% *}
    case "$src" in run-step|pane) printf 'working'; return ;; esac
  fi
  printf 'none'
}

# 0 if crew <id> shows POSITIVE evidence it is still working (crew_absorb_class
# reports `working`). This is the "provably working" predicate at the heart of
# absorb-only-when-provably-working: a no-verb turn-end or stale wake is absorbed
# ONLY when this returns 0, and SURFACED otherwise (the crew may be done, waiting
# on a decision, or wedged). For stale panes it is checked before trusting the
# status log so a pre-validation captain-relevant line does not override an active
# run. See crew_absorb_class for the exact working/paused/none decision.
crew_is_provably_working() {  # <id>
  [ "$(crew_absorb_class "$1")" = working ]
}

# 0 if crew <id>'s authoritative current state is a declared external-wait pause.
# The stale path absorbs such a crew (on a long re-surface cadence) instead of
# escalating a possible wedge.
crew_is_paused() {  # <id>
  [ "$(crew_absorb_class "$1")" = paused ]
}

# 0 (benign/absorb) if EVERY task referenced by a no-verb "signal:" wake is provably
# working; 1 (actionable/surface) if any is not, or no task can be resolved. Pass the
# same space-separated file list as signal_reason_is_actionable. Files are mapped to
# task ids by stripping the .status / .turn-ended suffix; a no-verb wake with nothing
# provably working must surface, so an empty/unresolvable list returns 1.
signal_crew_provably_working() {  # <file> ...
  local f base task seen=""
  for f in "$@"; do
    base=${f##*/}
    case "$base" in
      *.status)     task=${base%.status} ;;
      *.turn-ended) task=${base%.turn-ended} ;;
      *)            continue ;;
    esac
    [ -n "$task" ] || continue
    case " $seen " in *" $task "*) continue ;; esac
    seen="$seen $task"
    crew_is_provably_working "$task" || return 1
  done
  [ -n "$seen" ] || return 1
  return 0
}

# 0 (terminal/actionable) if a stale window's last status line is
# captain-relevant; 1 otherwise, including the no-status case. A 1 only means
# "non-terminal"; the always-on watcher then applies crew_is_provably_working,
# while the away-mode daemon applies its persistence recheck.
stale_is_terminal() {  # <window> <state>
  local win=$1 state=$2 last
  last=$(last_status_line "$state/$(window_to_task "$win" "$state").status")
  [ -n "$last" ] && status_is_captain_relevant "$last"
}

# Print "<file>\t<task>\t<last-line>" for every state/*.status whose last line is
# captain-relevant. This is the cheap fleet-scan both supervisors run as a
# catch-all backstop for a captain-relevant status the per-wake path might miss.
# No dedup is applied here: each consumer dedupes against its own seen-state (the
# daemon against .subsuper-seen-status-*, the watcher against .seen-* signatures).
scan_captain_relevant_statuses() {  # <state>
  local state=$1 f last task
  for f in "$state"/*.status; do
    [ -e "$f" ] || continue
    last=$(last_status_line "$f")
    status_is_captain_relevant "$last" || continue
    task=$(basename "$f"); task="${task%.status}"
    printf '%s\t%s\t%s\n' "$f" "$task" "$last"
  done
  return 0
}
