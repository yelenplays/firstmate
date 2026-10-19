#!/usr/bin/env bash
# Focused executable-interface regressions for Slack update delivery and guards.
# Slack and gh are transport doubles: these tests never contact either service
# and are not live Slack evidence. Every assertion concerns emitted messages,
# exit codes, delivery attempts, or the persisted outcome contract, not source.
set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
python3 - "$ROOT" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(sys.argv[1])
sys.argv = [sys.argv[0]]

SLACK_DOUBLE = '''#!/usr/bin/env python3
import json, os, pathlib, sys
home = pathlib.Path(os.environ["FM_HOME"])
a = sys.argv[1:]
with (home / "transport.jsonl").open("a") as log:
    log.write(json.dumps(a, ensure_ascii=False) + "\\n")
if a[:2] == ["draft", "send"]:
    if a[2] == "d_updates" and (home / "fail-updates").exists():
        print("error: ratelimited")
        sys.exit(1)
    with (home / "delivered.jsonl").open("a") as log:
        log.write(json.dumps(a) + "\\n")
    print('ts: "1791140000000001"')
elif a[:2] == ["draft", "discard"]:
    print("discarded")
elif a[0] == "draft":
    updates = a[1] == "#updates"
    print("draft: " + ("d_updates" if updates else "d_report"))
    print('channel: "%s (%s)"' % (a[1], "C0UPDATES1" if updates else "C0REPORT01"))
else:
    sys.exit(2)
'''


class UpdatesAdversarial(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix=".fm-updates-test-", dir=ROOT)
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        for name in ("state", "config", "data", "fakebin"):
            (self.home / name).mkdir()
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(("FM_", "TASKS_AXI_"))}
        self.env.update(FM_HOME=str(self.home), FM_CHECK_TIMEOUT="30",
                        PATH=str(self.home / "fakebin") + os.pathsep + os.environ["PATH"])
        cli = self.home / "fakebin/slack-axi"
        cli.write_text(SLACK_DOUBLE)
        cli.chmod(0o755)
        (self.home / "config/slack-bridge").write_text(
            "report-channel=#reports\ndecisions-channel=#decisions\n"
            "updates-channel=#updates\nlanguage=de\ncaptain-user=U0CAPTAIN1\n"
            f"digest-hour={(time.localtime().tm_hour + 8) % 24}\n")
        (self.home / "data/backlog.md").write_text("## In flight\n")

    def run_cli(self, script, *args):
        return subprocess.run([str(ROOT / "bin" / script), *args],
                              env=self.env, text=True, capture_output=True, timeout=55)

    def add_task(self, task, title, *, yolo=False):
        meta = "kind=ship\nproject=/projects/Lay\nspawn_gen=g1\nyolo=" + ("on" if yolo else "off") + "\n"
        if yolo:
            meta += "pr=https://github.com/example/lab/pull/1\n"
        (self.home / f"state/{task}.meta").write_text(meta)
        (self.home / f"state/{task}.status").write_text(f"done [at={int(time.time()) - 90000}]: fertig\n")
        with (self.home / "data/backlog.md").open("a") as backlog:
            backlog.write(f"- [ ] {task} - {title}\n")

    def calls(self):
        log = self.home / "transport.jsonl"
        return [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []

    def show(self, name, **observed):
        print(json.dumps({"scenario": name, **observed}, ensure_ascii=False), flush=True)

    def test_failed_updates_pointer_is_retried(self):
        self.add_task("approval", "Neue Startseite")
        (self.home / "fail-updates").touch()
        args = ("post", "ready", "--task", "approval", "--project", "Lay",
                "--title", "Freigabe nötig", "--context", "Bitte dort entscheiden.",
                "--url", "https://github.com/example/lab/pull/1")
        first = self.run_cli("fm-slack-bridge.sh", *args)
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(self.run_cli("fm-slack-bridge.sh", "posted", "--task", "approval", "ready").returncode, 1,
                         "the outcome remains owed until both destinations land")
        (self.home / "fail-updates").unlink()
        before = len(self.calls())
        retry = self.run_cli("fm-slack-bridge.sh", *args)
        self.assertEqual(retry.returncode, 0, retry.stderr)
        delivered = [json.loads(line) for line in (self.home / "delivered.jsonl").read_text().splitlines()]
        self.show("retry an approval after #updates recovers", first_output=first.stdout,
                  retry_output=retry.stdout, retry_transport_calls=self.calls()[before:],
                  successful_sends=delivered,
                  outcomes=(self.home / "state/slack-bridge/outcomes").read_text())
        self.assertEqual(sum(a[2] == "d_updates" for a in delivered), 1,
                         "the recovered #updates channel must receive its missing approval pointer")
        self.assertEqual(sum(a[2] == "d_report" for a in delivered), 1,
                         "retry must not duplicate the already-delivered approval")
        self.assertEqual(self.run_cli("fm-slack-bridge.sh", "posted", "--task", "approval", "ready").returncode, 0)
        before = len(self.calls())
        self.assertEqual(self.run_cli("fm-slack-bridge.sh", *args).returncode, 0)
        self.assertEqual(len(self.calls()), before, "a fully delivered ask must not be sent again")

    def test_questions_in_options_are_rejected(self):
        result = self.run_cli("fm-slack-bridge.sh", "post", "decision", "--project", "Lay",
                              "--title", "Wie weiter?", "--context", "Bitte eine Antwort.",
                              "--option", "a=Heute starten?", "--option", "b=Morgen starten?", "--recommend", "a")
        drafts = [a[2] for a in self.calls() if a[0] == "draft" and a[1].startswith("#")]
        self.show("refuse a decision containing three questions", exit_code=result.returncode,
                  output=result.stdout, emitted_messages=drafts)
        self.assertEqual(result.returncode, 2, "more than one question must be rejected before sending")
        self.assertEqual(drafts, [])

    def test_single_option_question_is_allowed(self):
        result = self.run_cli("fm-slack-bridge.sh", "post", "decision", "--project", "Lay",
                              "--title", "Nächster Schritt", "--context", "Bitte eine Antwort.",
                              "--option", "a=Heute starten?", "--option", "b=Morgen starten", "--recommend", "a")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sum(a[:2] == ["draft", "send"] for a in self.calls()), 2)

    def test_questions_beyond_option_truncation_are_rejected(self):
        result = self.run_cli("fm-slack-bridge.sh", "post", "decision", "--title", "Wie weiter?",
                              "--option", "a=" + "x" * 90 + "?", "--recommend", "a")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(self.calls(), [])

    def test_finished_result_without_pr_has_one_link(self):
        board = "https://deck.example.com/board"
        with (self.home / "config/slack-bridge").open("a") as config:
            config.write(f"board-url={board}\n")
        self.add_task("result", "Ranking-Messung fertig")
        result = self.run_cli("fm-updates.sh", "tick")
        self.assertEqual(result.returncode, 0, result.stderr)
        messages = [a[2] for a in self.calls()
                    if a[:2] == ["draft", "#updates"]]
        self.show("a finished result without a PR still includes a useful link",
                  output=result.stdout, emitted_messages=messages)
        self.assertEqual(len(messages), 1)
        self.assertEqual(messages[0].count("https://"), 1,
                         "every finished result needs one link, including results without a PR")
        self.assertIn(f"<{board}|", messages[0],
                      "a result without a PR must link to the configured Deck board")

    def test_slow_pr_reads_do_not_starve_finished_results(self):
        gh = self.home / "fakebin/gh"
        gh.write_text("#!/usr/bin/env bash\nprintf '%s\\n' \"$3\" >> \"$FM_HOME/pr-reads\"\nsleep 4\nprintf 'OPEN\\n'\n")
        gh.chmod(0o755)
        for n in range(4):
            task = f"a{n}-auto"
            self.add_task(task, f"Auto {n}", yolo=True)
            meta = self.home / f"state/{task}.meta"
            meta.write_text(meta.read_text().replace("pull/1", f"pull/{n + 1}"))
        self.add_task("z-result", "Ranking-Messung fertig")
        polls = []
        for _ in range(2):
            started = time.monotonic()
            result = self.run_cli("fm-slack-bridge.sh", "check")
            self.assertEqual(result.returncode, 0, result.stderr)
            polls.append({"seconds": round(time.monotonic() - started, 2), "output": result.stdout})
        posted = self.run_cli("fm-slack-bridge.sh", "posted", "--task", "z-result", "finished")
        self.show("an overdue result survives repeated polls with slow PR lookups", polls=polls,
                  finished_report_exit_code=posted.returncode,
                  attempted_messages=[a[:3] for a in self.calls() if a[0] == "draft" and a[1].startswith("#")],
                  result_record_retained=(self.home / "state/z-result.meta").exists())
        self.assertEqual(posted.returncode, 0,
                         "later finished work must not be starved by repeated earlier PR lookups")
        reads = (self.home / "pr-reads").read_text().splitlines()
        self.assertEqual(len(set(reads[:4])), 4,
                         "lookups must advance through all PRs before revisiting reported ones")
        self.assertEqual(self.run_cli("fm-slack-bridge.sh", "posted", "--task", "a3-auto", "stuck").returncode, 0,
                         "later remote outcomes must also make progress across polls")


unittest.main(verbosity=2)
PY
