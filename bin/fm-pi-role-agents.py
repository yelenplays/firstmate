#!/usr/bin/env python3
"""Provision the orchestrated-delivery definitions before a Pi-family launch.

Usage: fm-pi-role-agents.py [--check]

fm-spawn runs this inside the new pane before Pi, so both processes resolve the
same PI_CODING_AGENT_DIR (default ~/.pi/agent). No project files or trust records
are written. Sources live alongside the orchestrated-delivery skill, not under
.pi/agents: arbitrary project worktrees discover the installed global copies.

Only the six fm-orchestrated-* names are managed. Each installed file carries a
content digest: modified, unowned, linked, or otherwise conflicting destinations
refuse the whole preflight without overwriting them. Intact managed files converge
to this code root's definitions. --check is read-only and requires exact current
copies. Publication is per-file atomic and serialized across Firstmate homes;
a stopped install converges on its next invocation. This installs definitions,
not the third-party pi-interactive-subagents package or provider credentials.
"""

import argparse
import fcntl
import hashlib
import os
from pathlib import Path
import re
import stat
import sys
import tempfile


ROLES = ("explorer", "researcher", "worker", "tester", "reviewer", "integrator")
SOURCES = Path(__file__).resolve().parent.parent / ".agents/skills/orchestrated-delivery/agents"
STAMP = b"firstmate-content-sha256: "


def stamped(content):
    if not content.startswith(b"---\n"):
        raise ValueError("definition must begin with YAML frontmatter")
    return b"---\n" + STAMP + hashlib.sha256(content).hexdigest().encode() + b"\n" + content[4:]


def intact(content):
    match = re.match(rb"---\nfirstmate-content-sha256: ([a-f0-9]{64})\n", content)
    return bool(match and hashlib.sha256(b"---\n" + content[match.end():]).hexdigest().encode() == match[1])


def current(path):
    try:
        info = path.lstat()
    except FileNotFoundError:
        return None
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise ValueError(f"refusing linked or non-regular definition: {path}")
    return path.read_bytes()


def atomic_write(path, content):
    fd, tmp = tempfile.mkstemp(prefix=".fm-role-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(content)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def provision(check=False):
    config = Path(os.environ.get("PI_CODING_AGENT_DIR", str(Path.home() / ".pi/agent"))).expanduser()
    agents = config / "agents"
    desired = {
        agents / f"fm-orchestrated-{role}.md": stamped((SOURCES / f"fm-orchestrated-{role}.md").read_bytes())
        for role in ROLES
    }

    def reconcile():
        observed = {path: current(path) for path in desired}
        # Validate every destination before writing any file.
        for path, content in observed.items():
            if content is not None and not intact(content):
                raise ValueError(f"refusing unowned or edited definition: {path}")
            if check and content != desired[path]:
                raise ValueError(f"definition missing or out of date: {path}")
        if not check:
            for path, content in desired.items():
                if observed[path] != content:
                    atomic_write(path, content)

    if check:
        reconcile()
        return
    agents.mkdir(parents=True, exist_ok=True)
    # This lock is outside project resources and is shared across all homes
    # using this Pi config directory. Do not unlink a held flock inode.
    lock_path = config / ".fm-role-agents.lock"
    fd = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "r+") as lock:
        info = os.fstat(lock.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise ValueError(f"refusing linked or non-regular lock: {lock_path}")
        fcntl.flock(lock, fcntl.LOCK_EX)
        reconcile()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true", help="verify current installed copies without writing")
    args = parser.parse_args()
    try:
        provision(args.check)
    except (OSError, ValueError) as error:
        print(f"fm-pi-role-agents: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
