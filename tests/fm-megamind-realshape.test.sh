#!/usr/bin/env bash
# Real-producer shape guard for bin/fm-megamind-preflight.sh and
# bin/fm-megamind-content.py, run against an installed megamind-axi.
#
# Every other Megamind suite drives a synthetic stub, which can only confirm the
# assumption already written into the stub. That is exactly how the reader came
# to require a routing mode ("bounded") that no Megamind release can emit: nine
# green tests, and not one of them had ever seen real upstream output. This
# suite closes that gap without asserting implementation-source bytes anywhere:
# it runs the real binary, hands its real output to the real host path, and
# requires the authorization to survive end to end.
#
# The estate is synthetic and built here, so no captain wiki is read and nothing
# depends on a private path. Set FM_MEGAMIND_REAL_EXE to point at a specific
# build; otherwise megamind-axi is resolved from PATH.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PREFLIGHT="$ROOT/bin/fm-megamind-preflight.sh"
READER="$ROOT/bin/fm-megamind-content.sh"
WORKER="$ROOT/bin/fm-worker-preflight.sh"

CHECKS=0
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
check() { CHECKS=$((CHECKS + 1)); }

EXE="${FM_MEGAMIND_REAL_EXE:-}"
if [ -z "$EXE" ]; then
  EXE="$(command -v megamind-axi 2>/dev/null || true)"
fi
if [ -z "$EXE" ] || [ ! -x "$EXE" ]; then
  # Skip loudly and name what stays unproven, rather than passing over it.
  echo "skip: no megamind-axi on PATH and no FM_MEGAMIND_REAL_EXE;"
  echo "skip: the real routing-mode vocabulary and ladder descent stay unproven here"
  exit 0
fi
for tool in jq python3; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is required for the real-shape guard"
done

LAB="$ROOT/.no-mistakes/megamind-realshape.$$"
mkdir -p "$LAB"
cleanup() { rm -rf "$LAB"; }
trap cleanup EXIT

HOME_DIR="$LAB/home"
ESTATE="$LAB/estate"
WIKI="$ESTATE/RealShapeWiki"
mkdir -p "$HOME_DIR/config" "$HOME_DIR/state" "$HOME_DIR/data/realshape" "$WIKI/.megamind" "$WIKI/wiki/concepts"
printf '%s\n' "$EXE" > "$HOME_DIR/config/megamind-executable"
printf '%s\n' "$ESTATE" > "$HOME_DIR/config/megamind-estate"
printf '%s\n' cloud > "$HOME_DIR/config/megamind-model-class"
printf '%s\n' "$$" > "$HOME_DIR/state/.lock"

# bin/fm-megamind-preflight.sh owns which releases this host accepts, so ask it
# rather than restating that list here. A build it will not route is a loud skip
# naming the version, never a failure and never a silent pass.
probe=$(FM_HOME="$HOME_DIR" "$PREFLIGHT" check 2>/dev/null || true)
if [ "$(printf '%s' "$probe" | jq -r '.outcome // "error"')" != available ]; then
  echo "skip: megamind-axi at $EXE is not routable by this host"
  echo "skip: $(printf '%s' "$probe" | jq -r '.failure.code // "unavailable"') (detected $(printf '%s' "$probe" | jq -r '.failure.detected // "unknown"'))"
  echo "skip: the real routing-mode vocabulary and ladder descent stay unproven here"
  exit 0
fi
VERSION="$(printf '%s' "$probe" | jq -r '.version')"

cat > "$WIKI/.megamind/wiki-card.json" <<'JSON'
{
  "schema": "megamind/wiki-card/v2",
  "version": 2,
  "name": "RealShapeWiki",
  "purpose": "Synthetic read-only fixture estate for the Firstmate real-shape guard.",
  "description": "Synthetic fixture knowledge for a host integration guard; no real subject matter.",
  "privacy": "public-reference",
  "sensitivity": "public-reference",
  "routing_mode": "full",
  "catalog_visibility": "full",
  "model_access": {"cloud": "full", "local": "full"},
  "index": "wiki/index.md",
  "card": "",
  "digest": "",
  "context_budget": {"max_candidates": 3, "max_context_chars": 6000},
  "freshness": {"half_life_days": 180, "last_confirmed": "2026-08-10"},
  "owners": ["Firstmate test suite"],
  "dependencies": [],
  "keywords": ["synthetic", "fixture", "widget", "sprocket", "flange"],
  "triggers": ["synthetic fixture concept"],
  "answers": ["synthetic fixture definitions for a host integration guard"],
  "examples": ["What is a synthetic widget?"],
  "negative_triggers": ["password", "credential"],
  "scope_boundaries": "Only the compiled wiki/ layer is routable.",
  "source_policy": {"allowlist": "raw/README.md", "allowlist_status": "approved", "summary": "Synthetic fixture only."}
}
JSON

# Three routable pages plus enough index filler that the index alone would
# overrun the declared character budget: the ladder must resolve pages, not hand
# back the index that lists them.
python3 - "$WIKI" <<'PY'
import pathlib, sys
wiki = pathlib.Path(sys.argv[1])
pages = {"widget.md": "Widget", "sprocket.md": "Sprocket", "flange.md": "Flange"}
for name, title in pages.items():
    (wiki / "wiki" / "concepts" / name).write_text(
        f"---\nupdated: 2026-08-10\n---\n\n# {title}\n\nSynthetic fixture page about the {title}. "
        + ("Synthetic filler sentence. " * 12) + "\n", encoding="utf-8")
lines = ["---", "updated: 2026-08-10", "---", "", "# RealShapeWiki Index", "", "## Concepts"]
lines += [f"- [{t}](concepts/{n})" for n, t in pages.items()]
lines += ["", "## Filler"]
lines += [f"- [Filler entry {i:03d} with a deliberately long label](concepts/filler-{i:03d}.md) - synthetic padding"
          for i in range(1, 91)]
(wiki / "wiki" / "index.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
PY

INDEX_CHARS=$(python3 -c "import pathlib,sys;print(len(pathlib.Path(sys.argv[1]).read_text(encoding='utf-8')))" "$WIKI/wiki/index.md")
[ "$INDEX_CHARS" -gt 6000 ] || fail "the fixture index ($INDEX_CHARS chars) no longer exceeds its declared budget"

printf 'synthetic widget sprocket flange fixture concepts\n' > "$HOME_DIR/data/realshape/megamind-request.md"

# --- the guard ---------------------------------------------------------------

FM_HOME="$HOME_DIR" "$WORKER" "$HOME_DIR" realshape >/dev/null 2>&1 \
  || fail "the worker binding refused a real megamind-axi $VERSION preflight"
AUTH="$HOME_DIR/state/realshape.megamind-preflight.json"
[ -f "$AUTH" ] || fail "no authorization was written for a real megamind-axi $VERSION preflight"

outcome=$(jq -r '.outcome' "$AUTH")
[ "$outcome" = matched ] || fail "real megamind-axi $VERSION preflight was $outcome, not matched"
check

# The reader must accept whatever routing mode the real producer emits. Asserting
# admission, not a literal, is what keeps this from re-encoding an assumption.
out=$(FM_HOME="$HOME_DIR" "$READER" admit --task-id realshape)
[ "$(printf '%s' "$out" | jq -r '.outcome')" = admitted ] \
  || fail "the reader refused a real megamind-axi $VERSION authorization: $out"
check

# The ladder descended: the authorized surface is the pages the index points at,
# never the index itself, and it stays inside the declared candidate budget.
allows=$(jq -c '.matches[0].allows' "$AUTH")
printf '%s' "$allows" | jq -e 'length > 0 and all(.[]; startswith("wiki/concepts/"))' >/dev/null \
  || fail "real megamind-axi $VERSION authorized $allows rather than ladder pages"
printf '%s' "$allows" | jq -e 'index("wiki/index.md") == null' >/dev/null \
  || fail "the routing index was still authorized alongside its own pages: $allows"
printf '%s' "$allows" | jq -e 'length <= 3' >/dev/null \
  || fail "the ladder exceeded the declared candidate budget: $allows"
check

# The binding the reader re-derives the load surface from must match exactly.
[ "$(jq -c '.authorization_binding.declared_allows[0].allows' "$AUTH")" = "$allows" ] \
  || fail "declared_allows disagreed with the authorized allows under real output"
check

# Content comes back through the channel, in budget, and never carries the index.
id=$(printf '%s' "$out" | jq -r '.admission_id')
content=$(FM_HOME="$HOME_DIR" "$READER" content --admission-id "$id") \
  || fail "the content channel refused a real admission"
printf '%s' "$content" | grep -q 'RealShapeWiki:wiki/concepts/' \
  || fail "the content channel emitted no ladder page"
printf '%s' "$content" | grep -q 'RealShapeWiki:wiki/index.md' \
  && fail "the content channel emitted the routing index"
chars=$(printf '%s' "$out" | jq -r '.wikis[0].context_chars')
budget=$(printf '%s' "$out" | jq -r '.wikis[0].max_context_chars')
[ "$chars" -le "$budget" ] || fail "admitted $chars chars against a $budget budget"
check

# A pointer mode is the only other value the producer can emit, and it must
# still refuse: this guard proves the accepted value, never a widened gate.
python3 - "$AUTH" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1]); d = json.loads(p.read_text())
for m in d["matches"]:
    m["routing_mode"] = "pointer"
for m in d["authorization_binding"]["declared_allows"]:
    m["routing_mode"] = "pointer"
p.write_text(json.dumps(d, separators=(",", ":")))
PY
out=$(FM_HOME="$HOME_DIR" "$READER" admit --task-id realshape)
[ "$(printf '%s' "$out" | jq -r '.refusal_code')" = authorization_invalid ] \
  || fail "a pointer routing mode was not refused under real output: $out"
check

[ "$CHECKS" -ge 6 ] || fail "the real-shape guard ran only $CHECKS checks and proved nothing"
pass "real megamind-axi $VERSION: ladder pages authorize, admit, and read back in budget"
