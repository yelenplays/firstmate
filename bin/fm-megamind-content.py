#!/usr/bin/env python3
"""Host-owned bounded reader for validated Firstmate Megamind authorizations."""
from __future__ import annotations

import argparse
import errno
import fcntl
import hashlib
import json
import os
import re
import stat
import sys
import tempfile
import time
import uuid
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple

SCHEMA = "fm/megamind-content-admission/v1"
BINDING_SCHEMA = "fm/megamind-content-binding/v1"
MAX_JSON_BYTES = 4 * 1024 * 1024
SELECTION_RE = re.compile(r"^[0-9A-Fa-f]{16,128}$")
TASK_RE = re.compile(r"^[A-Za-z0-9_.-]+$")
CARD_REL = ".megamind/wiki-card.json"


def result(code: str, admitted: bool = False, **fields: Any) -> Dict[str, Any]:
    out: Dict[str, Any] = {
        "schema_version": SCHEMA,
        "outcome": "admitted" if admitted else "refused",
        "refusal_code": None if admitted else code,
        "admission_id": fields.pop("admission_id", None),
        "authorization_id": fields.pop("authorization_id", None),
        "selection_id": fields.pop("selection_id", None),
        "wikis": fields.pop("wikis", []),
    }
    out.update(fields)
    return out


def emit(obj: Dict[str, Any], rc: int = 0) -> int:
    sys.stdout.write(json.dumps(obj, ensure_ascii=True, separators=(",", ":")) + "\n")
    return rc


def fail(code: str, rc: int = 1, **fields: Any) -> int:
    return emit(result(code, **fields), rc)


def safe_home(raw: str) -> Optional[Path]:
    if not raw or not os.path.isabs(raw):
        return None
    try:
        home = Path(raw)
        st = home.lstat()
        if not stat.S_ISDIR(st.st_mode) or home.is_symlink():
            return None
        for name in ("config", "state"):
            child = home / name
            cst = child.lstat()
            if not stat.S_ISDIR(cst.st_mode) or child.is_symlink():
                return None
        return home
    except OSError:
        return None


def private_file(path: Path) -> bool:
    try:
        st = path.lstat()
        return (
            stat.S_ISREG(st.st_mode)
            and not path.is_symlink()
            and st.st_uid == os.getuid()
            and stat.S_IMODE(st.st_mode) == 0o600
        )
    except OSError:
        return False


def load_json(path: Path) -> Optional[Dict[str, Any]]:
    if not private_file(path):
        return None
    try:
        if path.stat().st_size > MAX_JSON_BYTES:
            return None
        with path.open("rb") as fh:
            obj = json.load(fh)
        return obj if isinstance(obj, dict) else None
    except (OSError, ValueError, UnicodeError):
        return None


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> Optional[str]:
    try:
        digest = hashlib.sha256()
        with path.open("rb") as fh:
            while True:
                block = fh.read(1024 * 1024)
                if not block:
                    return digest.hexdigest()
                digest.update(block)
    except OSError:
        return None


def file_fingerprint(st: os.stat_result, digest: str) -> Dict[str, Any]:
    return {
        "dev": st.st_dev,
        "ino": st.st_ino,
        "mode": stat.S_IMODE(st.st_mode),
        "size": st.st_size,
        "mtime_ns": st.st_mtime_ns,
        "nlink": st.st_nlink,
        "sha256": digest,
    }


def root_fingerprint(st: os.stat_result) -> Dict[str, Any]:
    return {
        "dev": st.st_dev,
        "ino": st.st_ino,
        "mode": stat.S_IMODE(st.st_mode),
        "mtime_ns": st.st_mtime_ns,
    }


def open_root(path: str) -> Tuple[int, os.stat_result]:
    if not os.path.isabs(path) or "\x00" in path:
        raise OSError(errno.EINVAL, "unsafe root")
    if not hasattr(os, "O_NOFOLLOW") or not hasattr(os, "O_DIRECTORY"):
        raise OSError(errno.ENOTSUP, "safe open unavailable")
    fd = os.open(os.path.sep, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for component in path.split(os.path.sep):
            if not component:
                continue
            if component in (".", ".."):
                raise OSError(errno.EINVAL, "unsafe root component")
            component_st = os.stat(component, dir_fd=fd, follow_symlinks=False)
            if not stat.S_ISDIR(component_st.st_mode):
                raise OSError(errno.ENOTDIR, "unsafe root component")
            next_fd = os.open(
                component,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                dir_fd=fd,
            )
            opened_st = os.fstat(next_fd)
            if (opened_st.st_dev, opened_st.st_ino, opened_st.st_mode) != (component_st.st_dev, component_st.st_ino, component_st.st_mode):
                os.close(next_fd)
                raise OSError(errno.EAGAIN, "root component changed")
            os.close(fd)
            fd = next_fd
        st = os.fstat(fd)
        if not stat.S_ISDIR(st.st_mode):
            raise OSError(errno.ENOTDIR, "root is not a directory")
        return fd, st
    except Exception:
        os.close(fd)
        raise


def safe_components(relative: str) -> Optional[List[str]]:
    if not isinstance(relative, str) or not relative or relative.startswith(("/", "~")):
        return None
    if "\x00" in relative or "\\" in relative:
        return None
    parts = relative.split("/")
    if any(not part or part in (".", "..") for part in parts):
        return None
    return parts


def open_relative(root_fd: int, relative: str) -> Tuple[int, os.stat_result]:
    parts = safe_components(relative)
    if parts is None or not hasattr(os, "O_NOFOLLOW"):
        raise OSError(errno.EINVAL, "unsafe relative path")
    parent = os.dup(root_fd)
    try:
        for component in parts[:-1]:
            component_st = os.stat(component, dir_fd=parent, follow_symlinks=False)
            if not stat.S_ISDIR(component_st.st_mode):
                raise OSError(errno.ENOTDIR, "unsafe intermediate")
            child = os.open(
                component,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                dir_fd=parent,
            )
            opened_st = os.fstat(child)
            if (opened_st.st_dev, opened_st.st_ino, opened_st.st_mode) != (component_st.st_dev, component_st.st_ino, component_st.st_mode):
                os.close(child)
                raise OSError(errno.EAGAIN, "intermediate changed")
            os.close(parent)
            parent = child
        final_st = os.stat(parts[-1], dir_fd=parent, follow_symlinks=False)
        if not stat.S_ISREG(final_st.st_mode):
            raise OSError(errno.EPERM, "unsafe final target")
        fd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_NONBLOCK", 0), dir_fd=parent)
        st = os.fstat(fd)
        if (st.st_dev, st.st_ino, st.st_mode) != (final_st.st_dev, final_st.st_ino, final_st.st_mode):
            os.close(fd)
            raise OSError(errno.EAGAIN, "final target changed")
        if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1:
            os.close(fd)
            raise OSError(errno.EPERM, "unsafe file")
        return fd, st
    finally:
        os.close(parent)


def strict_read(fd: int, ceiling: int) -> Tuple[bytes, str, int]:
    decoder = __import__("codecs").getincrementaldecoder("utf-8")("strict")
    digest = hashlib.sha256()
    output = bytearray()
    chars = 0
    try:
        while True:
            block = os.read(fd, 65536)
            if not block:
                tail = decoder.decode(b"", final=True)
                chars += len(tail)
                if chars > ceiling:
                    raise ValueError("budget")
                output.extend(tail.encode("utf-8"))
                return bytes(output), digest.hexdigest(), chars
            digest.update(block)
            text = decoder.decode(block, final=False)
            chars += len(text)
            if chars > ceiling:
                raise ValueError("budget")
            output.extend(text.encode("utf-8"))
    except UnicodeDecodeError:
        raise ValueError("invalid_utf8")


def compare_fingerprint(actual: Dict[str, Any], expected: Dict[str, Any]) -> bool:
    return actual == expected


def current_binding(home: Path, auth: Dict[str, Any], selection_id: Optional[str]) -> Optional[Dict[str, Any]]:
    binding = auth.get("authorization_binding")
    if not isinstance(binding, dict) or binding.get("schema_version") != BINDING_SCHEMA:
        return None
    required = (
        "owner_identity",
        "executable_identity",
        "executable_version",
        "estate_identity",
        "model_class",
        "preflight_id",
        "request_hash",
        "catalog_hash",
    )
    if any(not isinstance(binding.get(key), str) or not binding[key] for key in required):
        return None
    try:
        owner_real = str(home.resolve(strict=True))
        owner_identity = sha256_bytes(("firstmate-home/v1\n" + owner_real).encode())
    except OSError:
        return None
    if owner_identity != binding["owner_identity"]:
        return None
    config_exe = home / "config" / "megamind-executable"
    try:
        raw = config_exe.read_text(encoding="utf-8").splitlines()
        configured = next((line.strip() for line in raw if line.strip() and not line.lstrip().startswith("#")), "megamind-axi")
        exe = Path(configured).expanduser() if os.path.isabs(configured) else Path(__import__("shutil").which(configured) or "")
        if not exe or not exe.is_file() or not os.access(exe, os.X_OK):
            return None
        exe = exe.resolve(strict=True)
        executable_hash = sha256_file(exe)
        if executable_hash is None:
            return None
        exe_identity = sha256_bytes(("megamind-executable/v1\n" + str(exe) + "\n" + executable_hash).encode())
        version = None
        stream = __import__("subprocess").run([str(exe), "--version"], capture_output=True, text=True, timeout=5, check=False).stdout
        lines = [line for line in stream.splitlines() if re.fullmatch(r"megamind-axi [0-9]+\.[0-9]+\.[0-9]+", line)]
        if len(lines) != 1:
            return None
        version = lines[0].split(" ", 1)[1]
    except (OSError, UnicodeError, ValueError, __import__("subprocess").SubprocessError):
        return None
    estate_file = home / "config" / "megamind-estate"
    try:
        estate = next(line.strip() for line in estate_file.read_text(encoding="utf-8").splitlines() if line.strip() and not line.lstrip().startswith("#"))
        estate_path = Path(os.path.expanduser(estate)).resolve(strict=True)
        estate_identity = sha256_bytes(("megamind-estate/v1\\n" + str(estate_path)).encode())
    except (OSError, StopIteration, UnicodeError):
        return None
    model_path = home / "config" / "megamind-model-class"
    try:
        model = next((line.strip() for line in model_path.read_text(encoding="utf-8").splitlines() if line.strip() and not line.lstrip().startswith("#")), "cloud")
    except (OSError, UnicodeError):
        model = "cloud"
    if model not in ("local", "cloud"):
        return None
    if (owner_identity, exe_identity, version, estate_identity, model) != (
        binding["owner_identity"], binding["executable_identity"], binding["executable_version"], binding["estate_identity"], binding["model_class"]
    ):
        return None
    if selection_id is not None and binding.get("selection_id") != selection_id:
        return None
    if selection_id is None and binding.get("selection_id") not in (None, ""):
        return None
    today = time.strftime("%Y-%m-%d", time.gmtime())
    if binding.get("today") and binding["today"] != today:
        return None
    current = dict(binding)
    current["today"] = today
    return {"binding": current, "estate": estate_path, "executable_hash": executable_hash}


def auth_path(home: Path, task_id: Optional[str], selection_id: Optional[str]) -> Optional[Path]:
    if task_id is not None and TASK_RE.fullmatch(task_id):
        return home / "state" / (task_id + ".megamind-preflight.json")
    if selection_id is not None and SELECTION_RE.fullmatch(selection_id):
        return home / "state" / "megamind-offer-selections" / (selection_id + ".authorization.json")
    return None


def proof_matches(home: Path, auth: Dict[str, Any], outcome: str) -> bool:
    proof = home / "state" / "megamind-preflight.jsonl"
    if not private_file(proof):
        return False
    try:
        for line in proof.open(encoding="utf-8"):
            rec = json.loads(line)
            if (
                isinstance(rec, dict)
                and rec.get("preflight_id") == auth.get("preflight_id")
                and rec.get("request_hash") == auth.get("request_hash")
                and rec.get("catalog_hash") == auth.get("catalog_hash")
                and rec.get("model_class") == auth.get("model_class")
                and rec.get("outcome") in ("matched", "ambiguous", "authorized")
            ):
                return True
    except (OSError, ValueError, UnicodeError):
        return False
    return False


def authorization(auth: Dict[str, Any], selection_id: Optional[str]) -> Optional[Tuple[List[Dict[str, Any]], str]]:
    if selection_id is None:
        if auth.get("schema_version") != "fm/megamind-preflight/v1" or auth.get("outcome") != "matched":
            return None
        matches = auth.get("matches")
        authorization_id = auth.get("preflight_id")
    else:
        if auth.get("schema_version") != "fm/megamind-preflight-selection/v1" or auth.get("outcome") != "authorized":
            return None
        selected = auth.get("selected")
        matches = [dict(selected, wiki=selected.get("wiki"))] if isinstance(selected, dict) else None
        authorization_id = auth.get("selection_id")
        if authorization_id != selection_id:
            return None
        selection = auth.get("selection")
        if not isinstance(selection, dict) or selection.get("basis") != "selected-current-offer":
            return None
    if not isinstance(matches, list) or not matches:
        return None
    normalized: List[Dict[str, Any]] = []
    for match in matches:
        if not isinstance(match, dict):
            return None
        wiki = match.get("wiki")
        allows = match.get("allows")
        budget = match.get("context_budget")
        if not isinstance(wiki, str) or not re.fullmatch(r"[A-Za-z0-9_.-]+", wiki) or wiki in (".", ".."):
            return None
        if not isinstance(allows, list) or not allows:
            return None
        if match.get("access") not in ("full", "digest-only") or match.get("routing_mode") != "bounded":
            return None
        if not isinstance(budget, dict) or type(budget.get("max_candidates")) is not int or budget["max_candidates"] <= 0:
            return None
        if type(budget.get("max_context_chars")) is not int or budget["max_context_chars"] <= 0:
            return None
        root_identity = match.get("root_identity")
        if not isinstance(root_identity, str) or not re.fullmatch(r"[0-9a-f]{64}", root_identity):
            return None
        safe_allows: List[str] = []
        for rel in allows:
            if safe_components(rel) is None:
                return None
            if rel not in safe_allows:
                safe_allows.append(rel)
        if not safe_allows:
            return None
        normalized.append({
            "wiki": wiki,
            "root_identity": root_identity,
            "access": match["access"],
            "routing_mode": match["routing_mode"],
            "allows": safe_allows,
            "budget": budget,
        })
    binding = auth.get("authorization_binding")
    declared = binding.get("declared_allows") if isinstance(binding, dict) else None
    expected = [
        {
            "wiki": match["wiki"],
            "allows": match["allows"],
            "access": match["access"],
            "routing_mode": match["routing_mode"],
            "context_budget": match["budget"],
        }
        for match in normalized
    ]
    if not isinstance(declared, list) or json.dumps(declared, sort_keys=True, separators=(",", ":")) != json.dumps(expected, sort_keys=True, separators=(",", ":")):
        return None
    return normalized, str(authorization_id)


def lock_for(path: Path):
    path.parent.mkdir(mode=0o700, exist_ok=True)
    fh = path.open("a+")
    os.chmod(path, 0o600)
    fcntl.flock(fh.fileno(), fcntl.LOCK_EX)
    return fh


def write_private(path: Path, data: bytes) -> bool:
    path.parent.mkdir(mode=0o700, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".admission.", dir=str(path.parent))
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb") as fh:
            fh.write(data)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
        return True
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        return False


def admit(home: Path, task_id: Optional[str], selection_id: Optional[str]) -> int:
    path = auth_path(home, task_id, selection_id)
    if path is None or not private_file(path):
        return fail("authorization_unavailable")
    auth = load_json(path)
    if auth is None:
        return fail("authorization_malformed")
    outcome = "authorized" if selection_id else "matched"
    if not proof_matches(home, auth, outcome):
        return fail("authorization_unproven", authorization_id=auth.get("preflight_id"))
    binding_state = current_binding(home, auth, selection_id)
    if binding_state is None:
        return fail("binding_changed", authorization_id=auth.get("preflight_id"), selection_id=selection_id)
    authorized = authorization(auth, selection_id)
    if authorized is None:
        return fail("authorization_invalid", authorization_id=auth.get("preflight_id"), selection_id=selection_id)
    matches, authorization_id = authorized
    records: List[Dict[str, Any]] = []
    result_wikis: List[Dict[str, Any]] = []
    try:
        for match in matches:
            root = binding_state["estate"] / match["wiki"]
            root_fd, root_st = open_root(str(root))
            try:
                root_identity = sha256_bytes(("wiki-root/v1\n" + str(root.resolve(strict=True))).encode())
                if root_identity != match["root_identity"]:
                    return fail("root_binding_changed", authorization_id=authorization_id, selection_id=selection_id)
                card_fd, card_st = open_relative(root_fd, CARD_REL)
                try:
                    card_data, card_hash, card_chars = strict_read(card_fd, 16 * 1024 * 1024)
                    if card_chars > 16 * 1024 * 1024:
                        return fail("card_invalid", authorization_id=authorization_id, selection_id=selection_id)
                    card_fingerprint = file_fingerprint(card_st, card_hash)
                finally:
                    os.close(card_fd)
                seen: set[Tuple[int, int]] = set()
                candidates: List[Dict[str, Any]] = []
                ordinal = 0
                total_chars = 0
                for rel in match["allows"]:
                    fd, st = open_relative(root_fd, rel)
                    try:
                        identity = (st.st_dev, st.st_ino)
                        if identity in seen:
                            continue
                        seen.add(identity)
                        ordinal += 1
                        if ordinal > match["budget"]["max_candidates"]:
                            return fail("max_candidates_exceeded", authorization_id=authorization_id, selection_id=selection_id)
                        data, digest, chars = strict_read(fd, match["budget"]["max_context_chars"] - total_chars)
                        total_chars += chars
                        candidates.append({
                            "relative_path": rel,
                            "candidate_ordinal": ordinal,
                            "content_hash": digest,
                            "admitted_chars": chars,
                            "fingerprint": file_fingerprint(st, digest),
                        })
                    finally:
                        os.close(fd)
                if not candidates:
                    return fail("no_loadable_paths", authorization_id=authorization_id, selection_id=selection_id)
                records.append({
                    "wiki": match["wiki"],
                    "root": str(root),
                    "root_identity": root_identity,
                    "root_fingerprint": root_fingerprint(root_st),
                    "card_fingerprint": card_fingerprint,
                    "access": match["access"],
                    "routing_mode": match["routing_mode"],
                    "allows": match["allows"],
                    "budget": match["budget"],
                    "candidates": candidates,
                })
                result_wikis.append({
                    "wiki": match["wiki"],
                    "paths": [{k: c[k] for k in ("relative_path", "content_hash", "admitted_chars", "candidate_ordinal")} for c in candidates],
                    "candidate_count": len(candidates),
                    "context_chars": total_chars,
                    "max_candidates": match["budget"]["max_candidates"],
                    "max_context_chars": match["budget"]["max_context_chars"],
                })
            finally:
                os.close(root_fd)
    except UnicodeDecodeError:
        return fail("invalid_utf8", authorization_id=authorization_id, selection_id=selection_id)
    except ValueError as exc:
        return fail("context_budget_exceeded" if str(exc) == "budget" else "invalid_utf8", authorization_id=authorization_id, selection_id=selection_id)
    except (OSError, RuntimeError):
        return fail("path_unavailable", authorization_id=authorization_id, selection_id=selection_id)
    binding = {
        "schema_version": BINDING_SCHEMA,
        "owner_identity": binding_state["binding"]["owner_identity"],
        "executable_identity": binding_state["binding"]["executable_identity"],
        "executable_version": binding_state["binding"]["executable_version"],
        "executable_hash": binding_state["executable_hash"],
        "estate_identity": binding_state["binding"]["estate_identity"],
        "model_class": binding_state["binding"]["model_class"],
        "preflight_id": auth.get("preflight_id"),
        "request_hash": auth.get("request_hash"),
        "catalog_hash": auth.get("catalog_hash"),
        "authorization_id": authorization_id,
        "selection_id": selection_id,
        "task_id": task_id,
        "today": time.strftime("%Y-%m-%d", time.gmtime()),
    }
    admission_id = sha256_bytes(json.dumps({"binding": binding, "records": records}, sort_keys=True, separators=(",", ":")).encode())[:32]
    store = home / "state" / "megamind-admissions"
    lock = lock_for(store / ("." + admission_id + ".lock"))
    try:
        admission = {"schema_version": BINDING_SCHEMA, "admission_id": admission_id, "binding": binding, "records": records}
        if not write_private(store / (admission_id + ".json"), json.dumps(admission, sort_keys=True, separators=(",", ":")).encode() + b"\n"):
            return fail("admission_write_failed", authorization_id=authorization_id, selection_id=selection_id)
    finally:
        lock.close()
    return emit(result("", True, admission_id=admission_id, authorization_id=authorization_id, selection_id=selection_id, wikis=result_wikis))


def revalidate_and_content(home: Path, admission_id: str) -> int:
    if not re.fullmatch(r"[0-9a-f]{32}", admission_id):
        return fail("admission_id_invalid")
    path = home / "state" / "megamind-admissions" / (admission_id + ".json")
    admission = load_json(path)
    if admission is None or admission.get("schema_version") != BINDING_SCHEMA or admission.get("admission_id") != admission_id:
        return fail("admission_unavailable")
    binding = admission.get("binding")
    if not isinstance(binding, dict):
        return fail("admission_malformed")
    auth_selection = binding.get("selection_id")
    auth_task = binding.get("task_id")
    auth_path_value = auth_path(home, auth_task if not auth_selection else None, auth_selection)
    if auth_path_value is None:
        return fail("authorization_unavailable")
    auth = load_json(auth_path_value)
    if auth is None:
        return fail("authorization_unavailable")
    if not proof_matches(home, auth, "authorized" if auth_selection else "matched"):
        return fail("binding_changed")
    current = current_binding(home, auth, auth_selection)
    if current is None:
        return fail("binding_changed")
    for key in ("owner_identity", "executable_identity", "executable_version", "estate_identity", "model_class", "preflight_id", "request_hash", "catalog_hash", "authorization_id", "selection_id", "today"):
        if current["binding"].get(key) != binding.get(key):
            return fail("binding_changed")
    if auth_selection is None and not isinstance(auth_task, str):
        return fail("binding_changed")
    if auth_selection is None and binding.get("task_id") != auth_task:
        return fail("binding_changed")
    authorized = authorization(auth, auth_selection)
    if authorized is None:
        return fail("authorization_changed")
    matches, _ = authorized
    match_by_wiki = {m["wiki"]: m for m in matches}
    output = bytearray()
    try:
        for record in admission.get("records", []):
            if not isinstance(record, dict) or record.get("wiki") not in match_by_wiki:
                return fail("admission_changed")
            match = match_by_wiki[record["wiki"]]
            if match["allows"] != record.get("allows") or match["budget"] != record.get("budget") or match["access"] != record.get("access") or match["routing_mode"] != record.get("routing_mode"):
                return fail("admission_changed")
            root = current["estate"] / record["wiki"]
            root_fd, root_st = open_root(str(root))
            try:
                if sha256_bytes(("wiki-root/v1\n" + str(root.resolve(strict=True))).encode()) != record.get("root_identity"):
                    return fail("root_changed")
                if root_fingerprint(root_st) != record.get("root_fingerprint"):
                    return fail("root_changed")
                card_fd, card_st = open_relative(root_fd, CARD_REL)
                try:
                    _, card_hash, _ = strict_read(card_fd, 16 * 1024 * 1024)
                    if file_fingerprint(card_st, card_hash) != record.get("card_fingerprint"):
                        return fail("card_changed")
                finally:
                    os.close(card_fd)
                total = 0
                seen: set[Tuple[int, int]] = set()
                for candidate in record.get("candidates", []):
                    rel = candidate.get("relative_path")
                    fd, st = open_relative(root_fd, rel)
                    try:
                        identity = (st.st_dev, st.st_ino)
                        if identity in seen:
                            return fail("duplicate_identity")
                        seen.add(identity)
                        data, digest, chars = strict_read(fd, match["budget"]["max_context_chars"] - total)
                        total += chars
                        if digest != candidate.get("content_hash") or chars != candidate.get("admitted_chars") or file_fingerprint(st, digest) != candidate.get("fingerprint"):
                            return fail("path_changed")
                        output.extend((record["wiki"] + ":" + rel + "\n").encode("utf-8"))
                        output.extend(data)
                        output.extend(b"\n")
                    finally:
                        os.close(fd)
            finally:
                os.close(root_fd)
    except UnicodeDecodeError:
        return fail("invalid_utf8")
    except ValueError as exc:
        return fail("context_budget_exceeded" if str(exc) == "budget" else "invalid_utf8")
    except (OSError, RuntimeError):
        return fail("path_unavailable")
    sys.stdout.buffer.write(bytes(output))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("command", choices=("admit", "content"))
    parser.add_argument("--owner-home")
    parser.add_argument("--task-id")
    parser.add_argument("--selection-id")
    parser.add_argument("--admission-id")
    try:
        args = parser.parse_args()
    except SystemExit:
        return fail("invocation_invalid")
    owner = args.owner_home or os.environ.get("FM_MEGAMIND_OWNER_HOME") or os.environ.get("FM_HOME")
    home = safe_home(owner or "")
    if home is None:
        return fail("owner_home_invalid")
    if args.command == "admit":
        if bool(args.task_id) == bool(args.selection_id):
            return fail("authorization_selector_invalid")
        return admit(home, args.task_id, args.selection_id)
    if not args.admission_id or args.task_id or args.selection_id:
        return fail("admission_selector_invalid")
    return revalidate_and_content(home, args.admission_id)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (BrokenPipeError, KeyboardInterrupt):
        sys.exit(1)
    except Exception:
        sys.exit(fail("reader_internal_error"))
