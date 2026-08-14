# Authoring notes - Umzugservice Bochum design system v1

What was taken from each scout report, what was rejected and why, how the header conflict was resolved, and every place this system deliberately diverges from Umzugservice Dortmund.

The governing rule throughout: **take relationships, not literal values.** A type ratio, a spacing base, an accent percentage and a component's set of states transfer to a different business. The reference's hexes, typefaces and assets do not. Not one colour, typeface, radius, duration or asset from the reference appears in this system.

---

## 1. Structure report (`bochum-ref-structure-v1`)

### Taken

| Finding | How it lands here |
|---|---|
| Recommended twelve-section order | Adopted as §13's order, with three adjustments driven by the contact decision (below). |
| Vertical padding runs on a four-step scale with one deliberately oversized pause | Became three padding tokens plus a single 160px pause used at most once per page. |
| Container width signals what a section is | Rejected in that form - see below - but the underlying idea that width is a system value became one content width plus one prose measure. |
| Every dropdown terminates in a contact action; five routes to contact in the navigation alone | Kept as intent, not as mechanism: with no dropdowns, the mobile drawer ends with all three contact routes repeated full width. |
| Eight of ten body sections carry zero links; CTA gaps of 4.9 and 5.3 screens | Inverted. An action is within reach on every screen, mostly because the header never leaves. |
| Hero carries zero actions | Inverted. Three actions in the hero: phone, WhatsApp, quote. |
| The team photograph is the most valuable section to carry over | Kept, and given the strongest structural treatment in the system: it is a **proof** figure with required caption and source, adjacent to reviews. |
| Roughly every second section is an inset panel on a plain ground; a small consistent radius vocabulary | Kept as a relationship; every value is Bochum's own. |
| Page length target 6-8 screens | Adopted as a stated target. |

### Rejected

- **The three-screen sticky case-study stack.** A studio has product screenshots that are beautiful full-bleed; a mover's finished work is a flat empty room. Three screens of it would be stock vans and cardboard boxes. Cut - and cutting it is also what keeps the page to 6-8 screens.
- **Capability tool-logo grid, awards section, Products dropdown.** No truthful equivalent exists. Forcing them produces sections that visibly have nothing in them.
- **The five-dropdown, 26-destination IA.** Copying that depth means inventing pages to fill it, each of which then sits empty and dates the site. Four or five flat links instead.
- **The ten-field qualification form with a budget bracket.** It is a filter built for a business model that does not apply. Replaced by eight fields that a person can answer about a move.
- **Seven inner container widths.** The report calls this out as the reference looking systematic without being it. One content width, one prose measure.
- **The persistent WhatsApp bubble.** Removed - see §3.
- **No consent position.** Not inherited by omission; §7 of the system takes one.

### Not used

The report's §7 ordering rests on live measurement plus reasoning about the audience, and it says so - the wiki pages admitted for that task explicitly leave section ordering unresolved. That honesty is why the ordering was adopted as reasoning to check rather than as authority to cite.

---

## 2. Motion report (`bochum-ref-motion-v1`)

### Taken

| Finding | How it lands here |
|---|---|
| One layout-animating effect on an 11,000px page is the biggest reason it feels expensive | Count here is **zero**. Nothing animates a layout property. |
| Four verbs, one easing family, two duration bands, reused everywhere | Became four verbs (`enter`, `enter-stagger`, `respond`, `pin`), one `--ease-out` family, three durations. |
| Reveals fire once on entry and never replay | Adopted verbatim as a rule. |
| The sticky panel stack is free, robust, and the only effect that survives with scripting off | Kept as `pin`, used once, desktop and tablet only. |
| Effects switched off entirely at small widths - knowing when *not* to run an effect | Adopted: `pin` is off below 768px. |
| Six-event budget | Adopted exactly, and §6.2 spends all six explicitly so the budget is auditable rather than aspirational. |
| A block fade-up resolves faster and costs a fraction of the DOM of a character split | Adopted: 560ms + 70ms stagger, capped at five children. |
| `js-motion` gating class; author the final state and gate the *hiding* | Adopted verbatim into `tokens.css`. It is the single hardest thing to retrofit. |
| The reduced-motion contract, including "scripts must check the query themselves" | Adopted as §6.3, including the frame-by-frame test that proves it. |
| Counters that start near their answer | **Not used at all** - see rejected. |
| Hover physics: controls shrink, content grows, rows slide, buttons lift | Adopted as the hover grammar. |
| Five pre-launch checks, each of which caught something real | Adopted as §6.5. |

### Rejected

- **Hide-on-scroll header.** The one real conflict. See §3.
- **Character-split reveals.** Nobody reads a paragraph as a shape, and animating a fact one character at a time frames it as a performance at the moment the reader wants it framed as a commitment.
- **The perpetual logo marquee.** A page element that never stops moving reads as an advertisement. Someone reading about clearing a deceased relative's home should have nothing in their peripheral vision that will not hold still. This was the clearest single "no" in the report and it is honoured absolutely: there is no looping animation anywhere.
- **Auto-advancing content of any kind.** Content that moves on without being asked says the page's agenda outranks the reader's.
- **Counting numbers up.** Two reasons, and the second is the stronger one here: animating a number draws attention to it, which is the last thing to do next to a figure that cannot yet be substantiated (§9 of the system).
- **Overshoot / bounce / elastic easings on calls to action.** A quote button is a promise about someone's home.
- **The scroll-scrubbed aperture moment.** Optional in the report and capped at one per site. Not spent: the six events are better spent on entrances, and the only imagery that could carry it does not exist yet.
- **The mouse-only accordion.** Replaced by native `<details>`, operable by tap, keyboard and with scripting disabled.

### Faults treated as a checklist, not a pattern

Reduced motion ignored entirely; one JavaScript-only content section; keyboard- and touch-inoperable accordion; a dead animation script shipping a duplicate GSAP on every page load; a resize handler that is a no-op; a declared entrance whose targets are 0×0. Each has an explicit counter-rule in §6.3, §6.4 and §10.5.

---

## 3. The header conflict

**The disagreement.** The motion report ranks a hide-on-scroll header among the three effects worth carrying, and argues it well: it responds to intent rather than to position, and it gives back a strip of screen while reading.

**Why it is wrong here.** The captain confirmed phone and WhatsApp as both primary and both present in the header on every screen. A header that hides removes both primary contact routes for the entire downward scroll. The structure report reaches the same conclusion from its own lens and states it flatly: a header that hides while you scroll is defensible when the only action is a form on another page, and indefensible when the header is carrying the phone number.

**Resolution: rejected. The header is sticky and always visible - it never hides, and it never condenses.**

Condensing on scroll was considered as a way to keep some of the benefit and was rejected too: animating header height is a layout animation on scroll, it risks CLS, and this system's count of layout-animating effects is zero. Instead the reclaimed space is bought permanently - the header is 64px on desktop and 56px on a phone from the first pixel, against the reference's 70px.

**The other two carried effects are kept**: the once-only content entrance as a block fade-up, and the sticky `pin`.

**A second-order consequence, recorded because it is easy to miss.** The reference's persistent WhatsApp bubble exists to compensate for the hiding header. With the header present, the bubble is redundant - and on the reference at 390px it sits on top of body copy with no reserved gutter. It is removed. Rejecting the hide-on-scroll behaviour is what makes removing it safe.

---

## 4. Visual-system report (`bochum-ref-designsystem-v1`)

### Taken

| Finding | How it lands here |
|---|---|
| Two type ratios with a gap: ≈1.13 reading, ≈1.38 display | Adopted as 1.136 and 1.35 with an explicit 1.30 gap and nothing landing in it. The single most transferable fact in the three reports. |
| Line height is a function of size in five stops | Adopted, and bound into role classes so the wrong combination is not available. |
| Tracking only above ~2.5rem, negative | Adopted as a principle; **the unit is rejected** - `em`, not `px`. The reference's flat `-0.8px` is three times tighter on a phone than on a desktop. |
| Display collapses 2.5-3×, reading type moves 0-14% | Adopted; every display role collapses at 0.41, body is fixed at 1.00. |
| A serif's fallback must be a serif | Adopted, and it is why the display stack ends `Georgia, "Times New Roman", serif`. |
| Three grounds, stated rhythm, never more than ~3 screens on one | Adopted, with the split inverted toward light. |
| Accent under 1% of the page, concentrated on one screen | Adopted as a target, with three painted-fill locations named. |
| Emphasis by contrast mid-sentence, as **one reusable role** | Adopted as `.emph`. The reference's nineteen numbered spans are exactly the plumbing to avoid. |
| A size ramp needs a text-contrast ramp referenced alongside it | Adopted: three text tones per ground family. |
| Depth by ground change, zero shadows, near-zero borders | Adopted, and hardened into a stated combination rule. |
| Radius proportional to size; controls fully round; cap at five values | Adopted: five plus a pill, against the reference's twelve. |
| 4px base, declared and actually obeyed | Adopted, and made self-enforcing by naming each token after its multiple. |
| The framed page | Adopted as a relationship. All values are Bochum's own. |
| Hover physics | Adopted. |
| Reserve the focus ring's space with a transparent boundary | Adopted - **and then a visible ring is actually put in it.** |
| Primitives aliased into semantics; semantic names carry their ground | Adopted. There is no `--color-text-tertiary` in this system. |
| Rules testable, constraints countable, principles stated | Adopted as §0 and §14, and `check-contrast.mjs` makes the colour rules executable. |

### Rejected

- **The serif-italic heading accent.** The report's own recommendation 8 says keep the structure and change the device, because a mover copying it wears a design studio's clothes. Gone further: display type here is roman throughout, and heading-internal emphasis is carried by the contrast ramp. An italicised word inside an upright heading is also one of the most reliable machine-generated tells.
- **One dull grey across both grounds.** The direct cause of five of the reference's failures. Two tertiary tones, one per ground family, and the naming makes the single-grey mistake unavailable.
- **Reading text on live video.** The reference's hero paragraph swings between 3.95:1 and 8.56:1 depending on which second of footage is playing. That is not a contrast decision, it is a coin toss. The hero here is a split panel: every word sits on a solid surface.
- **Seven limes.** One accent, two derived states on one lightness axis.
- **Platform-stock breakpoints.** Three, named after the design, replacing defaults rather than extending them - a leftover default is a value nobody chose.
- **Hand-set section padding.** Three tokens, one mobile factor.
- **Invisible focus.** The reference's contact form has no visible keyboard focus at all. Every interactive component here ships a focus-visible state, and the ring is never animated in.
- **Two unreconciled unit systems and nine near-duplicate accordion classes.** Not a design decision to inherit, but the reason the token file is structured as primitives → semantics → bound roles.
- **A dark-dominant page.** 54% dark sells engineering. A company entering someone's home sells care. Inverted to roughly 67% light.

### The five contrast failures, closed

`#959595` on white (3.00), on light ground (2.72), `#A8C3BE` on teal (4.48), `#C6C6C6` on a bright video frame (3.95), `#65803A` on lime (3.18). All five share one cause: a colour named without its ground. This system has no ungrounded colour name, publishes all 85 permitted pairs with ratios, and asserts three banned pairs so a stale ban shows up as a check failure. Run `node check-contrast.mjs`.

---

## 5. Divergence from Umzugservice Dortmund

Dortmund: white protocol-paper, hairline rules as the structural material, label-and-value rows, an Übergabeprotokoll artefact. Six axes are opposed on purpose. The full table is §11 of the system document; the reasoning is here.

1. **Structural material.** Dortmund builds with hairline rules. This system has none - separation is a ground change. The single border in the whole system is 1.5px, and 1.5px was chosen over 1px specifically so it reads as the edge of a control rather than as a ruled line. That is a one-token decision made entirely for differentiation, and it is recorded here so nobody "tidies" it back to 1px.
2. **Neutral temperature.** Dortmund is cool white paper. Every neutral here carries a warm cast, and `#FFFFFF` appears nowhere in the system - the lightest surface is `#F6F4EF`. Two brands cannot share a neutral and read as separate companies.
3. **Colour family.** The brief's warning was that two shades of one blue is a failure. The answer went the other way: Bochum has **no second hue at all**. Ground, ink and accent are one warm family separated by value and saturation. It is a position no protocol-paper brand can hold, because protocol paper needs its ink to be neutral.
4. **Shape language.** Dortmund is flat, ruled and document-like. This is rounded, unruled and shadowless: a five-step radius ladder topping at 28px, controls fully round.
5. **Typefaces.** A slab-serif display with a humanist sans. No shared family and no shared classification with a document register.
6. **Hero construction.** Dortmund leads with a document artefact. This leads with a split panel - a solid ink panel carrying the headline and all three contact actions, beside a photograph. The construction is also forced by the contrast finding: no reading text sits on imagery anywhere on this site.

**The organising difference underneath all six:** Dortmund's system is a *record* - it proves what was done. Bochum's is a *room* - warm, quiet, no sharp edges, one clearly marked door.

**Where the two could still drift together, and the guard against it:** both are light-dominant. That is the only shared axis, and it is defended by temperature (warm vs cool), by material (ground change vs rule) and by shape (round vs flat). If a future change makes Bochum's ground cooler or reintroduces a 1px rule as a layout device, the differentiation collapses on the axis where it is thinnest. Treat those two as locked.

---

## 6. Deliberate divergences from all three reports

Recorded because they are judgement calls, not oversights.

- **Colour is authored in hex, not OKLCH.** The next consumer of this file is a Figma prototype, and Figma variables take hex. The OKLCH value of every primitive is in the comment beside it, so perceptual reasoning about the ramps is still possible.
- **Container width does not signal section type.** The reference uses seven widths to say what a section is; the visual report calls that out as not a system. Section type is signalled by ground and rhythm instead, both of which are already tokens.
- **`pin` is spent on the hero panel, not on a Referenzen stack.** The structure report cuts the case-study stack, so the effect it was carried for has no content. Putting it on the hero keeps the carried effect real rather than reserving it for a section that may never exist.
- **The scroll-scrubbed moment is not spent.** Permitted by the motion report at one per site, but there is no confirmed photograph to spend it on, and an effect held for content that does not exist is an invitation to fill it with stock.
- **A `check-contrast.mjs` was added beyond the requested deliverables.** A written rule that is never tested against the build is the exact failure mode the design-systems literature reports first-hand: a file can pass a five-check audit with all zeros and still be wrong 33 times. The check is small, it runs in one command, and it states its own blind spots.

---

## 7. Wiki grounding, stated plainly

This task's routing preflight matched and admitted one page from the website knowledge base's design pillar, through the owning home's bounded reader.

**What it supplied** - framing only, and only for how the system is *shaped*:

- A design system is *rules, principles and constraints implemented in design and code* - rules are testable, constraints are countable. That is §0 and §14.
- A token is the only format that crosses a tool boundary, which is why `tokens.css` is a first-class deliverable rather than an appendix to the document.
- Type size, line height and letter spacing must be bound together rather than listed separately.
- A size ramp needs a text-contrast ramp alongside it, because a text role is never separated by a single property.
- Defaults should be replaced, not extended - a leftover default is a value nobody chose. That is why there are three breakpoints and not six.
- An audit reporting zeros must state what it does not cover, and the checks that close the gap are additive: content bounds must be a subset of frame bounds; a variable bound to a text fill must carry text-fill scope; forbidden pairs must be resolved against each text node's nearest painted ancestor. That is §2.6.

**What it did not supply**, so nothing below is presented as wiki-grounded: anything about the reference site, about moving services, about Bochum, about this palette, this type pairing, this section order or this motion budget. Every measurement comes from the three scout reports; every design decision is judgement applied to those measurements and to the captain's confirmed constraints, and is presented as such.

---

## 8. What is not verified

Stated rather than left implied, since this system publishes green numbers.

1. **No page has been built from these tokens.** The contrast rules are proven at token level; the three page-level checks in §2.6 - nearest painted ancestor, content bounds inside frame bounds, token scope matching the bound property - cannot run until something exists to run them against.
2. **The typefaces have not been rendered in situ.** Zilla Slab and Source Sans 3 are chosen for classification, weight availability, German diacritic coverage and fallback integrity. Their optical fit at 86px and at 16px should be confirmed on the first real screen, and the display face is the one token most likely to move after that look.
3. **The ground split of roughly 67/33 is a target, not a measurement.** It can only be verified against a built page, by the same two independent methods the visual report used.
4. **The accent's sub-1% coverage is likewise a target.** Three painted-fill locations are named so it can be checked rather than estimated.
5. **Touch ergonomics are specified, not tested.** 44×44px minimums and 8px separation are stated; they need a real device.
6. **Nothing here has been reviewed by the captain.** Every unconfirmed fact is a typed placeholder rather than a plausible-looking number, so the review can be about the system rather than about which figures are real.
