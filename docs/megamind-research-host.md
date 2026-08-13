# Megamind research host lane

The host research lane executes an already-authorized deterministic plan and never decides whether research is authorized.

Its executable owner is [`bin/fm-megamind-research.sh`](../bin/fm-megamind-research.sh), whose header and `--help` surface own the versioned plan, result, adapter, quarantine, receipt, retry, cancellation, and fresh-admission mechanics.

The lane accepts only `fm/megamind-research-plan/v1` documents with a fresh governed admission and a matching model-class binding.

Search, browser, and YouTube-transcript adapters are fixed argv programs that return `fm/megamind-retrieval/v1` JSON.

The host rejects unsafe schemes, credentials, private or loopback addresses, redirects, unsupported MIME types, oversized bodies, excessive cost, expired deadlines, and invalid adapter output before it becomes research evidence.

Raw bytes and pure schema-bound extraction results are kept outside wiki roots in a mode-0700 private quarantine with mode-0600 files and immutable SHA-256 identities.

Tool receipts contain typed source and tool hashes, attempts, costs, latency, and outcomes without prompts, source bodies, credentials, private facts, or URLs.

A blocked fetch remains visible as `research-pending` and is never silently retried as an answer.

A completed retrieval also remains `research-pending` until a fresh governed admission accepts the original request identity through the `resume` command.

The host stores no answer and does not edit wikis, publish research, invoke paid sources, or grant standing autonomous writes.

Deterministic fake adapter coverage lives in [`tests/fm-megamind-research.test.sh`](../tests/fm-megamind-research.test.sh).
