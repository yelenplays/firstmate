# Gateway family CLI validation

Head: `3ae453910d728f5eba4f2ea14865a5b009d7fec0`.

Executed the real cross-review CLI against disposable local Git history and isolated task records, using a fresh `pi --list-models` capture from this run. No CLI mocks, remote PR mutations, worker launches, or AI review claims. Report-consumer cases use explicitly synthetic reports. This change is CLI-only; no rendered UI requires screenshots.

The regression was reproduced using the pre-fix cross-review CLI from `1a9afa58` with the current resolver, then re-driven using the current CLI against the same task records. Older records remain unchanged on disk while status and planning correctly re-resolve their maker.

## Plan recognized DeepSeek and GLM gateway tasks without catalog maker evidence

```text
$ bash bin/fm-cross-review.sh status new-pi-opencode-go-deepseek --json
{
  "task": "new-pi-opencode-go-deepseek",
  "head": "1fe201a78a5a047ac5e2b25972c826aad3bb26f1",
  "mode": "direct-PR",
  "builder": {
    "family": "deepseek",
    "source": "pi provider-qualified model opencode-go/deepseek-v4.1-flash identifies maker deepseek (resolved from the recorded harness and model; the record predates family recording)"
  },
  "pipeline_review": "N/A: direct-PR mode runs no pipeline review",
  "independent_review": "MISSING: no one-shot review is recorded for 1fe201a78a5a047ac5e2b25972c826aad3bb26f1, and direct-PR mode runs no pipeline review",
  "confirm": "MISSING: no confirm 1fe201a78a5a047ac5e2b25972c826aad3bb26f1 is recorded"
}

exit=0
```

```text
$ bash bin/fm-cross-review.sh plan new-pi-opencode-go-deepseek
task=new-pi-opencode-go-deepseek
head=1fe201a78a5a047ac5e2b25972c826aad3bb26f1
builder_family=deepseek
action=spawn-reviewer
kind=review
reason=no one-shot review is recorded for 1fe201a78a5a047ac5e2b25972c826aad3bb26f1, and direct-PR mode runs no pipeline review
reviewer_id=new-pi-opencode-go-deepseek-xr-1fe201a7
reviewer_harness=pi
reviewer_model=openai-codex/gpt-6.1-sol
reviewer_effort=high
reviewer_family=openai

exit=0
```

```text
$ bash bin/fm-cross-review.sh status new-pi-opencode-go-zhipu --json
{
  "task": "new-pi-opencode-go-zhipu",
  "head": "1fe201a78a5a047ac5e2b25972c826aad3bb26f1",
  "mode": "direct-PR",
  "builder": {
    "family": "zhipu",
    "source": "pi provider-qualified model opencode-go/glm-5.3 identifies maker zhipu (resolved from the recorded harness and model; the record predates family recording)"
  },
  "pipeline_review": "N/A: direct-PR mode runs no pipeline review",
  "independent_review": "MISSING: no one-shot review is recorded for 1fe201a78a5a047ac5e2b25972c826aad3bb26f1, and direct-PR mode runs no pipeline review",
  "confirm": "MISSING: no confirm 1fe201a78a5a047ac5e2b25972c826aad3bb26f1 is recorded"
}

exit=0
```

```text
$ bash bin/fm-cross-review.sh plan new-pi-opencode-go-zhipu
task=new-pi-opencode-go-zhipu
head=1fe201a78a5a047ac5e2b25972c826aad3bb26f1
builder_family=zhipu
action=spawn-reviewer
kind=review
reason=no one-shot review is recorded for 1fe201a78a5a047ac5e2b25972c826aad3bb26f1, and direct-PR mode runs no pipeline review
reviewer_id=new-pi-opencode-go-zhipu-xr-1fe201a7
reviewer_harness=pi
reviewer_model=openai-codex/gpt-6.1-sol
reviewer_effort=high
reviewer_family=openai

exit=0
```

## Re-plan previously recorded unknown DeepSeek and GLM tasks

```text
$ bash bin/.fm-cross-review-before-test.sh status existing-pi-deepseek --json
{
  "task": "existing-pi-deepseek",
  "head": "1fe201a78a5a047ac5e2b25972c826aad3bb26f1",
  "mode": "direct-PR",
  "builder": {
    "family": "unknown",
    "source": "pi catalog provider opencode-go serves several makers"
  },
  "pipeline_review": "N/A: direct-PR mode runs no pipeline review",
  "independent_review": "MISSING: no one-shot review is recorded for 1fe201a78a5a047ac5e2b25972c826aad3bb26f1, and direct-PR mode runs no pipeline review",
  "confirm": "MISSING: no confirm 1fe201a78a5a047ac5e2b25972c826aad3bb26f1 is recorded"
}

exit=0
```

```text
$ bash bin/.fm-cross-review-before-test.sh plan existing-pi-deepseek
task=existing-pi-deepseek
head=1fe201a78a5a047ac5e2b25972c826aad3bb26f1
builder_family=unknown
action=escalate
reason=the builder family is unknown (pi catalog provider opencode-go serves several makers), so no reviewer can be proven to be another family

exit=0
```

```text
$ bash bin/fm-cross-review.sh status existing-pi-deepseek --json
{
  "task": "existing-pi-deepseek",
  "head": "1fe201a78a5a047ac5e2b25972c826aad3bb26f1",
  "mode": "direct-PR",
  "builder": {
    "family": "deepseek",
    "source": "pi provider-qualified model opencode-go/deepseek-v4.1-flash identifies maker deepseek (re-resolved previously unknown recorded harness and model)"
  },
  "pipeline_review": "N/A: direct-PR mode runs no pipeline review",
  "independent_review": "MISSING: no one-shot review is recorded for 1fe201a78a5a047ac5e2b25972c826aad3bb26f1, and direct-PR mode runs no pipeline review",
  "confirm": "MISSING: no confirm 1fe201a78a5a047ac5e2b25972c826aad3bb26f1 is recorded"
}

exit=0
```

```text
$ bash bin/fm-cross-review.sh plan existing-pi-deepseek
task=existing-pi-deepseek
head=1fe201a78a5a047ac5e2b25972c826aad3bb26f1
builder_family=deepseek
action=spawn-reviewer
kind=review
reason=no one-shot review is recorded for 1fe201a78a5a047ac5e2b25972c826aad3bb26f1, and direct-PR mode runs no pipeline review
reviewer_id=existing-pi-deepseek-xr-1fe201a7
reviewer_harness=pi
reviewer_model=openai-codex/gpt-6.1-sol
reviewer_effort=high
reviewer_family=openai

exit=0
```

## Unknown, unqualified and misleading gateway names still require a decision

```text
$ bash bin/fm-cross-review.sh status bad-0 --json
{
  "task": "bad-0",
  "head": "1fe201a78a5a047ac5e2b25972c826aad3bb26f1",
  "mode": "direct-PR",
  "builder": {
    "family": "unknown",
    "source": "pi catalog provider opencode-go serves several makers"
  },
  "pipeline_review": "N/A: direct-PR mode runs no pipeline review",
  "independent_review": "MISSING: no one-shot review is recorded for 1fe201a78a5a047ac5e2b25972c826aad3bb26f1, and direct-PR mode runs no pipeline review",
  "confirm": "MISSING: no confirm 1fe201a78a5a047ac5e2b25972c826aad3bb26f1 is recorded"
}

exit=0
```

```text
$ bash bin/fm-cross-review.sh plan bad-0
task=bad-0
head=1fe201a78a5a047ac5e2b25972c826aad3bb26f1
builder_family=unknown
action=escalate
reason=the builder family is unknown (pi catalog provider opencode-go serves several makers), so no reviewer can be proven to be another family

exit=0
```

```text
$ bash bin/fm-cross-review.sh status bad-1 --json
{
  "task": "bad-1",
  "head": "1fe201a78a5a047ac5e2b25972c826aad3bb26f1",
  "mode": "direct-PR",
  "builder": {
    "family": "unknown",
    "source": "pi catalog provider opencode-go serves several makers"
  },
  "pipeline_review": "N/A: direct-PR mode runs no pipeline review",
  "independent_review": "MISSING: no one-shot review is recorded for 1fe201a78a5a047ac5e2b25972c826aad3bb26f1, and direct-PR mode runs no pipeline review",
  "confirm": "MISSING: no confirm 1fe201a78a5a047ac5e2b25972c826aad3bb26f1 is recorded"
}

exit=0
```

```text
$ bash bin/fm-cross-review.sh plan bad-1
task=bad-1
head=1fe201a78a5a047ac5e2b25972c826aad3bb26f1
builder_family=unknown
action=escalate
reason=the builder family is unknown (pi catalog provider opencode-go serves several makers), so no reviewer can be proven to be another family

exit=0
```

## Re-resolution preserves known and earlier unknown builder history

```text
$ bash bin/fm-cross-review.sh status history-0 --json
{
  "task": "history-0",
  "head": "1fe201a78a5a047ac5e2b25972c826aad3bb26f1",
  "mode": "direct-PR",
  "builder": {
    "family": "openai",
    "source": "known earlier builder"
  },
  "pipeline_review": "N/A: direct-PR mode runs no pipeline review",
  "independent_review": "MISSING: no one-shot review is recorded for 1fe201a78a5a047ac5e2b25972c826aad3bb26f1, and direct-PR mode runs no pipeline review",
  "confirm": "MISSING: no confirm 1fe201a78a5a047ac5e2b25972c826aad3bb26f1 is recorded"
}

exit=0
```

```text
$ bash bin/fm-cross-review.sh plan history-0
task=history-0
head=1fe201a78a5a047ac5e2b25972c826aad3bb26f1
builder_family=openai
action=spawn-reviewer
kind=review
reason=no one-shot review is recorded for 1fe201a78a5a047ac5e2b25972c826aad3bb26f1, and direct-PR mode runs no pipeline review
reviewer_id=history-0-xr-1fe201a7
reviewer_harness=claude
reviewer_model=claude-opus-5-5
reviewer_effort=high
reviewer_family=anthropic

exit=0
```

```text
$ bash bin/fm-cross-review.sh status history-1 --json
{
  "task": "history-1",
  "head": "1fe201a78a5a047ac5e2b25972c826aad3bb26f1",
  "mode": "direct-PR",
  "builder": {
    "family": "openai,unknown",
    "source": "mixed builder history"
  },
  "pipeline_review": "N/A: direct-PR mode runs no pipeline review",
  "independent_review": "MISSING: no one-shot review is recorded for 1fe201a78a5a047ac5e2b25972c826aad3bb26f1, and direct-PR mode runs no pipeline review",
  "confirm": "MISSING: no confirm 1fe201a78a5a047ac5e2b25972c826aad3bb26f1 is recorded"
}

exit=0
```

```text
$ bash bin/fm-cross-review.sh plan history-1
task=history-1
head=1fe201a78a5a047ac5e2b25972c826aad3bb26f1
builder_family=openai,unknown
action=escalate
reason=the builder family is unknown (mixed builder history), so no reviewer can be proven to be another family

exit=0
```

## Same-maker gateway reviews and legacy Z.ai aliases cannot establish independence

```text
$ bash bin/fm-cross-review.sh collect same-0 same-reviewer-0
recorded accepted=no kind=review head=1fe201a78a5a047ac5e2b25972c826aad3bb26f1 reason=the reviewer family zhipu is not provably different from the builder's zhipu

exit=0
```

```text
$ bash bin/fm-cross-review.sh collect same-1 same-reviewer-1
recorded accepted=no kind=review head=1fe201a78a5a047ac5e2b25972c826aad3bb26f1 reason=the reviewer family zhipu is not provably different from the builder's zai

exit=0
```

```text
$ bash bin/fm-cross-review.sh collect same-2 same-reviewer-2
recorded accepted=no kind=review head=1fe201a78a5a047ac5e2b25972c826aad3bb26f1 reason=the reviewer family zai is not provably different from the builder's zhipu

exit=0
```

```text
$ bash bin/fm-cross-review.sh collect same-3 same-reviewer-3
recorded accepted=no kind=review head=1fe201a78a5a047ac5e2b25972c826aad3bb26f1 reason=the reviewer family deepseek is not provably different from the builder's deepseek

exit=0
```

```text
$ bash bin/fm-cross-review.sh collect same-4 same-reviewer-4
recorded accepted=no kind=review head=1fe201a78a5a047ac5e2b25972c826aad3bb26f1 reason=the reviewer family zhipu is not provably different from the builder's deepseek,zhipu

exit=0
```

## Different gateway makers count only for the exact reviewed or confirmed head

```text
$ bash bin/fm-cross-review.sh collect independent other-maker
recorded accepted=no kind=review head=1fe201a78a5a047ac5e2b25972c826aad3bb26f1 reason=the report declares 90da5c064717457e7a8dd3c786ac54d5d6e60159, not the requested head 1fe201a78a5a047ac5e2b25972c826aad3bb26f1

exit=0
```

```text
$ bash bin/fm-cross-review.sh collect independent other-maker
recorded accepted=yes kind=review verdict=success head=1fe201a78a5a047ac5e2b25972c826aad3bb26f1 reviewer_family=deepseek

exit=0
```

```text
$ bash bin/fm-cross-review.sh status independent --json
{
  "task": "independent",
  "head": "1fe201a78a5a047ac5e2b25972c826aad3bb26f1",
  "mode": "direct-PR",
  "builder": {
    "family": "zhipu",
    "source": "opencode provider-qualified model opencode-go/glm-5.3 identifies maker zhipu (re-resolved previously unknown recorded harness and model)"
  },
  "pipeline_review": "N/A: direct-PR mode runs no pipeline review",
  "independent_review": {
    "source": "one-shot",
    "family": "deepseek",
    "verdict": "success",
    "head": "1fe201a78a5a047ac5e2b25972c826aad3bb26f1",
    "reviewer": "other-maker",
    "detail": "one-shot review by other-maker (deepseek) declares head 1fe201a78a5a047ac5e2b25972c826aad3bb26f1 with verdict success; the builder is zhipu"
  },
  "confirm": "MISSING: no confirm 1fe201a78a5a047ac5e2b25972c826aad3bb26f1 is recorded"
}

exit=0
```

```text
$ bash bin/fm-cross-review.sh plan independent
task=independent
head=1fe201a78a5a047ac5e2b25972c826aad3bb26f1
builder_family=zhipu
action=none
reason=one-shot review by other-maker (deepseek) declares head 1fe201a78a5a047ac5e2b25972c826aad3bb26f1 with verdict success; the builder is zhipu

exit=0
```

```text
$ bash bin/fm-cross-review.sh collect independent confirmer
recorded accepted=yes kind=confirm verdict=success head=1fe201a78a5a047ac5e2b25972c826aad3bb26f1 reviewer_family=deepseek

exit=0
```

```text
$ bash bin/fm-cross-review.sh verify-confirm independent 1fe201a78a5a047ac5e2b25972c826aad3bb26f1
confirmed 1fe201a78a5a047ac5e2b25972c826aad3bb26f1 by confirmer (deepseek); the builder is zhipu

exit=0
```

```text
$ bash bin/fm-cross-review.sh verify-confirm independent 90da5c064717457e7a8dd3c786ac54d5d6e60159

not confirmed: the recorded confirmation is for 1fe201a78a5a047ac5e2b25972c826aad3bb26f1, not 90da5c064717457e7a8dd3c786ac54d5d6e60159
exit=1
```

All disposable Git repositories, task records, and test caches were removed after execution. Complete inputs, outputs, persisted records, and commands are in `live-cli-transcript.json`; the repeatable driver is `live-cli-driver.py`.
