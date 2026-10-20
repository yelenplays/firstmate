#!/usr/bin/env python3
"""fm-search.py - the engine behind bin/fm-search.sh (see that file and docs/configuration.md).

Walks a provider chain for one web query and prints normalized results. Provider
logic is copied from the phase-1 bench (data/search-router-bench-v1). Keys are
read from ~/.config/<name>.key at call time and never printed, logged or stored.
The ledger and the route cache never hold query text.
"""
import contextlib, fcntl, hashlib, json, os, re, subprocess, sys, time, urllib.error, urllib.parse, urllib.request
from http.client import HTTPException

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
FM_HOME = os.environ.get("FM_HOME") or ROOT
STATE = os.environ.get("FM_SEARCH_STATE") or os.path.join(FM_HOME, "state", "fm-search")
LEDGER = os.path.join(STATE, "ledger.tsv")
ROUTE_CACHE = os.path.join(STATE, "route-cache.tsv")
KEY_DIR = os.environ.get("FM_SEARCH_KEY_DIR") or os.path.expanduser("~/.config")
JEV_BIN = os.environ.get("FM_JEV_BIN") or os.path.join(HERE, "fm-jev.sh")
KETCH = os.environ.get("FM_SEARCH_KETCH_BIN") or "ketch"
EXA_URL = os.environ.get("FM_SEARCH_EXA_URL") or "https://api.exa.ai/search"
TINYFISH_URL = os.environ.get("FM_SEARCH_TINYFISH_URL") or "https://api.search.tinyfish.ai/"

DEFAULTS = {
    "exa": {"monthly_usd_cap": 8.00, "warn_fraction": 0.8, "per_query_usd": 0.004,
            "deep_per_query_usd": 0.007, "type": "lite", "deep_type": "auto"},
    "tinyfish": {"per_minute": 25, "per_day": 10000},
    "jev": {"confidence_floor": 0.7, "route_cache_hours": 24, "max_query_bytes": 300},
    "timeouts_s": {"exa-keyless": 8, "exa-lite": 5, "exa-deep": 10, "tinyfish": 8, "ketch-multi": 15},
}

CLASSES = [
    ("docs", "official docs or API reference of a library, framework or hosted service"),
    ("cli", "flags, options or usage of a command-line tool"),
    ("error", "an error message or failure to troubleshoot"),
    ("seo_local", "local SEO, Google Business Profile, reviews, landing pages or directories for a local business"),
    ("music", "music distribution, streaming platforms, royalties, Content ID, ISRC, collecting societies"),
    ("de_admin", "German tax, business registration, social insurance, labour, permit or legal rules"),
    ("stt", "speech-to-text, pronunciation assessment, ASR models, forced alignment research"),
    ("fresh", "the latest version, release, price change or news, where recency decides the answer"),
]
KEYED_FIRST = {"docs", "error", "music"}
CHAIN_F = ["exa-keyless", "exa-lite", "tinyfish", "ketch-multi"]
CHAIN_K = ["exa-lite", "tinyfish", "exa-keyless", "ketch-multi"]

USAGE = """usage: fm-search.sh [--limit N] [--json] [--urls | --deep] [--chain F|K] [--no-jev] "<query>"
       fm-search.sh --ledger
Web search router: Jev picks a query class, a provider chain (Exa, TinyFish, ketch) answers.
  --limit N    results wanted (default 5)
  --json       print {"results": [...], "meta": {...}} instead of text
  --urls       cheap URL list: TinyFish first
  --deep       hard question: Exa type auto first
  --chain F|K  force the chain (F keyless first, K keyed first)
  --no-jev     skip the Jev class pick and use chain F
  --ledger     month-to-date spend and calls per provider
Exit: 0 results, 3 every hop empty (one line per hop on stderr), 1 usage error.
Send only non-private queries: the query goes to third-party providers."""


class HopError(Exception):
    pass


def load_config():
    cfg = json.loads(json.dumps(DEFAULTS))
    path = os.environ.get("FM_SEARCH_CONFIG") or os.path.join(FM_HOME, "config", "fm-search.json")
    try:
        with open(path) as f:
            user = json.load(f)
        for sect, vals in user.items():
            if isinstance(vals, dict) and isinstance(cfg.get(sect), dict):
                cfg[sect].update(vals)
    except (OSError, ValueError):
        pass
    return cfg


def key(name):
    try:
        with open(os.path.join(KEY_DIR, name + ".key")) as f:
            return f.read().strip() or None
    except OSError:
        return None


def norm(title, url, date, text):
    return {"title": (title or "").strip(), "url": url or "", "date": (date or "")[:10],
            "snippet": re.sub(r"^Published: \S+ ?", "", " ".join((text or "").split()))}


def http(req, timeout):
    """One request under one deadline that also covers the body, so a trickled response cannot hold the hop."""
    deadline = time.monotonic() + timeout
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            body = []
            while True:
                if time.monotonic() > deadline:
                    raise HopError("timeout")
                chunk = r.read1(65536)
                if not chunk:
                    return b"".join(body).decode()
                body.append(chunk)
    except HopError:
        raise
    except urllib.error.HTTPError as e:
        raise HopError("http %d" % e.code)
    except TimeoutError:
        raise HopError("timeout")
    except urllib.error.URLError as e:
        raise HopError("timeout" if "timed out" in str(e.reason) else "network error")
    except (OSError, HTTPException):
        raise HopError("network error")


def parse_json(raw):
    try:
        return json.loads(raw)
    except ValueError:
        raise HopError("bad json")


def run_ketch(args, query, limit, timeout):
    try:
        p = subprocess.run([KETCH, "search", query, "--limit", str(limit), "--json"] + args,
                           capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        raise HopError("timeout")
    except OSError:
        raise HopError("ketch not runnable")
    if p.returncode != 0:
        raise HopError("ketch exit %d" % p.returncode)
    items = parse_json(p.stdout) or []
    out = []
    for x in items[:limit]:
        desc = x.get("description") or ""
        date = desc[len("Published: "):] if desc.startswith("Published: ") and "N/A" not in desc else ""
        out.append(norm(x.get("title"), x.get("url"), date, x.get("content") or desc))
    return out, 0.0


def run_exa(kind, per_query, query, limit, timeout):
    k = key("exa")
    body = json.dumps({"query": query, "type": kind, "numResults": limit,
                       "contents": {"highlights": True}}).encode()
    raw = http(urllib.request.Request(EXA_URL, body, {"x-api-key": k, "Content-Type": "application/json"}), timeout)
    d = parse_json(raw)
    out = [norm(x.get("title"), x.get("url"), x.get("publishedDate"), "\n".join(x.get("highlights") or []))
           for x in d.get("results", [])[:limit]]
    cost = (d.get("costDollars") or {}).get("total")
    return out, float(cost) if cost is not None else per_query


def run_tinyfish(query, limit, timeout, language):
    params = {"query": query}
    if language:
        params["language"] = language
    req = urllib.request.Request(TINYFISH_URL + "?" + urllib.parse.urlencode(params), headers={"X-API-Key": key("tinyfish")})
    d = parse_json(http(req, timeout))
    return [norm(x.get("title"), x.get("url"), x.get("date"), x.get("snippet")) for x in d.get("results", [])[:limit]], 0.0


# ledger -------------------------------------------------------------------

def month_of(ts):
    return time.strftime("%Y-%m", time.gmtime(ts))


def read_ledger():
    rows = []
    try:
        with open(LEDGER) as f:
            for line in f:
                p = line.rstrip("\n").split("\t")
                if len(p) >= 6:
                    try:
                        rows.append((int(p[0]), p[1], float(p[2]), float(p[3]), int(p[4]), p[5]))
                    except ValueError:
                        pass
    except OSError:
        pass
    return rows


def append_ledger(provider, cost, lat, n, route):
    os.makedirs(STATE, exist_ok=True)
    with open(LEDGER, "a") as f:
        f.write("%d\t%s\t%.5f\t%.2f\t%d\t%s\n" % (time.time(), provider, cost, lat, n, route))


def exa_month_spend(rows, now):
    m = month_of(now)
    return sum(r[2] for r in rows if r[1].startswith("exa-") and r[1] != "exa-keyless" and month_of(r[0]) == m)


def warn_exa(cfg, spend, now):
    cap = cfg["exa"]["monthly_usd_cap"]
    if cap <= 0 or spend < cap * cfg["exa"]["warn_fraction"]:
        return
    marker = os.path.join(STATE, "exa-warned-" + month_of(now))
    if os.path.exists(marker):
        return
    os.makedirs(STATE, exist_ok=True)
    open(marker, "w").close()
    sys.stderr.write("warning: exa spend $%.2f is %d%% of the $%.2f monthly cap\n" % (spend, spend / cap * 100, cap))


def show_ledger(cfg):
    now = time.time()
    m = month_of(now)
    agg = {}
    for ts, prov, cost, _lat, _n, _route in read_ledger():
        if month_of(ts) == m:
            c = agg.setdefault(prov, [0, 0.0])
            c[0] += 1
            c[1] += cost
    print("fm-search ledger %s (UTC)" % m)
    for prov in ["exa-keyless", "exa-lite", "exa-deep", "tinyfish", "ketch-multi"]:
        c = agg.pop(prov, [0, 0.0])
        print("%-12s calls=%d cost=$%.4f" % (prov, c[0], c[1]))
    for prov, c in sorted(agg.items()):
        print("%-12s calls=%d cost=$%.4f" % (prov, c[0], c[1]))
    cap = cfg["exa"]["monthly_usd_cap"]
    spend = exa_month_spend(read_ledger(), now)
    print("exa-total    $%.4f of $%.2f cap (%d%%)" % (spend, cap, spend / cap * 100 if cap else 0))
    if cap > 0 and spend >= cap * cfg["exa"]["warn_fraction"]:
        print("warning: exa spend crossed %d%% of the monthly cap" % (cfg["exa"]["warn_fraction"] * 100))


# routing ------------------------------------------------------------------

def qhash(query):
    return hashlib.sha256(query.lower().encode()).hexdigest()[:24]


def cache_get(query, cfg, now):
    h = qhash(query)
    ttl = cfg["jev"]["route_cache_hours"] * 3600
    try:
        with open(ROUTE_CACHE) as f:
            for line in f:
                p = line.rstrip("\n").split("\t")
                if len(p) >= 3 and p[0] == h and now - int(p[1]) < ttl:
                    return p[2]
    except (OSError, ValueError):
        pass
    return None


def cache_put(query, cls, now):
    os.makedirs(STATE, exist_ok=True)
    with open(ROUTE_CACHE, "a") as f:
        f.write("%s\t%d\t%s\n" % (qhash(query), now, cls))


def jev_class(query, cfg):
    """Return the class name, or None when the deterministic chain F default applies."""
    if len(query.encode()) > cfg["jev"]["max_query_bytes"]:
        return None
    now = int(time.time())
    cached = cache_get(query, cfg, now)
    if cached:
        return cached
    args = [JEV_BIN, "pick", "--json", json.dumps({"search_query": query}, ensure_ascii=False),
            "Which kind of web lookup is search_query?"] + ["%s=%s" % c for c in CLASSES]
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=30)
        if p.returncode != 0:
            return None
        ans = json.loads(p.stdout)["answers"]
        ans = ans[next(iter(ans))]
        cls, conf = ans["choice"], float(ans["confidence"])
    except (OSError, subprocess.TimeoutExpired, ValueError, KeyError, StopIteration, TypeError):
        return None
    if cls not in dict(CLASSES) or conf < cfg["jev"]["confidence_floor"]:
        return None
    cache_put(query, cls, now)
    return cls


# chain walk ---------------------------------------------------------------

def hop_order(args, cls):
    if args["deep"]:
        return ["exa-deep"] + [h for h in CHAIN_F if h != "exa-lite"]
    if args["urls"]:
        return ["tinyfish"] + [h for h in CHAIN_F if h != "tinyfish"]
    if args["chain"] == "K" or (args["chain"] is None and cls in KEYED_FIRST):
        return CHAIN_K
    return CHAIN_F


def tinyfish_blocked(cfg):
    now = time.time()
    rows = [r for r in read_ledger() if r[1] == "tinyfish"]
    if sum(1 for r in rows if now - r[0] < 60) >= cfg["tinyfish"]["per_minute"]:
        return "per-minute cap"
    if sum(1 for r in rows if now - r[0] < 86400) >= cfg["tinyfish"]["per_day"]:
        return "per-day cap"
    return None


@contextlib.contextmanager
def capped(name, wait):
    """Hold the provider's lock across cap check, call and ledger line, so parallel workers cannot all pass one cap."""
    os.makedirs(STATE, exist_ok=True)
    with open(os.path.join(STATE, name + ".lock"), "a") as f:
        deadline = time.monotonic() + wait
        while True:
            try:
                fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except OSError:
                if time.monotonic() > deadline:
                    raise HopError("skipped: %s busy" % name)
                time.sleep(0.05)
        try:
            yield
        finally:
            fcntl.flock(f, fcntl.LOCK_UN)


def logged(hop, route, call):
    """Run one provider call and write its ledger line; return (results, cost) or raise HopError."""
    t0 = time.time()
    try:
        results, cost = call()
    except HopError:
        append_ledger(hop, 0.0, time.time() - t0, 0, route)
        raise
    append_ledger(hop, cost, time.time() - t0, len(results), route)
    return results, cost


def attempt(hop, query, limit, cfg, cls, route):
    """Return (results, cost) or raise HopError; a skip raises HopError with a 'skipped' reason."""
    t = cfg["timeouts_s"][hop]
    if hop in ("exa-lite", "exa-deep"):
        if not key("exa"):
            raise HopError("skipped: no exa key")
        deep = hop == "exa-deep"
        price = cfg["exa"]["deep_per_query_usd" if deep else "per_query_usd"]
        with capped("exa", t):
            now = time.time()
            spend = exa_month_spend(read_ledger(), now)
            if spend + price > cfg["exa"]["monthly_usd_cap"] + 1e-9:
                raise HopError("skipped: exa monthly cap reached")
            out = logged(hop, route, lambda: run_exa(cfg["exa"]["deep_type" if deep else "type"], price, query, limit, t))
            warn_exa(cfg, exa_month_spend(read_ledger(), now), now)
            return out
    if hop == "tinyfish":
        if not key("tinyfish"):
            raise HopError("skipped: no tinyfish key")
        with capped("tinyfish", t):
            why = tinyfish_blocked(cfg)
            if why:
                raise HopError("skipped: tinyfish " + why)
            return logged(hop, route, lambda: run_tinyfish(query, limit, t, "de" if cls == "de_admin" else None))
    return logged(hop, route, lambda: run_ketch(["-b", "exa"] if hop == "exa-keyless" else ["--multi"], query, limit, t))


def parse_args(argv):
    a = {"limit": 5, "json": False, "urls": False, "deep": False, "chain": None, "no_jev": False,
         "ledger": False, "query": None}
    i = 0
    while i < len(argv):
        x = argv[i]
        if x == "--limit":
            i += 1
            if i >= len(argv) or not argv[i].isdigit() or int(argv[i]) < 1:
                return None
            a["limit"] = min(int(argv[i]), 20)
        elif x in ("--json", "--urls", "--deep", "--ledger"):
            a[x[2:]] = True
        elif x == "--no-jev":
            a["no_jev"] = True
        elif x == "--chain":
            i += 1
            if i >= len(argv) or argv[i] not in ("F", "K"):
                return None
            a["chain"] = argv[i]
        elif x.startswith("-") and x != "-":
            return None
        elif a["query"] is None:
            a["query"] = x
        else:
            return None
        i += 1
    if a["urls"] and a["deep"]:
        return None
    if a["ledger"]:
        return a if a["query"] is None else None
    return a if a["query"] and a["query"].strip() else None


def main():
    if sys.argv[1:2] in (["-h"], ["--help"]):
        print(USAGE)
        return 0
    args = parse_args(sys.argv[1:])
    if args is None:
        sys.stderr.write(USAGE + "\n")
        return 1
    cfg = load_config()
    if args["ledger"]:
        show_ledger(cfg)
        return 0
    query = args["query"].strip()
    start = time.time()
    forced = args["chain"] is not None or args["urls"] or args["deep"]
    cls = None
    if not forced and not args["no_jev"]:
        cls = jev_class(query, cfg)
    route = "forced" if forced else ("jev" if cls else "default")
    hops = hop_order(args, cls)
    notes = []
    for n, hop in enumerate(hops, 1):
        try:
            results, cost = attempt(hop, query, args["limit"], cfg, cls, route)
        except HopError as e:
            notes.append("%s: %s" % (hop, e))
            continue
        if not results:
            notes.append("%s: empty" % hop)
            continue
        meta = {"provider": hop, "hops": n, "lat": round(time.time() - start, 2), "cost": round(cost, 5), "route": route}
        if cls:
            meta["class"] = cls
        if args["json"]:
            print(json.dumps({"results": results, "meta": meta}, ensure_ascii=False))
        else:
            for i, r in enumerate(results, 1):
                print("%d. %s" % (i, r["title"] or r["url"]))
                print("   %s%s" % (r["url"], " (%s)" % r["date"] if r["date"] else ""))
                if r["snippet"] and not args["urls"]:
                    print("   " + r["snippet"][:400])
            print("provider=%s hops=%d lat=%.1f cost=$%.4f route=%s" % (hop, n, meta["lat"], cost, route))
        return 0
    for line in notes:
        sys.stderr.write("fm-search: " + line + "\n")
    return 3


if __name__ == "__main__":
    sys.exit(main())
