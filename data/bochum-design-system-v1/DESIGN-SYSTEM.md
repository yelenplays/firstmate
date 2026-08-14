# Umzugservice Bochum - design system v1

`umzugservice-bochum.de` · Umzug (privat und geschäftlich), Entrümpelung und Räumung, Haushaltsauflösung
Audience: affluent private households and businesses in Bochum. Not a bargain buyer.

This document and `tokens.css` are two halves of one thing. This half carries the rules, the reasoning and the component contracts; `tokens.css` carries the values. `check-contrast.mjs` proves the colour rules rather than asserting them.

**Direction: Filz und Bronze.** One warm hue family, three grounds, one accent, no shadows, no rules. The page is a set of soft warm panels floating on a felt-toned ground, the only saturated object on it is the thing you press, and the loudest typographic object after the headline is the phone number.

Every choice below carries a one-line reason against a measured finding from the three reference scouts or against a captain constraint. A system whose author cannot say why a number was chosen does not survive its first argument.

---

## 0. The three kinds of statement in here

Borrowed framing, and it decides how each line is enforced:

- **Rules** are testable. "Every text-on-ground pair meets 4.5:1." `check-contrast.mjs` runs them.
- **Constraints** are countable. "One accent. Four font weights. Five radii. Three grounds. Six motion events."
- **Principles** are judged. "Colour marks the next step and nothing else."

Where a rule exists, it is checked against the built page, not against the palette in the abstract. The reference passes any abstract colour-pair check and still renders white text on a white card.

---

## 1. Type

### 1.1 Families, with fallbacks that actually work

| Role | Stack | Why |
|---|---|---|
| Display | `"Zilla Slab", Rockwell, "Roboto Slab", Georgia, "Times New Roman", serif` | A slab reads as load-bearing and workmanlike-premium, which is the trade. Every fallback is a serif, so a font failure degrades the weight of the voice instead of deleting it - the reference's serif falls back to Arial and its entire identity signal silently vanishes. |
| Body | `"Source Sans 3", "Source Sans Pro", "Segoe UI", system-ui, -apple-system, "Helvetica Neue", Arial, sans-serif` | Humanist, unfashionable, and legible at 16px for an audience that skews older; the fallbacks are all humanist sans, so the pairing survives the same way. |

**Four weights in the whole system**: display 500 and 600, body 400 and 600. The reference ships five weights of one sans and uses 300 exactly once.

**No italic anywhere in display type.** The reference's signature is one serif-italic word inside a sans heading. It is its strongest identity signal and its most borrowed-looking one, and copying it puts a moving company in a design studio's clothes. Emphasis here is carried by the contrast ramp (§1.5) and, once per page at most, by the display face itself.

### 1.2 Two ratios with a gap - the one thing taken wholesale

| Zone | Steps (px) | Ratio | Reason |
|---|---|---|---|
| Text | 12 · 14 · 16 · 18 · 20 | **1.136** (12 × 1.136⁴ = 20.0) | Measured at ≈1.13 on the reference. A tight ratio in the reading sizes makes labels, body and lead read as one voice. |
| *gap* | 20 → 26 | 1.30 | Nothing lands here, on purpose. |
| Display | 26 · 35 · 47 · 64 · 86 · 116 | **1.35** (26 × 1.35⁵ = 116.6) | Measured at ≈1.38 on the reference. A wide ratio above the gap makes every heading rank unmistakable. |

A single 1.25 scale across the whole range gives mushy body text and timid headings. The gap is what makes the page read as considered.

### 1.3 Leading is a function of size, in five bands

| Band | Leading | Whole-pixel result |
|---|---|---|
| ≤ 14px, micro | 1.80 | 12→22, 14→25 |
| 16-20px, body and lead | 1.60 | 16→26, 18→29, 20→32 |
| 26px, sub-head | 1.40 | 26→36 |
| 35-47px, display | 1.24 | 35→43, 47→58 |
| 64px+ | 1.15 / 1.05 | 64→74, 86→90, 116→122 |

Size, leading, tracking and weight are bound together in role classes (`.type-body`, `.type-display-2`, …), so the wrong combination is not on offer. Two independent sources reach the same conclusion from opposite ends: never pick a size whose line height will not land on a whole number, and encode the correct combination in the token rather than listing the parts separately.

### 1.4 Tracking - exactly two non-zero values, both in `em`

- `-0.015em` on display roles from 47px up; `-0.02em` on the two largest.
- `+0.04em` on the single uppercase micro role.
- Everything else is `normal`.

The reference applies a flat `-0.8px`, which is `-0.0067em` at 120px and `-0.02em` at 40px: three times tighter on a phone than on a desktop for the same headline. The principle transfers; the unit is a bug.

### 1.5 Emphasis by contrast, as one reusable role

Same size, same weight, same family - only the contrast moves, mid-sentence. `.emph` lifts a phrase from the secondary tone to the primary tone. It reads as a person speaking with emphasis rather than a page shouting. The reference implements this pattern as nineteen individually numbered one-off spans; the pattern is right, the plumbing is not.

**A size ramp alone cannot express this.** The palette therefore ships a text-contrast ramp per ground (§2.3), referenced together with the size ramp.

### 1.6 Responsive behaviour: display collapses, reading type does not

| Role | Phone | Desktop | Ratio |
|---|---|---|---|
| Statement (≤ once per page) | 47 | 116 | 0.41 |
| Display 1, hero H1 | 35 | 86 | 0.41 |
| Display 2, section H2 | 26 | 64 | 0.41 |
| Display 3, card title | 26 | 47 | 0.55 |
| Heading 4 | 20 | 26 | 0.77 |
| Lead | 18 | 20 | 0.90 |
| Body | 16 | 16 | **1.00** |
| Micro | 12 | 12 | **1.00** |

Measured on the reference: display collapses by 2.5-3× while reading type moves 0-14%. Correct, and especially correct here, because much of this audience arrives on a phone. Body never drops below 16px.

**The signature role.** `.type-phone` sets the number in the display slab with tabular figures. It is the only place the display family appears outside a heading, and it exists because the captain confirmed the phone as a primary contact route: for this business the number is not a nav link, it is the conversion.

---

## 2. Colour

### 2.1 The principle

**Bochum has no second hue.** Ground, ink and accent are values of one warm family. The accent is identified by depth and saturation, not by a colour change. This is a single, ownable position, and it is the cheapest way to guarantee the accent never has to compete with a second brand colour for the visitor's attention.

**Colour marks the next step and nothing else.** Target accent coverage: **under 1% of total page area**, concentrated on the one screen that asks for the click, matching the 0.92% measured two independent ways on the reference. The accent appears as a painted fill in exactly three places on the homepage: the header quote action, the mid-page CTA band's button, and the closing CTA band's button. Everywhere else the page is warm monochrome.

### 2.2 Grounds - exactly three families, six values

| Token | Hex | Role | Share of page |
|---|---|---|---|
| `--color-ground-page` | `#E4E0D7` | The passe-partout every panel floats on | frame only |
| `--color-ground-panel` | `#F6F4EF` | The main reading surface | ~48% |
| `--color-ground-panel-alt` | `#EDE9E1` | Alternating light panel | ~14% |
| `--color-ground-accent` | `#F7EFDF` | The one band that asks for the click | ~5% |
| `--color-ground-ink` | `#1C1A17` | Hero panel and footer - the frame, not the body | ~28% |
| `--color-ground-ink-alt` | `#2A2723` | Cards sitting on ink | ~5% |

Light ≈ 67%, ink ≈ 33%. The reference runs 54% dark because it is selling engineering; a company entering someone's home is selling care, so the split is inverted while the discipline of three grounds and the pacing are kept. **Never more than about three screens on one ground before it switches.**

The lightest surface in the system is `#F6F4EF`, not `#FFFFFF`. That is deliberate and it is load-bearing for §7.

### 2.3 Text ramps - named with their ground, always

There is no `--color-text-tertiary`. Naming a colour without its ground is exactly what produced the reference's five contrast failures: one dull grey at 7.01:1 on black, 3.00:1 on white and 2.72:1 on its light section ground.

### 2.4 Contrast - every permitted pair, every ratio

Computed WCAG 2.2 relative luminance. **AA-norm 4.5:1** for text under 24px (or under 18.66px bold); **3.0:1** for non-text UI boundaries, focus indicators and disabled text. Reproduce with `node check-contrast.mjs`.

**Text and UI on light grounds**

| Role | Hex | on page `#E4E0D7` | on panel `#F6F4EF` | on panel-alt `#EDE9E1` | on accent band `#F7EFDF` | Min |
|---|---|---|---|---|---|---|
| Primary text | `#1C1A17` | 13.18 | 15.80 | 14.34 | 15.19 | 4.5 |
| Secondary text | `#4A443B` | 7.31 | 8.76 | 7.95 | 8.42 | 4.5 |
| Tertiary text | `#615A4F` | 5.17 | 6.20 | 5.62 | 5.96 | 4.5 |
| Text link | `#7E5010` | 5.24 | 6.28 | 5.70 | 6.04 | 4.5 |
| Error | `#9C2B1E` | 5.74 | 6.88 | 6.24 | 6.61 | 4.5 |
| Success | `#2C6440` | 5.31 | 6.36 | 5.77 | 6.11 | 4.5 |
| Unconfirmed placeholder | `#5C3B8C` | 6.48 | 7.77 | 7.05 | 7.47 | 4.5 |
| Control boundary / disabled | `#7E776B` | 3.36 | 4.03 | 3.66 | 3.88 | 3.0 |
| Focus ring | `#1C1A17` | 13.18 | 15.80 | 14.34 | 15.19 | 3.0 |
| Accent fill | `#8F5D18` | 4.25 | 5.10 | 4.63 | 4.90 | 3.0 |
| Accent fill, hover | `#7E5010` | 5.24 | 6.28 | 5.70 | 6.04 | 3.0 |
| Accent fill, press | `#6E460E` | 6.26 | 7.51 | 6.81 | 7.22 | 3.0 |

**Text and UI on ink grounds**

| Role | Hex | on ink `#1C1A17` | on ink-alt `#2A2723` | Min |
|---|---|---|---|---|
| Primary text | `#F7F4EE` | 15.82 | 13.54 | 4.5 |
| Secondary text | `#D3CCC0` | 10.89 | 9.32 | 4.5 |
| Tertiary text | `#ADA396` | 6.99 | 5.98 | 4.5 |
| Error | `#F0A79C` | 8.86 | 7.58 | 4.5 |
| Success | `#9FD3AF` | 10.26 | 8.78 | 4.5 |
| Unconfirmed placeholder | `#C9B7E4` | 9.41 | 8.05 | 4.5 |
| Control boundary / disabled | `#847D71` | 4.26 | 3.65 | 3.0 |
| Focus ring | `#F7F4EE` | 15.82 | 13.54 | 3.0 |
| Inverted action fill | `#F7F4EE` | 15.82 | 13.54 | 3.0 |
| Inverted action fill, hover | `#E6E1D7` | 13.32 | 11.41 | 3.0 |
| Inverted action fill, press | `#D3CCC0` | 10.89 | 9.32 | 3.0 |

**Labels on filled actions**

| Pair | Ratio | Min |
|---|---|---|
| `#F7F4EE` on accent `#8F5D18` | 5.11 | 4.5 |
| `#F7F4EE` on accent hover `#7E5010` | 6.29 | 4.5 |
| `#F7F4EE` on accent press `#6E460E` | 7.52 | 4.5 |
| `#1C1A17` on inverted `#F7F4EE` | 15.82 | 4.5 |
| `#1C1A17` on inverted hover `#E6E1D7` | 13.32 | 4.5 |
| `#1C1A17` on inverted press `#D3CCC0` | 10.89 | 4.5 |
| Focus ring `#F7F4EE` on accent / hover / press | 5.11 / 6.29 / 7.52 | 3.0 |

**85 permitted pairs. 85 pass. Zero failures.**

**Three pairs are banned, and the ban is asserted rather than assumed** - the checker verifies each stays *below* its threshold, so a stale ban shows up as a failure:

| Banned pair | Ratio | Why |
|---|---|---|
| Accent fill on ink-alt | 2.65 | Bronze is not identifiable as a control on an ink ground. The primary action **inverts** on ink: paper fill, ink label. |
| Accent as body text on the page ground | 4.25 | Short of 4.5. The accent is a fill; text links use the one-step-deeper `#7E5010`. |
| Secondary text on the accent fill | 1.72 | Only the on-accent label colour may sit on the accent fill. |

### 2.5 Accent derivation

One value, two states derived on a single lightness axis: `#8F5D18` → hover `#7E5010` → press `#6E460E`. **If a hover bronze ever gets its own unrelated hex, the system has already failed** - the reference has seven limes pretending to be one, including a token named `--darkgreen` that holds the lightest value in the family.

Note the direction: hover goes *darker*, and it still passes because the label is paper. A lighter hover would have broken the label. The axis was chosen so that every state on it is legal.

### 2.6 What is checked, and what is not

`check-contrast.mjs` checks the declared pairs. It does **not** know which ancestor a text node is actually painted on in a built page, it does not evaluate text over imagery, and it does not verify that a bound token is used on a property its scope allows. Those three are the builder's checks, and they are exactly where the abstract audit is blind:

1. **Resolve every text node against its nearest painted ancestor** in the built HTML, not against an assumed page background.
2. **Content bounds must be a subset of frame bounds** for every component - a fixed-height master holding taller content crops its own value silently.
3. **A variable bound to a text fill must be a text-fill-scoped variable.**

A green result that does not state its scope is actively misleading, and the better the rest of the system looks, the more weight those zeros wrongly carry.

---

## 3. Space

### 3.1 Base 4px, thirteen steps, obeyed

`4 · 8 · 12 · 16 · 20 · 24 · 32 · 40 · 48 · 64 · 80 · 96 · 160`

The token name is the multiple: `--space-6` is 24px. That makes the base self-enforcing - a value off the ladder has no name, so it cannot be typed. The reference measures 81.2% compliance with a 4px base and 48.9% with 8px, which is another way of saying its 8px system does not exist. **Declare 4 and hit it.**

### 3.2 Section rhythm - derived, not hand-set

| Token | Desktop | Phone | Use |
|---|---|---|---|
| `--section-pad-tight` | 64 | 32 | Dense sections: trust strip, coverage |
| `--section-pad` | 96 | 48 | Every ordinary section |
| `--section-pad-pause` | 160 | 80 | **At most once per page** |

**One mobile factor of 0.5, applied to all three.** The reference's vertical padding runs 48/64/104/120/210 with no derivation, and its desktop-to-mobile reduction ranges from 0.17× to 1.00× per section. It looks systematic and is not; this is the clearest place to do better cheaply.

The single 160px pause is the deliberate breath. It works only because everything around it is at 96 - the reference proves this with its one 210px section against a page of 104s.

### 3.3 The framed page

Content sits in panels inset from the viewport edge on the felt ground, with a generous corner radius. The site reads as a set of objects rather than as full-bleed content. It costs `2 × --frame-inset` of horizontal space and buys the entire premium-object impression.

---

## 4. Layout

### 4.1 Three breakpoints, named after the design

`480px` phone-large · `768px` tablet · `1120px` desktop. Three, not the platform's stock six. A leftover default is a value nobody chose; defaults are replaced here, not extended.

### 4.2 Container widths per breakpoint

| Breakpoint | Frame inset | Gutter inside panel | Content max-width |
|---|---|---|---|
| < 480 (phone) | 8 | 16 | full width |
| 480-767 (phone-large) | 12 | 20 | full width |
| 768-1119 (tablet) | 16 | 24 | 680 |
| ≥ 1120 (desktop) | 20 | 32 | **1180** |

**One content width and one prose measure (`62ch`), and nothing else.** The reference's 1400px outer frame is disciplined; its seven different inner max-widths on a single page are not a system, they are seven per-section decisions.

---

## 5. Shape, borders and depth

### 5.1 Radius scales with the size of the box

| Token | Value | Applied to |
|---|---|---|
| `--radius-xs` | 4 | Tags, swatches |
| `--radius-sm` | 8 | Text inputs, small tiles |
| `--radius-md` | 14 | Cards, proof figures |
| `--radius-lg` | 22 | Large cards, decorative media frames |
| `--radius-xl` | 28 | Section panels, the page frame |
| `--radius-pill` | 999 | Anything you press |

Two families, cleanly separated: **rectangles get a radius proportional to their size; controls get a pill.** A visitor learns what is clickable without reading it. Twelve distinct radii exist in the reference's CSS, four or five more than its ladder needs.

A text input is a rectangle at `--radius-sm`, not a pill - it is a container for content, not an object to press. That is a stated exception, not an accident.

### 5.2 Borders

**One border in the system: `--border-control`, 1.5px.** It exists for exactly one reason: to give a control a boundary where a ground change cannot. Form fields use it. Nothing else does.

1.5px rather than 1px is deliberate. A 1px line reads as a ruled hairline, which is the neighbouring Dortmund brand's structural material; 1.5px reads as the edge of an object. See §11.

### 5.3 Elevation, and the combination rule

**There are no shadow tokens.** Depth is expressed by a ground change or by a scrim, never by a shadow. The reference authors zero shadows across an entire page - the only one in the document belongs to a third-party chat widget - and separates everything by ground colour, corner radius and whitespace. It works, it is cheap, and it is a strong differentiator.

**The rule, stated so it can be checked: a surface expresses separation by exactly one of - a ground change, or a 1.5px control border. They never combine. Shadow is not available.**

The one permitted depth device beyond a ground change is `--color-scrim` (62% ink), used only behind the mobile navigation drawer. The reference's drawer has no backdrop dim and does not scroll-lock the page behind it, so the page slides around under an open menu. That is sloppy and it is not copied.

---

## 6. Motion

### 6.1 Vocabulary: four verbs, one curve family, three durations

| Verb | What it does | Properties | Duration | Easing |
|---|---|---|---|---|
| `enter` | Content arrives, once, never replayed | `opacity` 0→1, `translateY` 20px→0 | 560ms | `--ease-out` |
| `enter-stagger` | A row of siblings arrives | as `enter`, per child | 560ms, +70ms per child, **capped at 5** | `--ease-out` |
| `respond` | Interface answers a pointer, tap or key | `background-color`, `border-color`, `color`, `transform` ≤2px | 160ms | `--ease-out` |
| `pin` | A panel holds while the next arrives over it | CSS `position: sticky` | n/a | n/a |

**Deliberately not in the vocabulary**: character splitting, scrubbed timelines, overshoot / bounce / elastic easings, looping animation, auto-advance, parallax, cursor followers, page transitions, counting numbers.

**Hover physics**, carried from the reference because the metaphor is coherent: controls shrink or settle when pressed, content images grow, buttons lift 2px. Small interactive things do not grow.

**Nothing animates a layout property.** One layout-animating effect on an 11,000px page is the single biggest reason the reference feels expensive rather than cheap, and it is the most transferable thing in that report. Here the count is zero.

### 6.2 The event budget: six, and here they are

A "considered interaction" is one motion event a visitor consciously notices. Hover and focus states are free and expected everywhere; they do not count.

| # | Where | Event |
|---|---|---|
| 1 | Hero | Headline and sub-headline enter as **one** group |
| 2 | Hero | The action group enters 150ms behind it |
| 3 | Hero | `pin` - the ink hero panel holds while the next panel arrives over it. Desktop and tablet only, off below 768px |
| 4 | Services | `enter-stagger` on the service rows, once |
| 5 | Ablauf | `enter-stagger` on the four steps, once |
| 6 | Closing CTA | `enter`, once |

**Zero motion** in the trust strip, coverage, reviews, team photograph, pricing, FAQ and footer. Stillness is not an absence here: someone reading about clearing a deceased relative's home should have nothing in their peripheral vision that will not hold still, and stillness buys the most credibility exactly where trust is being asked for.

Every entrance uses `toggleActions: play none none none` semantics - it fires once on entry and never replays, not on scroll-back, not on a second pass. A reveal that replays makes a site feel like a toy; one that plays once behaves like a page that has finished loading and stays finished.

Timing is slightly slower than the reference's per-element figures and much faster to resolve, because a single block fade at 560ms with a 70ms stagger settles a four-item row in ~770ms, against ~1.4s for a character-split heading - calmer to the eye, quicker to the reader, and a fraction of the DOM. Deliberation reads as competence; briskness reads as sales.

### 6.3 Reduced motion - mandatory, and the reference's biggest miss

`prefers-reduced-motion: reduce` is honoured by **removing motion while preserving the final state**, never by shortening durations.

1. The blanket CSS rule in `tokens.css` is the **floor, not the ceiling**.
2. **Every script-driven animation must check the query itself and jump straight to its end state.** A CSS rule cannot stop a script writing transforms per frame - which is precisely how the reference still animates under forced reduced motion, on identical curves, to the tenth of a pixel.
3. Read the preference once at startup **and subscribe to changes**, so a visitor who enables it mid-visit is respected without a reload.
4. `pin` may stay: `position: sticky` is not animation.
5. **Reduced motion never removes content.**

**The test that proves it**: record one scroll-triggered reveal frame by frame in both modes. If the two curves match, it is not implemented.

### 6.4 No JavaScript - mandatory

**The page is complete and readable with scripting off. Motion is an enhancement layered on top.**

- Every element is authored in its **final, visible state**. `opacity: 0` never appears in a stylesheet waiting for a script to remove it.
- **Gate the hiding, not the revealing.** A tiny inline script in `<head>` sets `js-motion` on `<html>`; every pre-animation state is scoped to it. If the script never runs, nothing was ever hidden. One line of code, and it eliminates the entire category of blank-page failure.
- `pin` is CSS `position: sticky` - no script, and it is the proof that the best effect available is also the cheapest.
- **Every disclosure works without script.** The services list and the FAQ are native `<details>` / `<summary>`. Nothing important lives behind a JavaScript-only widget - the one section where the reference fails this test is the one a visitor most wants to read.
- Never ship a second copy of an animation library, and never ship an animation script whose targets do not exist. Both are on the reference page today.

**Nothing in this system may depend on script for content to be readable or reachable.** That is a rule, and it is checked by loading the page with scripting disabled and reading it end to end.

### 6.5 Pre-launch checks

1. Frame-by-frame recording of one reveal, with and without forced reduced motion - the curves **must differ**.
2. Load with scripting disabled and read end to end - every section complete.
3. Tab through the whole page - every interaction reachable and operable.
4. CLS across a full scroll at 1440 and 390 - **target under 0.02**. The reference achieves 0.004 / 0.009; that is the bar.
5. Frame durations during a scripted full-page scroll at 4-6× CPU throttle - **zero frames over 32ms**.

---

## 7. Consent, analytics and third parties

A `.de` site needs a position on this, and inheriting the reference's absence by omission is not a position. The reference has no consent element of any kind in its DOM.

**v1 ships with no analytics and no third-party script.** Nothing is loaded that sets a cookie or transmits a visitor identifier. Under that configuration no consent banner is required, and none is shown.

**The consent layer is designed now and reserved, so that adding analytics later cannot become a design emergency:**

- **Where it lives**: a bottom-anchored panel inside the page frame, on `--color-ground-panel`, at `--radius-xl`, above the scrim. It is **not** a full-screen blocker.
- **What it may never cover**: the header. The phone number and the WhatsApp action must remain visible and tappable while the consent panel is open. A consent layer that hides the phone number costs more than the analytics is worth.
- **Actions**: "Alle akzeptieren" and "Nur notwendige" are given **equal visual weight** - same size, same shape, one accent fill and one outline. No dark pattern, no pre-ticked boxes, no cookie wall.
- **Order of operations**: no analytics, pixel, map embed, font CDN or chat widget may execute before an affirmative choice. This includes the first page view.
- **WhatsApp**: implemented as a plain `https://wa.me/…` link. It sets nothing and loads nothing, so it needs no consent. A WhatsApp *widget script* would need consent and is therefore not used.
- **Fonts** are self-hosted for the same reason.

Consent is a **rule**, so it is testable: with the consent panel untouched, a network capture on first load must contain zero third-party requests.

---

## 8. Imagery: decoration and proof are different objects

The system makes this structural so a later builder cannot blur them. They are not styling variants of one component; they are two contracts with different required parts, and `tokens.css` makes a mix-up visible.

| | **Proof** (`.img-proof`) | **Decoration** (`.img-decor`) |
|---|---|---|
| What it is | A photograph offered as evidence: our crew, our van, this job | Atmosphere |
| Carries a claim | Yes | **No** |
| `<figcaption>` | **Required** - names what, where and when | **Forbidden**; the CSS refuses to render one |
| `data-proof-source` | **Required** - records where the asset came from | n/a |
| `alt` | Describes the actual thing shown | `alt=""`, hidden from assistive technology |
| Stock permitted | **Never** | Yes, and only here |
| Radius / ratio | `--radius-md`, 4:3 | `--radius-lg`, 16:9 |
| May sit next to a factual claim | Yes | **No** |

**A proof figure missing its caption or its source is not proof.** It renders with a dashed unconfirmed outline on the unconfirmed ground instead of quietly passing as evidence. That is the enforcement: the failure is visible in a screenshot, in a review, and in a Figma frame.

This matters more here than anywhere else on the page. The team photograph is the single most valuable section to carry over from the reference, because this customer is deciding whether to let five strangers into their home. A real photograph of the people who will arrive does work no stock image can. Bought stock of a generic removal van will read as fake next to real reviews, and will undercut both.

---

## 9. Unconfirmed content is typed, never invented

Confirmed by the captain and therefore real content:

- **Phone: +49 15567 692971.** Primary. In the header on every screen.
- **WhatsApp**, same number. Primary. In the header on every screen.
- Domain `umzugservice-bochum.de`; city Bochum.
- Services: Umzug (privat und geschäftlich), Entrümpelung und Räumung, Haushaltsauflösung.

**Everything else is a typed placeholder.** Prices, insurance sums, response times, years in business, crew size, counts of any kind, testimonials, ratings, and every photograph of the team or of a completed job.

```html
<span data-unconfirmed="price">Preis - noch nicht bestätigt</span>
<span data-unconfirmed="count">Anzahl - noch nicht bestätigt</span>
<div  data-unconfirmed="photo" aria-label="Teamfoto folgt"></div>
```

Types: `price · sum · duration · count · years · rating · quote · photo`.

They render in a violet that is **deliberately outside the brand**, so an unfilled slot cannot be mistaken for finished design. `data-unconfirmed="photo"` reserves the real aspect ratio, so dropping in the real photograph shifts nothing.

**Release rule, testable: any element carrying `data-unconfirmed` in a production build fails the release check.**

Two consequences for components. A testimonial component must **look correct with two reviews**, not merely stop looking broken at six - if there are not yet enough reviews to justify a carousel, the component that works with two is the right component. And no number animates: animating a figure draws attention to it, which is the last thing to do next to one that cannot yet be substantiated.

---

## 10. Component inventory

Interactive components ship all eight states: **default · hover · focus-visible · active · disabled · loading · error · success**. Where a state does not apply, it is marked n/a rather than skipped.

### 10.1 Header

The most constrained component in the system, because the captain's contact decision runs through it.

- **Always visible. Never hidden on scroll, never condensed.** See §12.
- Compact by design: 64px desktop, 56px phone. The screen space the reference buys by hiding is bought here by being permanently smaller.
- Opaque `--color-ground-panel`, `--radius-xl`, inset by `--frame-inset`. No border, no shadow, no backdrop blur - separation is the opaque ground, as in the reference.
- Contents, desktop: wordmark · four flat links · **phone (`.type-phone`, `tel:`)** · **WhatsApp (`wa.me`)** · quote action (accent fill).
- Contents, phone: wordmark · **phone** · **WhatsApp** · hamburger. Both contact actions stay in the bar at every width; only the nav links collapse.
- **No floating WhatsApp bubble anywhere on the site.** The reference's persistent bubble exists to compensate for a header that hides; with the header present that overlay is redundant, and on the reference at 390px it sits on top of body copy with no reserved gutter.

| State | Treatment |
|---|---|
| Default | As above |
| Hover (links) | `respond`, colour to primary |
| Focus-visible | 2px ink ring, 2px offset, instant |
| Active | Settle 1px |
| Disabled | n/a |
| Loading / Error / Success | n/a |
| Menu open (phone) | Drawer below the bar, scrim behind, page scroll locked, focus trapped, `Esc` closes, focus returns to the toggle |

Touch targets: **44 × 44px minimum**, 8px minimum between them. The phone and WhatsApp actions are labelled with text or an accessible name - never a bare unlabelled glyph.

### 10.2 Buttons

Three variants. Two ground-dependent forms of the primary, because the accent is not legible on ink (§2.4).

| Variant | On light | On ink |
|---|---|---|
| Primary | Accent fill `#8F5D18`, paper label, pill | **Inverts**: paper fill, ink label, pill |
| Secondary | 1.5px ink boundary, transparent fill, ink label, pill | 1.5px paper boundary, paper label, pill |
| Quiet | Ink label with a 1px underline, no box | Paper label with a 1px underline |

| State | Primary on light | Notes |
|---|---|---|
| Default | `#8F5D18` fill, `#F7F4EE` label (5.11) | Min height 48px, min width 44px |
| Hover | `#7E5010` (6.29), lift `-2px` | 160ms `--ease-out` |
| Focus-visible | Paper ring 2px, 2px offset (5.11) | **Never animated in** |
| Active | `#6E460E` (7.52), settle `+1px` | |
| Disabled | `#7E776B` label on panel (3.36), `cursor: not-allowed` | Held to 3:1 though WCAG exempts it |
| Loading | Label replaced by a static "Wird gesendet…", `aria-busy="true"`, width held so nothing reflows | No spinner animation under reduced motion |
| Error | Label reverts, error message rendered **at the field**, focus moved to it | |
| Success | Label becomes the past tense of the action ("Angefragt"), announced via a polite live region | Silent success; no celebratory toast |

**No scale-and-pop entrance on any call to action.** Overshoot easings read as playful; a "Kostenloses Angebot anfordern" button is a promise about someone's home and should appear with the same calm as everything else.

### 10.3 Cards

One component, reused. `--color-ground-panel` or `--color-ground-ink-alt` fill, `--radius-md`, `--space-8` padding, **no border, no shadow**. The reference's card is one idea reused seven ways and it is the strongest part of that system.

| State | Treatment |
|---|---|
| Default | Ground fill, radius, padding |
| Hover (only if the whole card is a link) | Ground steps one value, media inside grows to `--grow` 1.03 |
| Focus-visible | Ring on the card, from the link inside it |
| Active | Settle 1px |
| Disabled / Loading | Ground at panel-alt, content replaced by reserved blocks at the real dimensions |
| Error / Success | n/a |
| Empty | Renders its unconfirmed state, never a stock photo |

A non-interactive card has **no hover state at all**. The reference flips a testimonial card from near-black to white on hover, which is a large state change on an element that does nothing.

### 10.4 Form fields

This is where the business earns money, and it is where the reference is at its worst: it reserves the focus ring's space with a transparent border and then sets the focus border width to zero, so **keyboard focus on its contact form is completely invisible**.

- Ground `--color-ground-panel`, 1.5px `--color-line-on-light` boundary (3.36-4.03), `--radius-sm`, min height 48px.
- **Visible label above the field, always.** Never a placeholder standing in for a label.
- Helper text below, `--color-text-tertiary-on-light`, smaller **and** lower contrast than the label - a text role is never separated by a single property.
- Correct technique carried from the reference: **reserve the focus ring's space with a transparent boundary so focus cannot shift layout.** Then actually put a visible ring in it.

| State | Treatment |
|---|---|
| Default | 1.5px `#7E776B` boundary |
| Hover | Boundary to `#615A4F`, 160ms |
| Focus-visible | **2px `#1C1A17` ring, 2px offset, instant, on top of the reserved space** |
| Active | As focus |
| Disabled | `#7E776B` label and boundary (3.36), panel-alt fill, `cursor: not-allowed` |
| Loading | Field locked, `aria-busy` on the form, layout held |
| Error | 1.5px `#9C2B1E` boundary, message **below the field** (5.74), `aria-describedby`, `aria-invalid="true"`, plus an error summary at the top of the form that links to each field |
| Success | 1.5px `#2C6440`, message below (5.31) |

Quote form fields: Name, Telefon, E-Mail, Umzug von, Umzug nach, Wunschtermin, Art der Leistung, Nachricht. **No budget bracket and no eight-checkbox need-picker.** The reference's ten-field qualification form behind a Turnstile is a filter built for a business model that does not apply here; asking a family relocating within Bochum to select a budget bracket before any human contact loses them to whoever put a phone number in the header.

### 10.5 Accordion

Native `<details>` / `<summary>`. **Works on tap, on keyboard, and with scripting disabled.**

| State | Treatment |
|---|---|
| Collapsed | Summary row, `--space-6` padding, chevron rotated 0° |
| Expanded | Chevron 180°, body at `--measure` |
| Hover | Row ground steps one value, 160ms |
| Focus-visible | 2px ink ring on the summary, instant |
| Active | Settle 1px |
| Disabled / Loading / Error / Success | n/a |
| Reduced motion | Opens instantly, no height transition |
| No JavaScript | Fully operable |

**No auto-advance, no timer, no mouse-only listener.** The reference's process accordion advances itself every 30 seconds and listens only for `mouseenter`: a keyboard user, a screen-reader user and a touch user can never open cards 2, 3 or 4. It is also the only section of that page that breaks without JavaScript. Three separate problems in one component.

Content with steps, prices or inclusions is **fully visible, not disclosed**. A comparison shopper reads the process twice, slowly; content that moves on without being asked says the page's agenda outranks the reader's.

### 10.6 Navigation

- Desktop: four or five **flat** links. No dropdowns. A local service with one city and one service family does not need the reference's five-dropdown, 26-destination IA - copying that depth means inventing pages to fill it, each of which then sits empty and dates the site.
- Phone: drawer below the header bar, with the scrim, scroll lock, focus trap and `Esc` the reference's drawer lacks.
- **Current page** is marked by weight and an accent underline, plus `aria-current="page"` - never by colour alone.
- Every dropdown on the reference terminates in a contact action, which is its single best conversion idea and costs no page space. The flat equivalent here: the drawer ends with the phone number, WhatsApp and the quote action repeated full width.

### 10.7 Footer

`--color-ground-ink`. Contact block (phone, WhatsApp, e-mail, address), Einsatzgebiet, opening hours, **Impressum** and **Datenschutzerklärung** - both legally required in Germany. Around ten links, not the reference's 41. At 390px the reference's footer is 25% of the entire page.

Column headings are distinguished from their links by weight and colour, never by size alone.

### 10.8 Trust strip item

Micro label plus value, on `--color-ground-panel-alt`, `--radius-sm`. Every value is currently a typed placeholder (§9). If a value cannot be substantiated, **the item is removed rather than softened** - a vague trust marker is worse than none.

### 10.9 Consent panel

Specified in §7. States: hidden (default in v1), shown, focus-visible on each action, dismissed. Never covers the header.

---

## 11. How this differs from Umzugservice Dortmund

Dortmund runs a white protocol-paper direction: hairline rules as the structural material, label-and-value rows, an Übergabeprotokoll artefact. Put the two side by side at the same width and a stranger must not guess they share an owner. Six axes are deliberately opposed.

| Axis | Dortmund | Bochum |
|---|---|---|
| **Structural material** | Hairline rules | **Ground change.** Zero rules in the system; the only border is a 1.5px control boundary on a form field, and 1.5px is chosen precisely so it reads as an object edge rather than a ruled line |
| **Neutral temperature** | Cool white paper | **Warm felt.** Every neutral carries a warm cast; the lightest surface in the system is `#F6F4EF`, and `#FFFFFF` appears nowhere |
| **Colour family** | Protocol-paper monochrome | **One warm bronze family.** Not a second blue, not a second anything - the accent is the same hue as the ground, three-and-a-half stops deeper |
| **Shape language** | Flat, ruled, document-like | **Rounded, unruled, shadowless.** Five-step radius ladder topping at 28px, controls fully round |
| **Typefaces** | Protocol/document register | **Slab serif display + humanist sans.** No shared family, no shared classification |
| **Hero construction** | Document artefact | **Split panel**: a solid ink panel carrying the headline and both contact actions, adjacent to a photograph. No reading text sits on imagery at any point |

The organising difference underneath all six: Dortmund's system is **a record** - it proves what was done. Bochum's is **a room** - warm, quiet, no sharp edges, and one clearly marked door.

---

## 12. The header conflict, and how it was resolved

The motion report ranks a **hide-on-scroll header** among the three effects worth carrying, and its reasoning is sound in the abstract: it responds to intent rather than to position, and on a long page it does more for the sense of quality than any reveal.

**It is wrong here, and it is rejected.**

The captain confirmed that phone and WhatsApp are both primary and both in the header on every screen. A header that hides is a header that takes both primary contact routes off the screen for the entire downward scroll. On the reference this is already the page's largest structural weakness: between roughly 1 and 5.8 viewport heights, and again between 5.8 and 11.1, the only visible way to act is a 60px unlabelled circle. Copying that behaviour onto a business whose header carries the phone number converts a defensible choice into an indefensible one - the structure report reaches the same conclusion independently.

**Resolution: the header is sticky and always visible. It never hides and it never condenses on scroll.**

Condensing was considered and rejected too: animating the header's height is a layout animation on scroll, it risks CLS, and the system's count of layout-animating effects is zero. The screen space the reference reclaims by hiding is instead bought permanently, by a header that is 64px on desktop and 56px on a phone from the first pixel.

**The other two carried effects are kept**: the once-only content entrance, as a block fade-up rather than per character, and the sticky `pin`, which costs no JavaScript, survives scripting being disabled, and is switched off below the tablet breakpoint.

---

## 13. Homepage section order

Taken from the structure report's recommended twelve, adjusted where the contact decision changes it. "Content exists" states whether the section can be filled truthfully today.

| # | Section | What it is for | Content exists? |
|---|---|---|---|
| 1 | **Header** | Wordmark, four flat links, phone, WhatsApp, quote action. Sticky, never hidden | **Yes** - number confirmed |
| 2 | **Hero** (split: ink panel + photograph) | Says what, where, and offers all three actions inside the first screen | Copy yes; **photograph is a typed placeholder** |
| 3 | **Trust strip** | Answers the first question - rating, years, insurance, membership - in one line under the fold | **No** - every value unconfirmed |
| 4 | **Leistungen** (accordion) | Full service depth in two-thirds of a screen; the one reference pattern that fits a service business perfectly | **Yes** - the three service families are confirmed |
| 5 | **First repeat CTA** | Asks at the moment a visitor confirms you do their job, not 4.9 screens later | **Yes** |
| 6 | **Ablauf**, four steps | Answers the real objection - cost certainty and disruption - not craft | Structure yes; **"Festpreis" is a business promise and is unconfirmed** |
| 7 | **Einsatzgebiet** | "Do you come to my street" has to be answered before anything else matters | Bochum yes; **radius and district list unconfirmed** |
| 8 | **Bewertungen + Teamfoto**, adjacent | They answer the same fear - strangers in my home - and are stronger together | **No** - both are typed placeholders |
| 9 | **Wie der Preis entsteht** | Not a price list; a mover that hides how price is formed loses to one that explains it | **No** - unconfirmed |
| 10 | **FAQ** | Fills the slot the reference gives to awards and capability logos, with content a mover can genuinely produce | **Yes** - writable without unconfirmed facts |
| 11 | **Closing CTA band** | The reference's strongest single conversion object; kept, with all three routes | **Yes** |
| 12 | **Footer** | Contact, coverage, Impressum, Datenschutz | Legal pages yes; **address unconfirmed** |

**Adjustments made because the contact decision changed the header:**

- The persistent WhatsApp overlay is **removed**. Its only job on the reference is to compensate for a header that hides; with phone and WhatsApp permanently in the bar it is redundant, and on the reference at 390px it overlaps body copy.
- The structure report's target of a call to action every ~2 screens is now met partly by the header itself, which never leaves. The number of mid-page CTA bands therefore drops from four to **two** (sections 5 and 11), which keeps the page from nagging.
- The hero carries **three** routes rather than two: phone, WhatsApp, and the quote request. The reference's hero carries zero and survives on brand; this business has to convert on the first screen.

**Cut from the reference, with reasons**, so nobody re-adds them later: the three-screen sticky case-study stack (a mover's finished work is an ordinary empty room; three screens of it will be stock vans and boxes and every visitor will know), the tool-logo capability grid, the awards section, the Products dropdown, the five-dropdown 26-destination IA, and the ten-field budget-bracket qualification form.

**Targets**: 6-8 screens on desktop; an action within reach on every screen; at least half of all body sections carrying one. The reference runs 12.5 screens with 2 of 10 body sections carrying a link, which makes it a brand page. This has to be a working one.

---

## 14. Constraints, counted

One accent value · three derived states on one axis · six grounds · two text ramps, one per ground family · two type families · four font weights · two type ratios with one gap · thirteen spacing steps on a 4px base · three section-padding tokens and one mobile factor · one content width and one prose measure · three breakpoints · five radii plus a pill · one border width · **zero shadows** · four motion verbs · one easing family · three durations · **six motion events**.

If any of those numbers grows, something has gone wrong, and the number is where the argument should start.
