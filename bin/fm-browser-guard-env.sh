#!/usr/bin/env bash
# fm-browser-guard-env.sh - the launch environment text that turns the agent
# browser guard on for a worker firstmate starts.
#
# Usage:
#   bin/fm-browser-guard-env.sh --command   # print the guard's export snippet
#   bin/fm-browser-guard-env.sh --help
#
# bin/fm-spawn.sh embeds the printed snippet at the head of every launch command
# it builds - crewmate, scout, and secondmate, on a fresh spawn and on a
# relaunch, on every harness - so the guard is established by the launch layer
# rather than by a worker remembering an instruction. Because it is an export
# statement inside the launch command, it also survives the launch-env-allowlist
# `env -i` wrapper and a compound raw launch, the same way
# COMPACT_ADVISER_DISABLE does.
#
# The snippet exports:
#   FM_BROWSER_GUARD=1   the marker that says this pane is guarded
#   PATH=<shims>:$PATH   the `open` and `osascript` shims ahead of the real tools
#   NODE_OPTIONS=--require <preload>  the Node preload, appended to whatever
#                        NODE_OPTIONS the pane already carries
#   LAVISH_AXI_NO_OPEN=1 lavish-axi's own switch for suppressing its local
#                        browser launch, so a worker's visual review still
#                        serves and prints its URL instead of hitting the shim's
#                        refusal path
#
# Everything is evaluated in the pane's own shell, so `$PATH` and `$NODE_OPTIONS`
# expand there, not here.
#
# The snippet is deliberately a plain sequence of `export` statements and
# nothing else - no `if`, no `case`, no `fi` - because the launch command text is
# read as a word list by firstmate's own tests and helpers (see
# tests/fm-spawn-dispatch-profile.test.sh), and a compound statement in it would
# break that reading rather than the launch. Whether the guard files exist is
# therefore decided here, when the launch is built, not in the pane: a home whose
# checkout lacks them gets a warning-only snippet, and a secondmate's own spawn
# builds its own snippet from its own checkout. A worker whose launch carries the
# guard twice (a secondmate's worker inheriting its own environment) passes
# `--require` twice, which Node resolves through the module cache as one load.
#
# docs/browser-guard.md owns the contract. The shims and the preload own their
# own halves of the enforcement.

set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHIM_DIR="$ROOT/bin/fm-browser-guard-bin"
PRELOAD="$ROOT/bin/fm-browser-guard-preload.cjs"

usage() {
  cat <<'EOF'
Usage: bin/fm-browser-guard-env.sh --command

  --command   Print the shell snippet that turns the agent browser guard on in a
              launched pane: the guard marker, the shim directory on PATH, and
              the Node preload in NODE_OPTIONS. bin/fm-spawn.sh embeds it at the
              head of every launch command.
  --help      Print this help.

The snippet is one line of plain export statements and carries no state of its
own. It is safe to apply twice: a duplicate --require resolves through Node's
module cache as a single load, and a duplicate shim directory on PATH is inert.
EOF
}

# fm_bg_quote <text>: single-quote for the pane shell. Every byte except NUL can
# be represented this way, including the quote itself and any command
# substitution a hostile path embeds, so a checkout whose directory name carries
# shell syntax can neither break the snippet nor make it execute something.
fm_bg_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

# fm_bg_node_embeddable <path>: true when the path can be embedded in the
# NODE_OPTIONS value. Node parses NODE_OPTIONS with double quotes and no escape
# sequences, so a path carrying a quote, a backslash, a dollar sign, or a
# backtick cannot be represented there and the Node half of the guard is skipped
# with a warning instead of emitting a broken assignment.
fm_bg_node_embeddable() {
  [ -n "$1" ] || return 1
  ! printf '%s' "$1" | LC_ALL=C grep -q '[^A-Za-z0-9._/+@,:= -]'
}

guard_command() {
  local q_shim q_warning q_unusable
  q_shim=$(fm_bg_quote "$SHIM_DIR")
  q_warning=$(fm_bg_quote "fm-browser-guard: warning: the browser guard is not installed at $ROOT; agent browser launches in this pane are unguarded")
  q_unusable=$(fm_bg_quote "fm-browser-guard: warning: $PRELOAD cannot be named in NODE_OPTIONS, so Node browser launches in this pane are unguarded")
  if [ ! -r "$PRELOAD" ] || [ ! -x "$SHIM_DIR/open" ]; then
    printf '%s\n' "printf '%s\\n' $q_warning >&2;"
    return 0
  fi
  if ! fm_bg_node_embeddable "$PRELOAD"; then
    # shellcheck disable=SC2016 # $PATH expands in the pane shell, not here.
    printf '%s\n' "export FM_BROWSER_GUARD=1; export LAVISH_AXI_NO_OPEN=1; export PATH=$q_shim:\$PATH; printf '%s\\n' $q_unusable >&2;"
    return 0
  fi
  # The NODE_OPTIONS value needs double quotes around the path, because that is
  # the only quoting Node's own parser understands; the shell-side double quotes
  # below are escaped so the pane shell writes them into the value.
  # shellcheck disable=SC2016 # every $ below expands in the pane shell, not here.
  printf '%s\n' \
    "export FM_BROWSER_GUARD=1; export LAVISH_AXI_NO_OPEN=1; export PATH=$q_shim:\$PATH; export NODE_OPTIONS=\"--require \\\"$PRELOAD\\\"\${NODE_OPTIONS:+ \$NODE_OPTIONS}\";"
}

case "${1:-}" in
--command)
  [ "$#" -eq 1 ] || {
    usage >&2
    exit 2
  }
  guard_command
  ;;
--help | -h)
  usage
  ;;
*)
  usage >&2
  exit 2
  ;;
esac
