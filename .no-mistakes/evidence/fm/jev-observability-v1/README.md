# Live validation evidence - fm/jev-observability-v1 (e26ea66e)

All runs used a disposable lab FM_HOME minted with bin/fm-lab-home.sh; the real
TypeSafe key was read from the fleet .env into process env only (never written).

| File | Shows |
|---|---|
| jev-cli-transcript.txt | real fm-jev.sh yes/pick/batch calls; 9-option pick refused (single + batch); 8-option pick answered; jev-calls.jsonl rows with ts, caller (task:/home:), items {type, options, conf} |
| spend-week-before.json / spend-week-after.json | `week --hours 168` over real ~/.claude + ~/.pi sessions, base vs target: target adds claudeEqTokens (~0.88B vs 6.05B raw) and claudeEqWeights; zero-valued family keys kept |
| spend-rollup-after.json | rollup v4 with claudeEqWeights and trailing168h.byFamily.claude.claudeEqTokens |
| claude-eq-crosscheck.txt + crosscheck-claude-eq.py | independent recomputation on a snapshot of one real transcript equals the ledger exactly |
| dispatch-receipt-transcript*.txt | real fm-dispatch-resolve.sh (typed Jev) receipts carry top-level selected_rule matching the decided rule; decisions.jsonl too |
| brief-preflight-transcript.txt | brief with DoD -> silent, verdict has_acceptance; without -> warning, missing_acceptance |
| done-verify-retired-transcript.txt | real fm-wake-drain.sh presenting a worker done: line: base writes a skipped shadow-done-verify record, target writes none; presentation identical |
| test-*.log | targeted test files for the changed scripts (runoff-overturn receipt case is fake-curl driven) |
