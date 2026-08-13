#!/usr/bin/env python3
"""Host-owned deterministic Megamind research execution lane."""
from __future__ import annotations

import argparse
import hashlib
import html
import ipaddress
import json
import os
import re
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import time
import urllib.parse
import uuid
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple

PLAN_SCHEMA = "fm/megamind-research-plan/v1"
RESULT_SCHEMA = "fm/megamind-research-result/v1"
RETRIEVAL_SCHEMA = "fm/megamind-retrieval/v1"
EXTRACTION_SCHEMA = "fm/megamind-extraction/v1"
RECEIPT_SCHEMA = "fm/megamind-tool-receipt/v1"
MAX_PLAN_BYTES = 1024 * 1024
MAX_SOURCE_BYTES = 2 * 1024 * 1024
MAX_TOTAL_BYTES = 8 * 1024 * 1024
MAX_SOURCES = 16
MAX_ATTEMPTS = 5
SAFE_ID = re.compile(r"^[A-Za-z0-9_.:-]{1,128}$")
HASH = re.compile(r"^[0-9a-fA-F]{32,128}$")
ALLOWED_MIME = {
    "application/json",
    "application/xml",
    "text/html",
    "text/plain",
    "text/vtt",
    "text/xml",
}
TRANSIENT = {"adapter_error", "adapter_timeout", "malformed_adapter_output"}


def emit(obj: Dict[str, Any], code: int = 0) -> int:
    sys.stdout.write(json.dumps(obj, ensure_ascii=True, separators=(",", ":")) + "\n")
    return code


def result(status: str, reason: str, **fields: Any) -> Dict[str, Any]:
    out: Dict[str, Any] = {
        "schema_version": RESULT_SCHEMA,
        "status": status,
        "reason": reason,
        "run_id": fields.pop("run_id", None),
        "plan_hash": fields.pop("plan_hash", None),
        "request_hash": fields.pop("request_hash", None),
        "model_class": fields.pop("model_class", None),
        "sources": fields.pop("sources", []),
        "handoff": fields.pop("handoff", None),
    }
    out.update(fields)
    return out


def safe_private_file(path: Path, max_bytes: int, require_private: bool = False) -> bool:
    try:
        st = path.lstat()
        return (
            stat.S_ISREG(st.st_mode)
            and not path.is_symlink()
            and st.st_uid == os.getuid()
            and (not require_private or stat.S_IMODE(st.st_mode) == 0o600)
            and st.st_size <= max_bytes
        )
    except OSError:
        return False


def read_json(path: Path, max_bytes: int) -> Optional[Dict[str, Any]]:
    if not safe_private_file(path, max_bytes):
        return None
    try:
        with path.open("rb") as stream:
            obj = json.load(stream)
        return obj if isinstance(obj, dict) else None
    except (OSError, ValueError, UnicodeError):
        return None


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(65536), b""):
            digest.update(block)
    return digest.hexdigest()


def atomic_private_write(path: Path, data: bytes, exclusive: bool = False) -> bool:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    flags = os.O_WRONLY | os.O_CREAT | (os.O_EXCL if exclusive else os.O_TRUNC)
    tmp = path.parent / ("." + path.name + "." + uuid.uuid4().hex + ".tmp")
    try:
        fd = os.open(tmp, flags, 0o600)
        try:
            view = memoryview(data)
            while view:
                written = os.write(fd, view)
                if written <= 0:
                    raise OSError("short write")
                view = view[written:]
            os.fsync(fd)
        finally:
            os.close(fd)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
        os.chmod(path, 0o600)
        return True
    except OSError:
        try:
            tmp.unlink()
        except OSError:
            pass
        return False


def private_exclusive(path: Path, data: bytes) -> bool:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            view = memoryview(data)
            while view:
                written = os.write(fd, view)
                if written <= 0:
                    raise OSError("short write")
                view = view[written:]
            os.fsync(fd)
        finally:
            os.close(fd)
        os.chmod(path, 0o600)
        return True
    except FileExistsError:
        return False
    except OSError:
        return False


def safe_home(raw: str) -> Optional[Path]:
    if not raw or not os.path.isabs(raw):
        return None
    home = Path(raw)
    try:
        if home.is_symlink() or not home.is_dir():
            return None
        for name in ("config", "state"):
            child = home / name
            if child.is_symlink() or not child.is_dir():
                return None
        return home.resolve(strict=True)
    except OSError:
        return None


def valid_id(value: Any) -> bool:
    return isinstance(value, str) and bool(SAFE_ID.fullmatch(value))


def valid_hash(value: Any) -> bool:
    return isinstance(value, str) and bool(HASH.fullmatch(value))


def admission_from(plan: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    admission = plan.get("admission")
    if not isinstance(admission, dict):
        return None
    if admission.get("schema_version") != "fm/megamind-research-admission/v1":
        return None
    if admission.get("outcome") not in ("matched", "authorized"):
        return None
    if admission.get("authorized") is not True or admission.get("fresh") is not True:
        return None
    if not valid_id(admission.get("admission_id")):
        return None
    if not valid_hash(admission.get("request_hash")):
        return None
    if admission.get("model_class") not in ("local", "cloud"):
        return None
    return admission


def plan_identity(plan: Dict[str, Any]) -> Optional[Tuple[str, str]]:
    plan_id = plan.get("plan_id")
    if not valid_id(plan_id):
        return None
    canonical = json.dumps(plan, ensure_ascii=True, sort_keys=True, separators=(",", ":")).encode()
    return plan_id, sha256_bytes(canonical)


def stable_run_id(plan_id: str, request_hash: str) -> str:
    return sha256_bytes((plan_id + "\n" + request_hash).encode())[:32]


def validate_url(raw: Any) -> Tuple[Optional[str], Optional[str]]:
    if not isinstance(raw, str) or len(raw) > 2048 or any(ord(c) < 0x20 for c in raw):
        return None, "invalid_url"
    parsed = urllib.parse.urlsplit(raw)
    if parsed.scheme not in ("http", "https") or not parsed.hostname:
        return None, "invalid_url"
    if parsed.username is not None or parsed.password is not None or parsed.fragment:
        return None, "unsafe_url"
    host = parsed.hostname.rstrip(".").lower()
    if host == "localhost" or host.endswith(".localhost") or host.endswith(".local"):
        return None, "ssrf_blocked"
    try:
        addresses = {item[4][0] for item in socket.getaddrinfo(host, parsed.port or (443 if parsed.scheme == "https" else 80), type=socket.SOCK_STREAM)}
    except (OSError, ValueError):
        return None, "dns_unavailable"
    if not addresses:
        return None, "dns_unavailable"
    for address in addresses:
        try:
            ip = ipaddress.ip_address(address)
        except ValueError:
            return None, "ssrf_blocked"
        if not ip.is_global:
            return None, "ssrf_blocked"
    normalized = urllib.parse.urlunsplit((parsed.scheme, host + ((":" + str(parsed.port)) if parsed.port else ""), parsed.path or "/", parsed.query, ""))
    return normalized, None


def validate_plan(plan: Dict[str, Any], admission: Dict[str, Any]) -> Optional[str]:
    if plan.get("schema_version") != PLAN_SCHEMA or plan.get("authorized") is not True:
        return "plan_invalid"
    if plan.get("model_class") != admission.get("model_class"):
        return "admission_changed"
    budgets = plan.get("budgets")
    if not isinstance(budgets, dict):
        return "budget_invalid"
    for key, ceiling in (("max_sources", MAX_SOURCES), ("max_bytes", MAX_TOTAL_BYTES), ("deadline_ms", 600000), ("max_cost_microunits", 100000000)):
        value = budgets.get(key)
        if not isinstance(value, int) or isinstance(value, bool) or value < 1 or value > ceiling:
            return "budget_invalid"
    retry = plan.get("retry", {})
    if not isinstance(retry, dict):
        return "retry_invalid"
    attempts = retry.get("max_attempts", 1)
    cooldown = retry.get("cooldown_seconds", 0)
    if not isinstance(attempts, int) or not 1 <= attempts <= MAX_ATTEMPTS or not isinstance(cooldown, (int, float)) or cooldown < 0 or cooldown > 3600:
        return "retry_invalid"
    sources = plan.get("sources")
    if not isinstance(sources, list) or not sources or len(sources) > budgets["max_sources"] or len(sources) > MAX_SOURCES:
        return "sources_invalid"
    seen = set()
    for source in sources:
        if not isinstance(source, dict) or not valid_id(source.get("source_id")) or source["source_id"] in seen:
            return "sources_invalid"
        seen.add(source["source_id"])
        if source.get("kind") not in ("search", "browser", "youtube-transcript"):
            return "source_kind_invalid"
        if not isinstance(source.get("url"), str):
            return "source_url_invalid"
        adapter = source.get("adapter")
        if not isinstance(adapter, dict) or not isinstance(adapter.get("argv"), list) or not adapter["argv"] or any(not isinstance(arg, str) or not arg or "\x00" in arg for arg in adapter["argv"]):
            return "adapter_invalid"
        command = adapter["argv"][0]
        if not os.path.isabs(command) or not os.access(command, os.X_OK) or os.path.islink(command):
            return "adapter_invalid"
        source_bytes = source.get("max_bytes", MAX_SOURCE_BYTES)
        timeout_ms = source.get("timeout_ms", 10000)
        if isinstance(source_bytes, bool) or not isinstance(source_bytes, int) or source_bytes < 1 or source_bytes > MAX_SOURCE_BYTES:
            return "source_budget_invalid"
        if isinstance(timeout_ms, bool) or not isinstance(timeout_ms, int) or timeout_ms < 1 or timeout_ms > 600000:
            return "source_budget_invalid"
    return None


def load_cooldowns(state: Path) -> Dict[str, float]:
    path = state / "megamind-research-cooldowns.json"
    obj = read_json(path, 64 * 1024)
    return obj if isinstance(obj, dict) else {}


def save_cooldowns(state: Path, cooldowns: Dict[str, float]) -> None:
    atomic_private_write(state / "megamind-research-cooldowns.json", json.dumps(cooldowns, sort_keys=True, separators=(",", ":")).encode())


def host_for(url: str) -> str:
    return (urllib.parse.urlsplit(url).hostname or "").lower()


def cancellation_path(state: Path, run_id: str) -> Path:
    return state / "megamind-research-cancel" / (run_id + ".cancel")


def is_cancelled(state: Path, run_id: str) -> bool:
    marker = cancellation_path(state, run_id)
    return marker.is_file() and not marker.is_symlink()


def quarantine_dir(state: Path, plan_hash: str) -> Path:
    root = state / "megamind-research-quarantine"
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(root, 0o700)
    path = root / plan_hash
    path.mkdir(mode=0o700, exist_ok=True)
    os.chmod(path, 0o700)
    return path


def existing_result_valid(state: Path, plan_hash: str, existing: Dict[str, Any]) -> bool:
    if existing.get("schema_version") != RESULT_SCHEMA:
        return False
    qdir = state / "megamind-research-quarantine" / plan_hash
    sources = existing.get("sources")
    if not isinstance(sources, list):
        return False
    for source in sources:
        if not isinstance(source, dict) or source.get("status") != "retrieved":
            continue
        source_id = source.get("source_id")
        content_hash = source.get("content_sha256")
        if not valid_id(source_id) or not valid_hash(content_hash):
            return False
        body = qdir / (source_id + "." + content_hash + ".body")
        extraction = qdir / (source_id + "." + content_hash + ".extraction.json")
        if not safe_private_file(body, MAX_SOURCE_BYTES, require_private=True) or sha256_file(body) != content_hash:
            return False
        if not safe_private_file(extraction, MAX_SOURCE_BYTES, require_private=True):
            return False
        extracted = read_json(extraction, MAX_SOURCE_BYTES)
        if not extracted or extracted.get("schema_version") != EXTRACTION_SCHEMA or extracted.get("content_sha256") != content_hash:
            return False
    return True


def adapter_command(source: Dict[str, Any], url: str) -> List[str]:
    # The plan owns an already-authorized executable and fixed argv prefix.
    # URL and source id are separate argv values; shell parsing never occurs.
    return [*source["adapter"]["argv"], "--url", url, "--source-id", source["source_id"]]


def read_adapter(path: Path, source: Dict[str, Any], url: str, started: float, max_bytes: int) -> Tuple[Optional[Dict[str, Any]], str, int]:
    output = path / (".adapter-" + source["source_id"] + ".out")
    try:
        with output.open("wb") as stream:
            proc = subprocess.Popen(adapter_command(source, url), stdin=subprocess.DEVNULL, stdout=stream, stderr=subprocess.DEVNULL, shell=False, close_fds=True, start_new_session=True, env={"PATH": "/usr/bin:/bin", "LC_ALL": "C", "HOME": str(path)})
            try:
                proc.wait(timeout=max(0.1, (source.get("timeout_ms", 10000) / 1000)))
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
                return None, "adapter_timeout", int((time.monotonic() - started) * 1000)
        if output.stat().st_size > max_bytes:
            return None, "size_exceeded", int((time.monotonic() - started) * 1000)
        if proc.returncode != 0:
            return None, "adapter_error", int((time.monotonic() - started) * 1000)
        obj = read_json(output, max_bytes)
        if not obj or obj.get("schema_version") != RETRIEVAL_SCHEMA or obj.get("status") != "ok":
            return None, "malformed_adapter_output", int((time.monotonic() - started) * 1000)
        return obj, "ok", int((time.monotonic() - started) * 1000)
    except (OSError, ValueError):
        return None, "adapter_error", int((time.monotonic() - started) * 1000)
    finally:
        try:
            output.unlink()
        except OSError:
            pass


def extract(body: bytes, source_id: str, content_hash: str) -> Dict[str, Any]:
    # Deliberately pure: hostile source bytes are data, never instructions.
    text = body.decode("utf-8", "strict")
    text = html.unescape(re.sub(r"<script\b[^>]*>.*?</script\s*>", " ", text, flags=re.I | re.S))
    text = re.sub(r"<style\b[^>]*>.*?</style\s*>", " ", text, flags=re.I | re.S)
    text = re.sub(r"<[^>]+>", " ", text)
    text = re.sub(r"[ \t\r\f\v]+", " ", text).strip()
    return {
        "schema_version": EXTRACTION_SCHEMA,
        "source_id": source_id,
        "content_sha256": content_hash,
        "text_sha256": sha256_bytes(text.encode("utf-8")),
        "char_count": len(text),
        "text": text,
    }


def receipt_bytes(source: Dict[str, Any], url: str, attempt: int, outcome: str, latency: int, cost: int, body_hash: Optional[str], tool_hash: str) -> bytes:
    return json.dumps({
        "schema_version": RECEIPT_SCHEMA,
        "receipt_id": uuid.uuid4().hex,
        "source_id": source["source_id"],
        "kind": source["kind"],
        "attempt": attempt,
        "outcome": outcome,
        "latency_ms": max(0, latency),
        "cost_microunits": cost,
        "tool_sha256": tool_hash,
        "url_sha256": sha256_bytes(url.encode()),
        "content_sha256": body_hash,
    }, sort_keys=True, separators=(",", ":")).encode()


def privacy_summary(source: Dict[str, Any], status: str, attempts: int, body_hash: Optional[str], size: int, latency: int, cost: int, receipt_ids: List[str]) -> Dict[str, Any]:
    return {"source_id": source["source_id"], "kind": source["kind"], "status": status, "attempts": attempts, "content_sha256": body_hash, "bytes": size, "latency_ms": latency, "cost_microunits": cost, "receipt_ids": receipt_ids}


def run_plan(home: Path, plan_path: Path) -> int:
    if not safe_private_file(plan_path, MAX_PLAN_BYTES, require_private=True):
        return emit(result("blocked", "plan_unavailable"), 1)
    plan = read_json(plan_path, MAX_PLAN_BYTES)
    if not plan:
        return emit(result("blocked", "plan_unavailable"), 1)
    admission = admission_from(plan)
    identity = plan_identity(plan) if admission else None
    if not admission or not identity:
        return emit(result("blocked", "admission_invalid"), 1)
    plan_id, plan_hash = identity
    invalid = validate_plan(plan, admission)
    run_id = stable_run_id(plan_id, admission["request_hash"])
    base = {"run_id": run_id, "plan_hash": plan_hash, "request_hash": admission["request_hash"], "model_class": admission["model_class"], "admission_id": admission["admission_id"]}
    if invalid:
        return emit(result("blocked", invalid, **base), 1)
    state = home / "state"
    receipt_store = state / "megamind-research-receipts"
    done = receipt_store / (plan_hash + ".json")
    existing = read_json(done, 2 * 1024 * 1024)
    if existing and existing.get("schema_version") == RESULT_SCHEMA:
        if existing_result_valid(state, plan_hash, existing):
            return emit(existing)
        return emit(result("blocked", "quarantine_changed", **base), 1)
    if is_cancelled(state, run_id):
        return emit(result("research-pending", "cancelled", **base))
    budgets = plan["budgets"]
    retry = plan.get("retry", {})
    max_attempts = retry.get("max_attempts", 1)
    cooldown_seconds = float(retry.get("cooldown_seconds", 0))
    started = time.monotonic()
    total_bytes = 0
    total_cost = 0
    summaries: List[Dict[str, Any]] = []
    cooldowns = load_cooldowns(state)
    for source in plan["sources"]:
        if is_cancelled(state, run_id):
            out = result("research-pending", "cancelled", sources=summaries, **base)
            atomic_private_write(state / "megamind-research-pending" / (run_id + ".json"), json.dumps(out, sort_keys=True, separators=(",", ":")).encode())
            return emit(out)
        if (time.monotonic() - started) * 1000 >= budgets["deadline_ms"]:
            out = result("research-pending", "deadline_exceeded", sources=summaries, **base)
            atomic_private_write(state / "megamind-research-pending" / (run_id + ".json"), json.dumps(out, sort_keys=True, separators=(",", ":")).encode())
            return emit(out)
        url, url_error = validate_url(source["url"])
        if url_error or not url:
            summary = privacy_summary(source, url_error or "invalid_url", 0, None, 0, 0, 0, [])
            out = result("research-pending", "fetch_blocked", sources=summaries + [summary], **base)
            atomic_private_write(state / "megamind-research-pending" / (run_id + ".json"), json.dumps(out, sort_keys=True, separators=(",", ":")).encode())
            return emit(out)
        host = host_for(url)
        if float(cooldowns.get(host, 0)) > time.time():
            summary = privacy_summary(source, "cooldown", 0, None, 0, 0, 0, [])
            out = result("research-pending", "cooldown", sources=summaries + [summary], **base)
            atomic_private_write(state / "megamind-research-pending" / (run_id + ".json"), json.dumps(out, sort_keys=True, separators=(",", ":")).encode())
            return emit(out)
        qdir = quarantine_dir(state, plan_hash)
        receipt_ids: List[str] = []
        body: Optional[bytes] = None
        body_hash: Optional[str] = None
        status = "adapter_error"
        attempts = 0
        last_latency = 0
        source_cost = 0
        for attempt in range(1, max_attempts + 1):
            attempts = attempt
            if is_cancelled(state, run_id):
                status = "cancelled"
                break
            if (time.monotonic() - started) * 1000 >= budgets["deadline_ms"]:
                status = "deadline_exceeded"
                break
            tool_hash = sha256_bytes("\0".join(adapter_command(source, url)).encode())
            response, status, last_latency = read_adapter(qdir, source, url, time.monotonic(), int(source.get("max_bytes", MAX_SOURCE_BYTES)))
            if response is not None:
                final_url = response.get("final_url", url)
                mime = response.get("mime")
                raw_body = response.get("body")
                if final_url != url:
                    status = "redirect_blocked"
                elif not isinstance(mime, str) or mime.split(";", 1)[0].strip().lower() not in ALLOWED_MIME:
                    status = "mime_blocked"
                elif not isinstance(raw_body, str):
                    status = "malformed_adapter_output"
                else:
                    try:
                        candidate = raw_body.encode("utf-8")
                    except UnicodeEncodeError:
                        candidate = b""
                        status = "invalid_utf8"
                    if len(candidate) > int(source.get("max_bytes", MAX_SOURCE_BYTES)):
                        status = "size_exceeded"
                    elif total_bytes + len(candidate) > budgets["max_bytes"]:
                        status = "budget_exceeded"
                    else:
                        cost = response.get("cost_microunits", 0)
                        if not isinstance(cost, int) or cost < 0:
                            status = "malformed_adapter_output"
                        elif total_cost + cost > budgets["max_cost_microunits"]:
                            status = "budget_exceeded"
                        else:
                            body = candidate
                            body_hash = sha256_bytes(body)
                            source_cost = cost
                            total_bytes += len(body)
                            total_cost += cost
            receipt = receipt_bytes(source, url, attempt, status, last_latency, source_cost, body_hash, tool_hash)
            receipt_path = receipt_store / (plan_hash + "." + source["source_id"] + "." + str(attempt) + ".json")
            if private_exclusive(receipt_path, receipt):
                receipt_ids.append(receipt_path.stem)
            else:
                existing_receipt = read_json(receipt_path, 128 * 1024)
                if existing_receipt:
                    receipt_ids.append(receipt_path.stem)
            if body is not None or status not in TRANSIENT or attempt == max_attempts:
                break
        if body is None and cooldown_seconds > 0:
            cooldowns[host] = time.time() + cooldown_seconds
            save_cooldowns(state, cooldowns)
        if body is None:
            summary = privacy_summary(source, status, attempts, None, 0, last_latency, source_cost, receipt_ids)
            out = result("research-pending", "fetch_blocked" if status.endswith("blocked") or status in ("size_exceeded", "budget_exceeded", "mime_blocked") else status, sources=summaries + [summary], **base)
            atomic_private_write(state / "megamind-research-pending" / (run_id + ".json"), json.dumps(out, sort_keys=True, separators=(",", ":")).encode())
            return emit(out)
        content_path = qdir / (source["source_id"] + "." + body_hash + ".body")
        if not content_path.exists():
            if not private_exclusive(content_path, body):
                return emit(result("blocked", "quarantine_write_failed", sources=summaries, **base), 1)
        extraction = extract(body, source["source_id"], body_hash)
        extract_path = qdir / (source["source_id"] + "." + body_hash + ".extraction.json")
        if not extract_path.exists():
            if not private_exclusive(extract_path, json.dumps(extraction, ensure_ascii=True, sort_keys=True, separators=(",", ":")).encode()):
                return emit(result("blocked", "quarantine_write_failed", sources=summaries, **base), 1)
        summaries.append(privacy_summary(source, "retrieved", attempts, body_hash, len(body), last_latency, source_cost, receipt_ids))
    handoff = {"schema_version": "fm/megamind-fresh-admission-handoff/v1", "required": True, "request_hash": admission["request_hash"], "run_id": run_id}
    out = result("research-pending", "fresh_admission_required", sources=summaries, handoff=handoff, **base)
    encoded = json.dumps(out, sort_keys=True, separators=(",", ":")).encode()
    if not atomic_private_write(done, encoded):
        return emit(result("blocked", "receipt_write_failed", sources=summaries, **base), 1)
    if not atomic_private_write(state / "megamind-research-pending" / (run_id + ".json"), encoded):
        return emit(result("blocked", "pending_write_failed", sources=summaries, **base), 1)
    return emit(out)


def cancel_plan(home: Path, run_id: str) -> int:
    if not valid_id(run_id):
        return emit(result("blocked", "run_id_invalid"), 1)
    marker = cancellation_path(home / "state", run_id)
    data = json.dumps({"schema_version": "fm/megamind-research-cancellation/v1", "run_id": run_id, "cancelled": True}, separators=(",", ":")).encode()
    if not marker.exists() and not private_exclusive(marker, data):
        return emit(result("blocked", "cancellation_write_failed"), 1)
    return emit(result("research-pending", "cancelled", run_id=run_id))


def resume_plan(home: Path, plan_path: Path) -> int:
    if not safe_private_file(plan_path, MAX_PLAN_BYTES, require_private=True):
        return emit(result("blocked", "fresh_admission_invalid"), 1)
    plan = read_json(plan_path, MAX_PLAN_BYTES)
    admission = admission_from(plan) if plan else None
    identity = plan_identity(plan) if admission and plan else None
    if not admission or not identity:
        return emit(result("blocked", "fresh_admission_invalid"), 1)
    plan_id, plan_hash = identity
    run_id = stable_run_id(plan_id, admission["request_hash"])
    pending = read_json(home / "state" / "megamind-research-pending" / (run_id + ".json"), 2 * 1024 * 1024)
    if not pending or pending.get("request_hash") != admission.get("request_hash"):
        return emit(result("blocked", "research_not_pending", run_id=run_id, plan_hash=plan_hash), 1)
    previous = pending.get("admission_id")
    if previous is not None and previous == admission.get("admission_id"):
        return emit(result("blocked", "fresh_admission_required", run_id=run_id, plan_hash=plan_hash), 1)
    return emit(result("research-pending", "fresh_admission_accepted", run_id=run_id, plan_hash=plan_hash, request_hash=admission["request_hash"], model_class=admission["model_class"], handoff={"schema_version": "fm/megamind-fresh-admission-handoff/v1", "required": False, "run_id": run_id}))


def main() -> int:
    parser = argparse.ArgumentParser(prog="fm-megamind-research.sh")
    parser.add_argument("command", choices=("run", "resume", "cancel"))
    parser.add_argument("--plan")
    parser.add_argument("--home", default=os.environ.get("FM_HOME", ""))
    parser.add_argument("--run-id")
    args = parser.parse_args()
    home = safe_home(args.home)
    if not home:
        return emit(result("blocked", "home_invalid"), 1)
    if args.command == "cancel":
        return cancel_plan(home, args.run_id or "")
    if not args.plan:
        return emit(result("blocked", "plan_required"), 1)
    plan_path = Path(args.plan)
    if not plan_path.is_absolute() or plan_path.is_symlink():
        return emit(result("blocked", "plan_invalid"), 1)
    return run_plan(home, plan_path) if args.command == "run" else resume_plan(home, plan_path)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(130)
