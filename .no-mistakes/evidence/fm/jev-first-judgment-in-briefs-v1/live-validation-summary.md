# Live validation — Jev-first standing instruction (fm/jev-first-judgment-in-briefs-v1)

Change under test: `bin/fm-dod-lib.sh` owns one `fm_jev_first_rule`; `bin/fm-brief.sh`
renders it as rule 8 in every ship and scout brief; `bin/fm-spawn.sh` appends it to a
Claude task worker's `--append-system-prompt`.

## What was driven live

1. **Real brief generation** — `bin/fm-brief.sh` run directly (no doubles) for
   `--mode no-mistakes|direct-PR|local-only`, `--scout`, and `--secondmate`.
   All four worker scaffolds carry rule 8 with identical bytes; the secondmate
   supervisor charter carries none. See `artifacts/brief-rule-modes.txt`,
   `artifacts/ship-brief-no-mistakes.md`, `artifacts/scout-brief.md`.

2. **Real launch emission through a real tmux pane** — `bin/fm-spawn.sh` run
   for a ship, a scout, and a secondmate against a private tmux server/socket.
   The pane resolved a lab shim for the external tools only (`treehouse get`
   that cd's into a pre-created isolated worktree, and a `claude` recorder); the
   pane shell is a real shell executing the real emitted command. The recorder
   captures the exact argv the command hands to `claude`:
   - ship/scout: `ARG[3]=--append-system-prompt`, `ARG[4]` = the trust statement
     followed by the Jev-first rule, as one argument.
   - secondmate: no `--append-system-prompt`, no rule.
   See `artifacts/claude-argv-*.txt`, `artifacts/spawn-output-*.txt`.

3. **Rule parity / quoting adversarial check** — the rule extracted from the
   delivered `--append-system-prompt` is byte-identical to rule 8 in the brief
   (717 bytes) for both ship and scout, and contains zero apostrophes, so the
   single-quoted shell embedding in `launch_template` cannot break. See
   `artifacts/rule-parity.txt`.

## Targeted suites

- `bash tests/fm-brief.test.sh` — pass (includes `test_ship_and_scout_carry_advisory_jev_rule`).
- `bash tests/fm-spawn-dispatch-profile.test.sh` — pass (includes the updated
  launch-command expectation and the secondmate omission).

## Why no screenshot/GIF

The change has no rendered UI surface; its end-user artifacts are generated
prompt files and a tmux-typed launch command. The reviewer-visible evidence is
those real artifacts plus the recorded argv above.
