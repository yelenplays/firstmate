// Render a built bearings board's shipped inline script under a minimal DOM
// shim and print what the renderer actually produced, so board behavior is
// asserted through the real template rather than by reading its source.
//
// Usage: node board-render-harness.mjs <built-board.html>
// Prints one JSON document:
//   { stats:[{n,label,of,wip,over}], call_sub, calls:[{title,badges}],
//     underway:[{title,sub,badges}], charted:[{title,sub,badges,pickable}],
//     empty, more, error }
import { readFileSync } from "node:fs";

const html = readFileSync(process.argv[2], "utf8");

class Node {
  constructor(tag) {
    this.tagName = tag;
    this.className = "";
    this.children = [];
    this.attributes = {};
    this._text = "";
    this.hidden = false;
    this.disabled = false;
    this.innerHTML = "";
    this.parentNode = null;
    this.type = "";
    this.value = "";
    this.checked = false;
    const classes = () => this.className.split(/\s+/).filter(Boolean);
    this.classList = {
      add: (c) => { if (!classes().includes(c)) this.className = (this.className + " " + c).trim(); },
      remove: (c) => { this.className = classes().filter((x) => x !== c).join(" "); },
      contains: (c) => classes().includes(c),
      toggle: (c, force) => {
        const on = force === undefined ? !classes().includes(c) : Boolean(force);
        if (on) this.classList.add(c); else this.classList.remove(c);
        return on;
      },
    };
  }
  get textContent() {
    return this.children.length
      ? this.children.map((c) => c.textContent).join("")
      : this._text;
  }
  set textContent(v) { this._text = String(v); this.children = []; }
  appendChild(n) { n.parentNode = this; this.children.push(n); return n; }
  setAttribute(k, v) { this.attributes[k] = v; }
  addEventListener() {}
  querySelectorAll(sel) {
    const want = sel.replace(/^\./, "").replace(/:checked$/, "");
    const checkedOnly = sel.endsWith(":checked");
    const out = [];
    const walk = (n) => {
      for (const c of n.children) {
        if (c.className.split(/\s+/).includes(want) && (!checkedOnly || c.checked)) out.push(c);
        walk(c);
      }
    };
    walk(this);
    return out;
  }
}

const byId = new Map();
const dataNode = new Node("script");
dataNode.textContent = html
  .split('<script id="bearings-data" type="application/json">')[1]
  .split("</script>")[0];
byId.set("bearings-data", dataNode);

globalThis.document = {
  createElement: (tag) => new Node(tag),
  // Lazily mint any element the page asks for: the shim tracks whatever ids
  // the shipped template actually uses instead of pinning a fixed list.
  getElementById: (id) => {
    if (!byId.has(id)) {
      const n = new Node("div");
      new Node("div").appendChild(n);
      byId.set(id, n);
    }
    return byId.get(id);
  },
  querySelector: (sel) => {
    const id = "sel:" + sel;
    if (!byId.has(id)) byId.set(id, new Node("div"));
    return byId.get(id);
  },
};
globalThis.window = {};
globalThis.TextEncoder = TextEncoder;

const script = html.slice(html.indexOf("<script>") + "<script>".length, html.lastIndexOf("</script>"));
new Function(script)();

const badgesOf = (row) =>
  row.children
    .filter((c) => c.className.includes("fm-badge"))
    .map((c) => ({ tone: c.className.replace(/.*fm-badge--/, "").trim(), text: c.textContent }));

const findDeep = (node, cls) => {
  for (const c of node.children) {
    if (c.className.split(/\s+/).includes(cls)) return c;
    const hit = findDeep(c, cls);
    if (hit) return hit;
  }
  return undefined;
};

const strip = byId.get("bb-stats") || new Node("div");
const stats = strip.children.map((t) => ({
  n: Number(findDeep(t, "bb-stat__num")?.textContent),
  label: findDeep(t, "bb-stat__label")?.textContent,
  of: findDeep(t, "bb-stat__of")?.textContent ?? null,
  wip: findDeep(t, "bb-stat__wip")?.textContent ?? null,
  over: t.className.split(/\s+/).includes("bb-stat--over"),
}));
const callSub = byId.get("bb-call-sub")?.textContent ?? "";

// A Captain's Call card nests its badges inside the card head, so gather them
// from anywhere in the card, keeping each badge's hover title.
const deepBadges = (node) =>
  node.children.flatMap((c) =>
    c.className.includes("fm-badge")
      ? [{ tone: c.className.replace(/.*fm-badge--/, "").trim(), text: c.textContent, title: c.title ?? "" }]
      : deepBadges(c));
const deck = byId.get("bb-call") || new Node("div");
const calls = deck.children
  .filter((c) => c.className.split(/\s+/).includes("bb-decision"))
  .map((card) => ({ title: findDeep(card, "bb-decision__title")?.textContent ?? "", badges: deepBadges(card) }));

const rowsOf = (container) =>
  container.children
    .filter((r) => r.className.split(/\s+/).includes("bb-row"))
    .map((row) => {
      const main = row.children.find((c) => c.className.includes("bb-row__main"));
      return {
        title: main?.children.find((c) => c.className.includes("bb-row__title"))?.textContent ?? "",
        sub: main?.children.find((c) => c.className.includes("bb-row__sub"))?.textContent ?? "",
        badges: badgesOf(row),
        pickable: row.children.some((c) => c.className.includes("bb-pick") && !c.className.includes("spacer")),
      };
    });

const uw = byId.get("bb-underway") || new Node("div");
const underway = rowsOf(uw);

const ch = byId.get("bb-charted") || new Node("div");
const charted = rowsOf(ch);
// A fail-closed render replaces the page body instead of the board sections, so
// surface it rather than reporting an empty board as a successful render.
const errorText = [...byId.entries()]
  .filter(([k]) => k.startsWith("sel:"))
  .flatMap(([, n]) => n.children.map((c) => c.textContent))
  .join(" ");
const empty = ch.children.filter((c) => c.className.includes("bb-empty")).map((c) => c.textContent);
const more = ch.children.filter((c) => c.className.includes("bb-morechip")).map((c) => c.textContent);

process.stdout.write(
  JSON.stringify({ stats, call_sub: callSub, calls, underway, charted, empty, more, error: errorText }) + "\n");
