#!/usr/bin/env python3
"""Drive the real local digest-preview interface; no Slack transport or mocks."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path.cwd()
env = {k: v for k, v in os.environ.items() if not k.startswith(("FM_", "TASKS_AXI_"))}
with tempfile.TemporaryDirectory(prefix=".fm-live-preview-", dir=root) as scratch:
    home = Path(scratch)
    env["FM_HOME"] = str(home)

    def run(script, *args):
        print("$ FM_HOME=<disposable-worktree-home> bin/" + script + " " + " ".join(args), flush=True)
        p = subprocess.run([str(root / "bin" / script), *args], env=env, text=True,
                           capture_output=True, timeout=45)
        print(p.stdout, end="", flush=True)
        if p.stderr:
            print(p.stderr, end="", flush=True)
        print(f"exit={p.returncode}", flush=True)
        if p.returncode:
            raise RuntimeError(f"{script} failed")
        return p.stdout

    run("fm-lab-home.sh", "create", str(home))
    (home / "config/slack-bridge").write_text(
        "report-channel=#reports\ndecisions-channel=#decisions\nupdates-channel=#updates\n"
        "captain-user=U0CAPTAIN1\nlanguage=de\nboard-url=https://deck.example.invalid/board\n")
    # Standard empty local-home queue; all subsequent task mutations go through
    # the same public task and hold commands an operator uses.
    (home / "data/backlog.md").write_text("## Queued\n\n## In flight\n\n## Done\n")
    empty = run("fm-updates.sh", "digest", "--print")
    assert len(empty.splitlines()) == 5
    assert "Nichts wartet auf dich." in empty
    assert "Läuft gerade: 0" in empty
    run("fm-captain-hold.sh", "hold", "lay-freigabe", "--title", "Startseite freigeben",
        "--reason", "Entwurf ansehen und freigeben")
    run("fm-tasks-axi.sh", "list", "--state", "held", "--fields", "hold_kind")
    held = run("fm-updates.sh", "digest", "--print")
    assert len(held.splitlines()) == 5
    assert "Wartet auf dich: 1 - Startseite freigeben" in held
    assert held.splitlines()[-1] == "https://deck.example.invalid/board"
    assert not (home / "state/slack-bridge/posts").exists(), "preview must not publish"
    print(json.dumps({"local_preview": "pass", "live": True, "external_posts": 0,
                      "german_lines": len(held.splitlines()), "held_call_count": 1,
                      "home_removed_on_exit": True}, ensure_ascii=False), flush=True)
