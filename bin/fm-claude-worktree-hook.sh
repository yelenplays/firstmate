#!/usr/bin/env bash
# Install or remove Firstmate's Claude crewmate lifecycle hooks in a task worktree.
#
# This command is the sole owner of the edit to
# <worktree>/.claude/settings.local.json. A project may keep its own file there -
# permissions the captain pre-approved, hooks the project already had, and it may
# be tracked in git - so install MERGES Firstmate's hooks into the existing
# document and never rewrites it wholesale. A missing or empty file has nothing to
# preserve and is simply written; malformed, symlinked, and structurally
# surprising settings are refused without any write, so a file Firstmate cannot
# read is never silently replaced.
#
# <hooks-json> is an optional file holding an object that maps each Claude hook
# event name to the command Firstmate installs for it, so the caller owns the
# command text and this script owns the file. Without it the hook set is the one
# Stop hook that touches <turn-ended-path>, which is what an older task recorded.
#
# install records what it found in <backup>, plus the exact hooks it added, so
# remove can put the file back the way it was: original bytes when the task
# changed nothing else, the pruned document when the task added settings of its
# own, and deletion only for a file (and .claude directory) Firstmate itself
# created. remove takes out only the command hooks install recorded, so a
# project's own hooks on the same events are never touched.
#
# install prints one word: "owned" when the settings file is Firstmate's own
# creation (fm-spawn keeps those out of git's view), "merged" when it belongs to
# the project.
#
# Usage:
#   fm-claude-worktree-hook.sh install <worktree> <turn-ended-path> <backup-path> [<hooks-json>]
#   fm-claude-worktree-hook.sh remove  <worktree> <turn-ended-path> <backup-path> [<hooks-json>]
set -u

case "${1:-}" in
  install|remove) ACTION=$1 ;;
  -h|--help)
    sed -n '2,31{s/^# \{0,1\}//;p;}' "$0"
    exit 0
    ;;
  *)
    printf 'usage: %s install|remove <worktree> <turn-ended-path> <backup-path> [<hooks-json>]\n' "${0##*/}" >&2
    exit 2
    ;;
esac

if [ "$#" -lt 4 ] || [ "$#" -gt 5 ]; then
  printf 'usage: %s install|remove <worktree> <turn-ended-path> <backup-path> [<hooks-json>]\n' "${0##*/}" >&2
  exit 2
fi

if ! command -v python3 >/dev/null 2>&1; then
  printf 'fm-claude-worktree-hook: refused: python3 is required to edit .claude/settings.local.json without discarding it.\n' >&2
  exit 1
fi

python3 - "$ACTION" "$2" "$3" "$4" "${5:-}" <<'PY'
import base64
import json
import os
import re
import stat
import sys
import tempfile

ACTION, WORKTREE, TURNEND, BACKUP, HOOKS_SPEC = sys.argv[1:6]

SETTINGS_REL = os.path.join(".claude", "settings.local.json")
CLAUDE_DIR = os.path.join(WORKTREE, ".claude")
SETTINGS = os.path.join(WORKTREE, SETTINGS_REL)
INDENT_LINE = re.compile(rb"\n(\x20+)\S")


def refuse(reason: str) -> None:
    print(f"fm-claude-worktree-hook: refused: {reason}", file=sys.stderr)
    raise SystemExit(1)


if not os.path.isdir(WORKTREE):
    refuse(f"worktree is missing or not a directory at {WORKTREE}.")
if not TURNEND.startswith("/") or not TURNEND.endswith(".turn-ended"):
    refuse(f"turn-end marker must be an absolute .turn-ended path, got {TURNEND}.")
if "'" in TURNEND:
    # The hook command single-quotes this path for the shell Claude runs it in.
    refuse("turn-end marker path contains a single quote.")

# Resolve symlinks in the marker's directory so install and remove agree on the
# hook command even when they are handed the same state directory by different
# names (a symlinked TMPDIR or home is the common case).
TURNEND = os.path.join(
    os.path.realpath(os.path.dirname(TURNEND)), os.path.basename(TURNEND)
)
COMMAND = f"touch '{TURNEND}'"
EVENT_NAME = re.compile(r"[A-Za-z][A-Za-z0-9]*\Z")
# The legacy hook set: one Stop hook touching this task's turn-end marker. It is
# what a task installed before Firstmate carried lifecycle hooks recorded, so it
# stays the default and keeps remove working against an older backup record.
LEGACY_HOOKS = [("Stop", COMMAND)]


def load_hooks():
    """Return the [(event, command)] pairs this invocation owns."""
    if not HOOKS_SPEC:
        return list(LEGACY_HOOKS)
    try:
        with open(HOOKS_SPEC, "rb") as stream:
            spec_raw = stream.read()
    except OSError as error:
        refuse(f"hook specification could not be read at {HOOKS_SPEC}: {error}.")
    try:
        spec = json.loads(spec_raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        refuse(f"hook specification at {HOOKS_SPEC} is not valid JSON ({error}).")
    if not isinstance(spec, dict) or not spec:
        refuse(f"hook specification at {HOOKS_SPEC} must be a non-empty object.")
    pairs = []
    for event, command in spec.items():
        if not isinstance(event, str) or not EVENT_NAME.match(event):
            refuse(f"hook specification names an unusable event: {event!r}.")
        if not isinstance(command, str) or not command:
            refuse(f"hook specification has no usable command for {event}.")
        pairs.append((event, command))
    return pairs


def encode_hooks(pairs) -> str:
    return base64.b64encode(
        json.dumps([list(pair) for pair in pairs]).encode("utf-8")
    ).decode("ascii")


def decode_hooks(encoded: str):
    """Return the recorded pairs, or None when the record predates them."""
    if not encoded:
        return None
    try:
        decoded = json.loads(base64.b64decode(encoded).decode("utf-8"))
    except Exception:
        refuse(f"install record has an unreadable hook set at {BACKUP}.")
    if not isinstance(decoded, list) or not decoded:
        refuse(f"install record has an unusable hook set at {BACKUP}.")
    pairs = []
    for item in decoded:
        if (
            not isinstance(item, list)
            or len(item) != 2
            or not all(isinstance(part, str) for part in item)
        ):
            refuse(f"install record has an unusable hook entry at {BACKUP}.")
        pairs.append((item[0], item[1]))
    return pairs


HOOKS = load_hooks()


def read_settings():
    """Return (exists, is_empty, raw_bytes, mode) after refusing anything unsafe."""
    if os.path.lexists(CLAUDE_DIR) and (
        os.path.islink(CLAUDE_DIR) or not os.path.isdir(CLAUDE_DIR)
    ):
        refuse(f".claude is not a regular directory at {CLAUDE_DIR}.")
    if not os.path.lexists(SETTINGS):
        return False, False, b"", None
    info = os.lstat(SETTINGS)
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        refuse(f"{SETTINGS_REL} is not a regular non-symlink file at {SETTINGS}.")
    with open(SETTINGS, "rb") as stream:
        raw = stream.read()
    return True, raw.strip() == b"", raw, stat.S_IMODE(info.st_mode)


def parse(raw: bytes):
    """Parse settings bytes into a JSON object, refusing anything else."""
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as error:
        refuse(f"{SETTINGS_REL} is not UTF-8: {error}.")
    try:
        doc = json.loads(text)
    except json.JSONDecodeError as error:
        refuse(
            f"{SETTINGS_REL} is not valid JSON ({error}); "
            "repair or remove it - Firstmate will not overwrite it."
        )
    if not isinstance(doc, dict):
        refuse(f"{SETTINGS_REL} is valid JSON but not an object.")
    hooks = doc.get("hooks")
    if hooks is not None and not isinstance(hooks, dict):
        refuse(f"{SETTINGS_REL} has an unexpected non-object 'hooks' value.")
    if isinstance(hooks, dict):
        for event, _command in HOOKS:
            existing = hooks.get(event)
            if existing is not None and not isinstance(existing, list):
                refuse(
                    f"{SETTINGS_REL} has an unexpected non-array 'hooks.{event}' value."
                )
    return doc


def serialize(doc, raw: bytes) -> bytes:
    """Render doc with the indentation and trailing newline the file already used."""
    match = INDENT_LINE.search(raw)
    indent = len(match.group(1)) if match else 2
    text = json.dumps(doc, indent=indent, ensure_ascii=False)
    if not raw or raw.endswith(b"\n"):
        text += "\n"
    return text.encode("utf-8")


def atomic_write(path: str, data: bytes, mode: int) -> None:
    fd, temporary = tempfile.mkstemp(
        prefix=f".{os.path.basename(path)}.", dir=os.path.dirname(path)
    )
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "wb") as stream:
            fd = -1
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    except Exception:
        if fd >= 0:
            os.close(fd)
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def is_ours(hook, command: str) -> bool:
    return (
        isinstance(hook, dict)
        and hook.get("type") == "command"
        and hook.get("command") == command
    )


def already_installed(doc, event: str, command: str) -> bool:
    for entry in doc.get("hooks", {}).get(event, []):
        if isinstance(entry, dict) and isinstance(entry.get("hooks"), list):
            if any(is_ours(hook, command) for hook in entry["hooks"]):
                return True
    return False


def prune(doc, pairs):
    """Drop this task's command hooks and any container they leave empty."""
    hooks = doc.get("hooks")
    if not isinstance(hooks, dict):
        return doc
    for event, command in pairs:
        existing = hooks.get(event)
        if not isinstance(existing, list):
            continue
        kept = []
        for entry in existing:
            if isinstance(entry, dict) and isinstance(entry.get("hooks"), list):
                entry = dict(entry)
                entry["hooks"] = [
                    hook for hook in entry["hooks"] if not is_ours(hook, command)
                ]
                if not entry["hooks"]:
                    continue
            kept.append(entry)
        if kept:
            hooks[event] = kept
        else:
            del hooks[event]
    if not hooks:
        del doc["hooks"]
    return doc


def write_backup(
    exists: bool, empty: bool, raw: bytes, mode, dir_created: bool, hooks
) -> None:
    record = "".join(
        (
            f"existed={int(exists)}\n",
            f"empty={int(empty)}\n",
            f"dir_created={int(dir_created)}\n",
            f"mode={'' if mode is None else oct(mode)}\n",
            f"original_b64={base64.b64encode(raw).decode('ascii')}\n",
            f"hooks_b64={encode_hooks(hooks)}\n",
        )
    )
    os.makedirs(os.path.dirname(BACKUP) or ".", exist_ok=True)
    atomic_write(BACKUP, record.encode("utf-8"), 0o600)


def rewrite_backup_hooks(record, hooks) -> None:
    """Keep the original-settings fields and record the current hook set."""
    updated = dict(record)
    updated["hooks_b64"] = encode_hooks(hooks)
    body = "".join(f"{key}={value}\n" for key, value in updated.items())
    atomic_write(BACKUP, body.encode("utf-8"), 0o600)


def read_backup():
    """Return the install-time record, or None for a task installed without one."""
    if not os.path.lexists(BACKUP):
        return None
    info = os.lstat(BACKUP)
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        refuse(f"install record is not a regular non-symlink file at {BACKUP}.")
    record = {}
    with open(BACKUP, "rb") as stream:
        for line in stream.read().decode("utf-8", "replace").splitlines():
            key, _, value = line.partition("=")
            record[key] = value
    if "existed" not in record:
        refuse(f"install record is unreadable at {BACKUP}.")
    return record


try:
    if ACTION == "install":
        exists, empty, raw, mode = read_settings()
        dir_created = not os.path.lexists(CLAUDE_DIR)
        # A respawn re-installs into a file this task already touched, so the
        # first record is the one that names the project's original settings.
        backup = read_backup()
        recorded = decode_hooks(backup.get("hooks_b64", "")) if backup else None
        # A caller that names no hook set is restoring, not respawning - a refused
        # teardown puts back the hooks the task actually had. Falling back to the
        # legacy default there would strip a running crewmate's lifecycle hooks
        # and leave the record naming hooks that are no longer the ones installed.
        if recorded is not None and not HOOKS_SPEC:
            HOOKS = recorded
        doc = {} if (not exists or empty) else parse(raw)
        if backup is None:
            write_backup(exists, empty, raw, mode, dir_created, HOOKS)
            project_owned = exists and not empty
        else:
            project_owned = backup.get("existed") == "1" and backup.get("empty") != "1"
            # A respawn may carry a different hook set; the record must name the
            # hooks that are actually in the file so remove prunes exactly those.
            if recorded != HOOKS:
                rewrite_backup_hooks(backup, HOOKS)
        if dir_created:
            os.makedirs(CLAUDE_DIR, exist_ok=True)
        added = False
        for event, command in HOOKS:
            if already_installed(doc, event, command):
                continue
            doc.setdefault("hooks", {}).setdefault(event, []).append(
                {"hooks": [{"type": "command", "command": command}]}
            )
            added = True
        if added:
            atomic_write(SETTINGS, serialize(doc, raw), 0o600 if mode is None else mode)
        print("merged" if project_owned else "owned")
    else:
        exists, empty, raw, mode = read_settings()
        backup = read_backup()
        if not exists:
            raise SystemExit(0)
        # The record names the hooks install actually added, so remove needs no
        # second copy of the specification and can never strip a project's own
        # hook that happens to sit on the same event.
        recorded = decode_hooks(backup.get("hooks_b64", "")) if backup else None
        if recorded is not None:
            HOOKS = recorded
        doc = {} if empty else parse(raw)
        before = json.dumps(doc, sort_keys=True)
        pruned = prune(doc, HOOKS)
        changed = json.dumps(pruned, sort_keys=True) != before
        # No record means a task installed before Firstmate kept one: back then the
        # file was always Firstmate's own, so an empty pruned document is disposable.
        original_existed = backup is not None and backup.get("existed") == "1"
        original_empty = backup is not None and backup.get("empty") == "1"
        original_raw = (
            base64.b64decode(backup.get("original_b64", "")) if backup else b""
        )
        if not pruned and not original_existed:
            os.unlink(SETTINGS)
            if backup is not None and backup.get("dir_created") == "1":
                try:
                    os.rmdir(CLAUDE_DIR)
                except OSError:
                    pass
        elif not pruned and original_empty:
            atomic_write(SETTINGS, b"", 0o600 if mode is None else mode)
        elif backup is not None and original_existed and not original_empty and pruned == parse(original_raw):
            # Nothing else changed the file, so restore its exact original bytes.
            atomic_write(SETTINGS, original_raw, 0o600 if mode is None else mode)
        elif changed:
            atomic_write(SETTINGS, serialize(pruned, raw), 0o600 if mode is None else mode)
except OSError as error:
    refuse(f"filesystem operation failed: {error}.")
PY
