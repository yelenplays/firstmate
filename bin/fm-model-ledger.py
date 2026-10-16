#!/usr/bin/env python3
"""Preserve a minimal task outcome before teardown retires meta/status.

Usage: fm-model-ledger.py --state <dir> --data <dir> <task-id>
Writes data/model-ledger.jsonl, once per task + spawn_gen, under an append lock.
Only allowlisted scalar facts and event counts survive, never message/brief
text, account-root paths, report paths, or other private metadata. Missing
measurements are null, not zero. Secondmates are not task outcomes.
Re-dispatches are the relaunch count fm-spawn.sh records in the meta. Pipeline
review rounds are the distinct (run, round) pairs with a completed review
invocation that no-mistakes recorded read-only in its state database for the
task branch since its creation; they stay null when the worktree, branch, or
repository cannot be matched, and agent invocation counts are never substituted.
Cross-review uses the latest accepted review for the recorded head (when known).
Claude weighted tokens are copied only from the task spend snapshot teardown
refreshes just before this runs. Write failures stop cleanup so records remain
retryable.
"""

import argparse
import fcntl
import json
import math
import os
import re
import sqlite3
import subprocess
import sys
import time
from pathlib import Path


def token(value, model=False):
    pattern = r"[A-Za-z0-9][A-Za-z0-9._+\[\]-]*"
    if model:
        pattern += r"(?:/[A-Za-z0-9][A-Za-z0-9._+\[\]-]*)?"
    return value if isinstance(value, str) and re.fullmatch(pattern, value) else None


def number(value):
    if isinstance(value, bool):
        return None
    try:
        n = float(value)
        return n if math.isfinite(n) and n >= 0 else None
    except (TypeError, ValueError):
        return None


def json_rows(path):
    try:
        with path.open() as stream:
            for line in stream:
                try:
                    row = json.loads(line)
                    if isinstance(row, dict):
                        yield row
                except ValueError:
                    continue
    except FileNotFoundError:
        pass


def git(worktree, *args):
    out = subprocess.run(["git", "-C", worktree, *args], capture_output=True, text=True, timeout=10, check=True)
    return out.stdout.strip()

def pipeline_review_rounds(worktree):
    try:
        if not worktree or not os.path.isdir(worktree):
            return None
        branch = git(worktree, "symbolic-ref", "--quiet", "--short", "HEAD")
        common = git(worktree, "rev-parse", "--path-format=absolute", "--git-common-dir")
        repo = os.path.dirname(common) if os.path.basename(common) == ".git" else common
        stamps = git(worktree, "reflog", "show", "--date=unix", "--format=%gd", "refs/heads/" + branch, "--").splitlines()
        match = re.search(r"@\{(\d+)\}$", stamps[-1]) if stamps else None
        since = int(match[1]) if match else 0
        root = os.environ.get("NM_HOME") or os.path.expanduser("~/.no-mistakes")
        database = Path(root) / "state.sqlite"
        with sqlite3.connect(database.resolve().as_uri() + "?mode=ro", uri=True, timeout=5) as db:
            repos = db.execute("SELECT id FROM repos WHERE working_path = ?", (repo,)).fetchall()
            if len(repos) != 1:
                return None
            return db.execute(
                "SELECT COUNT(*) FROM (SELECT DISTINCT i.run_id, i.round FROM agent_invocations i "
                "JOIN runs r ON r.id = i.run_id WHERE r.repo_id = ? AND r.branch = ? AND r.created_at >= ? "
                "AND i.purpose = 'review' AND i.exit_status = 'ok')",
                (repos[0][0], branch, since),
            ).fetchone()[0]
    except (OSError, ValueError, sqlite3.Error, subprocess.SubprocessError):
        return None

def record(state, data, task):
    meta = {}
    for line in (state / (task + ".meta")).read_text().splitlines():
        key, sep, value = line.partition("=")
        if sep:
            meta[key] = value
    if meta.get("kind") == "secondmate":
        return
    counts = {"needs-decision": 0, "blocked": 0}
    final = None
    status = state / (task + ".status")
    if status.exists():
        for line in status.read_text().splitlines():
            match = re.match(r"^(working|needs-decision|blocked|paused|done|failed)(?:\s+\[[^\]\n]*\])*\s*:", line)
            if match:
                final = match[1]
                if final in counts:
                    counts[final] += 1
    row = {
        "task": task,
        "spawn_gen": token(meta.get("spawn_gen")),
        "recorded_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "kind": token(meta.get("kind")),
        "harness": token(meta.get("harness")),
        "model": token(meta.get("model"), model=True),
        "effort": token(meta.get("effort")),
        "provider": token(meta.get("provider") or meta.get("account_provider")),
        "pool": token(meta.get("pool") or meta.get("account")),
        "final_state": final,
        "needs_decision_count": counts["needs-decision"],
        "blocked_count": counts["blocked"],
        "redispatches": number(meta.get("redispatches")),
        "pipeline_review_rounds": pipeline_review_rounds(meta.get("worktree")),
        "cross_review_verdict": None,
        "claude_eq_tokens": None,
    }
    head = meta.get("independent_review_head") or meta.get("pr_head")
    for review in json_rows(data / task / "cross-review.jsonl"):
        if review.get("kind") == "review" and review.get("accepted") is True and (not head or review.get("head") == head):
            if review.get("verdict") in ("success", "failure"):
                row["cross_review_verdict"] = review["verdict"]
    try:
        spend = json.loads((state / (task + ".spend")).read_text())
        if isinstance(spend, dict) and spend.get("task") == task and spend.get("status") == "ok" and isinstance(spend.get("totals"), dict):
            row["claude_eq_tokens"] = number(spend["totals"].get("claudeEqTokens"))
    except (FileNotFoundError, ValueError):
        pass
    data.mkdir(parents=True, exist_ok=True)
    fd = os.open(data / "model-ledger.jsonl", os.O_RDWR | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "r+b") as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        content = stream.read()
        for line in content.splitlines():
            try:
                prior = json.loads(line)
            except ValueError:
                continue
            if isinstance(prior, dict) and prior.get("task") == task and prior.get("spawn_gen") == row["spawn_gen"]:
                return
        prefix = b"\n" if content and not content.endswith(b"\n") else b""
        stream.write(prefix + json.dumps(row, separators=(",", ":")).encode() + b"\n")
        stream.flush()
        os.fsync(stream.fileno())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state", required=True, type=Path)
    parser.add_argument("--data", required=True, type=Path)
    parser.add_argument("task")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9_-][A-Za-z0-9._-]*", args.task):
        parser.error("invalid task id")
    try:
        record(args.state, args.data, args.task)
    except (OSError, ValueError, TypeError) as exc:
        print("fm-model-ledger: cannot preserve task outcome: %s" % exc, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
