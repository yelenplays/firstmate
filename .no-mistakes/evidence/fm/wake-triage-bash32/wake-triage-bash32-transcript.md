=== Evidence: fm-wake-triage.sh macOS bash 3.2 empty-array fix ===

--- Host system bash (macOS stock) ---
GNU bash, version 3.2.57(1)-release (x86_64-apple-darwin24)

--- 1. PRE-FIX (base commit 1de36c0): triage under /bin/bash with NO recovered pending files ---
$ FM_STATE_OVERRIDE=<empty-state> /bin/bash bin/fm-wake-triage.sh   # base script
bin/fm-wake-triage.sh: line 30: recovered[@]: unbound variable
EXIT=1   <-- wake handling aborts, falls back to bin/fm-wake-drain.sh (the reported bug)

--- 2. POST-FIX (target commit bfb30f1): same command, same empty state ---
$ FM_STATE_OVERRIDE=<empty-state> /bin/bash bin/fm-wake-triage.sh   # fixed script
WAKE TRIAGE: 0 row(s), 0 task(s): 0 act now, 0 routine
FULL DRAIN OUTPUT: /private/tmp/claude-501/-Users-wwzz-Downloads-proxyclawd/88833871-9d1c-410a-8425-a5a54e5377ef/scratchpad/fix-state/.wake-triage.last
DRAIN OUTPUT (verbatim, except acknowledgement instruction moved to the end):
EXIT=0   <-- triage completes end-to-end

--- 3. Regression test FAILS before the fix (base bin/ swapped in, full suite) ---
/Users/marcocadornini/.no-mistakes/worktrees/a742a9bd3c66/01M3M8RG6BFQ66NYHJY4Y36FDA/bin/fm-wake-triage.sh: line 30: recovered[@]: unbound variable
not ok - triage command failed
EXIT=1   <-- suite aborts at the first triage invocation on bash 3.2.57

--- 4. Full suite AFTER the fix: bash tests/fm-wake-triage.test.sh ---
(16/16 behavior sub-tests pass, including the new
'triage completes with no recovered pending files under system bash').
The only non-ok line is 'shellcheck: command not found' — shellcheck is not
installed on this host and installing packages is forbidden in this run; remote
CI owns that sub-test.

=== Files ===
- wake-triage-suite-after-fix.log: full suite output after the fix
- this transcript: pre-fix reproduction, fix verification, fail-before check
