#!/usr/bin/env node
/**
 * Umzugservice Bochum - contrast rule check.
 *
 * A rule is testable or it is decoration. This script reads tokens.css, resolves
 * every semantic colour token through its var() chain to a hex primitive, and
 * checks each pair this system permits against its WCAG 2.2 minimum.
 *
 *   node check-contrast.mjs
 *
 * WHAT THIS CHECKS: the pairs declared in the manifest below.
 * WHAT THIS DOES NOT CHECK, stated so a green result is not read as a claim it
 * never made:
 *   - which ancestor a text node is actually painted on in a built page. A
 *     token pair can be correct in the abstract and wrong on the page. Resolve
 *     forbidden pairs against each text node's nearest painted ancestor in the
 *     built HTML; that is a separate check the builder owns.
 *   - text over photography or video. This system forbids reading text on live
 *     video outright, so there is no ratio to compute.
 *   - whether a bound token is used on a property its scope allows.
 */

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const css = readFileSync(join(here, "tokens.css"), "utf8");

/* ---------- resolve tokens -------------------------------------------- */

const decls = new Map();
for (const m of css.matchAll(/(--[a-z0-9-]+)\s*:\s*([^;]+);/gi)) {
  decls.set(m[1], m[2].trim());
}

function resolve(name, seen = new Set()) {
  if (seen.has(name)) throw new Error(`circular token: ${name}`);
  seen.add(name);
  const raw = decls.get(name);
  if (raw === undefined) throw new Error(`undeclared token: ${name}`);
  const ref = raw.match(/^var\(\s*(--[a-z0-9-]+)\s*\)$/i);
  if (ref) return resolve(ref[1], seen);
  if (/^#[0-9a-f]{6}$/i.test(raw)) return raw.toLowerCase();
  throw new Error(`token ${name} is not a hex colour: ${raw}`);
}

/* ---------- WCAG 2.x relative luminance ------------------------------- */

const channel = (v) => {
  const c = v / 255;
  return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
};

const luminance = (hex) => {
  const n = parseInt(hex.slice(1), 16);
  return (
    0.2126 * channel((n >> 16) & 255) +
    0.7152 * channel((n >> 8) & 255) +
    0.0722 * channel(n & 255)
  );
};

const ratio = (a, b) => {
  const [x, y] = [luminance(a), luminance(b)].sort((p, q) => q - p);
  return (x + 0.05) / (y + 0.05);
};

/* ---------- the manifest ---------------------------------------------- */
/* min 4.5 = body text.  min 3.0 = large text (>=24px, or >=18.66px bold),
   non-text UI boundaries, focus indicators, and disabled text.             */

const LIGHT = [
  ["--color-ground-page", "page"],
  ["--color-ground-panel", "panel"],
  ["--color-ground-panel-alt", "panel-alt"],
  ["--color-ground-accent", "accent band"],
];
const INK = [
  ["--color-ground-ink", "ink"],
  ["--color-ground-ink-alt", "ink-alt"],
];

const pairs = [];
const on = (grounds, token, min, role) => {
  for (const [g, label] of grounds) pairs.push({ fg: token, bg: g, min, role, label });
};

/* text on light */
on(LIGHT, "--color-text-primary-on-light", 4.5, "body / heading");
on(LIGHT, "--color-text-secondary-on-light", 4.5, "secondary paragraph");
on(LIGHT, "--color-text-tertiary-on-light", 4.5, "tertiary / caption");
on(LIGHT, "--color-link-on-light", 4.5, "text link");
on(LIGHT, "--color-error-on-light", 4.5, "field error");
on(LIGHT, "--color-success-on-light", 4.5, "field success");
on(LIGHT, "--color-unconfirmed-on-light", 4.5, "unconfirmed placeholder");
on(LIGHT, "--color-line-on-light", 3.0, "control boundary");
on(LIGHT, "--color-disabled-on-light", 3.0, "disabled label");
on(LIGHT, "--color-focus-on-light", 3.0, "focus ring");
on(LIGHT, "--color-accent", 3.0, "primary action fill");
on(LIGHT, "--color-accent-hover", 3.0, "primary action fill, hover");
on(LIGHT, "--color-accent-press", 3.0, "primary action fill, press");

/* text on ink */
on(INK, "--color-text-primary-on-ink", 4.5, "body / heading");
on(INK, "--color-text-secondary-on-ink", 4.5, "secondary paragraph");
on(INK, "--color-text-tertiary-on-ink", 4.5, "tertiary / caption");
on(INK, "--color-error-on-ink", 4.5, "field error");
on(INK, "--color-success-on-ink", 4.5, "field success");
on(INK, "--color-unconfirmed-on-ink", 4.5, "unconfirmed placeholder");
on(INK, "--color-line-on-ink", 3.0, "control boundary");
on(INK, "--color-disabled-on-ink", 3.0, "disabled label");
on(INK, "--color-focus-on-ink", 3.0, "focus ring");
on(INK, "--color-action-inverse", 3.0, "inverted action fill");
on(INK, "--color-action-inverse-hover", 3.0, "inverted action fill, hover");
on(INK, "--color-action-inverse-press", 3.0, "inverted action fill, press");

/* text on the accent fill and its states */
for (const [t, label] of [
  ["--color-accent", "accent"],
  ["--color-accent-hover", "accent hover"],
  ["--color-accent-press", "accent press"],
]) {
  pairs.push({ fg: "--color-text-on-accent", bg: t, min: 4.5, role: "action label", label });
  pairs.push({ fg: "--color-focus-on-accent", bg: t, min: 3.0, role: "focus ring", label });
}

/* text on the inverted action fill and its states */
for (const [t, label] of [
  ["--color-action-inverse", "inverse"],
  ["--color-action-inverse-hover", "inverse hover"],
  ["--color-action-inverse-press", "inverse press"],
]) {
  pairs.push({
    fg: "--color-text-on-action-inverse",
    bg: t,
    min: 4.5,
    role: "action label",
    label,
  });
}

/* ---------- forbidden pairs, asserted rather than assumed -------------- */
/* Each of these is a combination the system explicitly bans. The check proves
   the ban is earned: if one of them ever clears its threshold, the ban is
   stale and the document is wrong.                                        */

const forbidden = [
  {
    fg: "--color-accent",
    bg: "--color-ground-ink-alt",
    under: 3.0,
    why: "the bronze fill is not identifiable on ink; use the inverted action",
  },
  {
    fg: "--color-accent",
    bg: "--color-ground-page",
    under: 4.5,
    why: "the accent is a fill, not body text on the page ground",
  },
  {
    fg: "--color-text-secondary-on-light",
    bg: "--color-accent",
    under: 4.5,
    why: "only the on-accent label colour may sit on the accent fill",
  },
];

/* ---------- run -------------------------------------------------------- */

let failed = 0;
const rows = [];

for (const p of pairs) {
  const fg = resolve(p.fg);
  const bg = resolve(p.bg);
  const r = ratio(fg, bg);
  const ok = r >= p.min;
  if (!ok) failed++;
  rows.push({
    ok,
    r,
    min: p.min,
    text: `${fg} ${p.fg.replace("--color-", "")}`,
    ground: `${bg} ${p.label}`,
    role: p.role,
  });
}

const w = (s, n) => String(s).padEnd(n);
console.log(
  `\n${w("", 5)}${w("ratio", 8)}${w("min", 6)}${w("text", 42)}${w("on ground", 32)}role`,
);
console.log("-".repeat(120));
for (const r of rows) {
  console.log(
    `${w(r.ok ? "pass" : "FAIL", 5)}${w(r.r.toFixed(2), 8)}${w(r.min.toFixed(1), 6)}${w(
      r.text,
      42,
    )}${w(r.ground, 32)}${r.role}`,
  );
}

console.log("\nforbidden pairs (each must stay below its threshold):");
for (const f of forbidden) {
  const r = ratio(resolve(f.fg), resolve(f.bg));
  const held = r < f.under;
  if (!held) failed++;
  console.log(
    `${w(held ? "held" : "STALE", 6)}${w(r.toFixed(2), 8)}< ${f.under.toFixed(1)}  ` +
      `${f.fg.replace("--color-", "")} on ${f.bg.replace("--color-", "")} - ${f.why}`,
  );
}

console.log(
  `\n${rows.length} permitted pairs, ${forbidden.length} forbidden pairs, ${failed} problem(s).`,
);
console.log(
  "Not covered: nearest-painted-ancestor resolution in a built page, text over imagery, token scope.\n",
);

process.exit(failed === 0 ? 0 : 1);
