"""Independent recomputation of Claude equivalents for one real transcript (dedupe per message id, last usage wins)."""
import json, sys
path = sys.argv[1]
msgs = {}
for line in open(path):
    try: r = json.loads(line)
    except Exception: continue
    if r.get("type") != "assistant": continue
    m = r.get("message") or {}
    u = m.get("usage")
    if not isinstance(u, dict): continue
    msgs[(m.get("id"), r.get("requestId"))] = u
tot = dict(input=0, output=0, cacheRead=0, cacheWrite=0, cacheWrite1h=0)
eq = 0
for u in msgs.values():
    i, o = u.get("input_tokens", 0), u.get("output_tokens", 0)
    cr, cw = u.get("cache_read_input_tokens", 0), u.get("cache_creation_input_tokens", 0)
    w1h = min((u.get("cache_creation") or {}).get("ephemeral_1h_input_tokens", 0), cw)
    for k, v in zip(tot, (i, o, cr, cw, w1h)): tot[k] += v
    eq += round(i + 5*o + 0.1*cr + 1.25*(cw - w1h) + 2*w1h)
print(json.dumps({"messages": len(msgs), **tot, "rawTokens": tot["input"]+tot["output"]+tot["cacheRead"]+tot["cacheWrite"], "claudeEqTokens": eq}))
