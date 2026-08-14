# Umzugservice Bochum - Figma prototype v1, build notes

Built from `data/bochum-design-system-v1/` (DESIGN-SYSTEM.md + tokens.css) as an accepted system, not a new design.

**Figma file:** https://www.figma.com/design/crnaqj5TXWHciIhEatpCan/Umzugservice-Bochum---Design-System-und-Prototyp-v1

File key `crnaqj5TXWHciIhEatpCan`. Private to the authenticated account's own team ("Yelen L.'s team"), created in drafts. Sharing settings untouched, nothing published, no pre-existing file modified.

**One piece of cleanup for the captain:** a first, empty file was created before this one and is now abandoned - `EIP7Y87Q37RvCsfmG2CF4i`, named `Umzugservice Bochum - Design System &amp; Prototype v1`. Figma's file-creation API HTML-escaped the ampersand and the Plugin API refuses to rename a document, so the file was recreated with an ampersand-free name. The abandoned one is empty and safe to delete; it could not be deleted from here.

---

## 1. Variables (foundation)

123 variables in 5 collections, plus 11 text styles and **0 effect styles** - the system has no shadow tokens, and none were invented.

| Collection | Modes | Count | Notes |
|---|---|---|---|
| Primitives | Value | 25 | Raw filz / paper / bronze / status / unconfirmed ramps. Scopes set to `[]` so they never appear in a picker. |
| Colour | Value | 39 | Semantic, every one aliased to a primitive. Named with its ground, as the system requires - there is no `text/tertiary`. |
| Space | Desktop / Phone | 21 | The 13-step 4px ladder (identical in both modes) plus the derived section rhythm, frame inset, gutter and layout widths. |
| Shape | Value | 9 | Five radii plus the pill, one border width, focus width and offset. |
| Type | Desktop / Phone | 29 | Two families, four weights, three tracking tokens, and per-role size + leading. |

Every variable carries an explicit scope and a WEB code syntax in `var(--token)` form matching `tokens.css`. Every semantic colour is an alias; no raw hex was duplicated into the semantic tier.

**The two modes are load-bearing.** `Type` and `Space` carry Desktop and Phone modes, so the ten text styles resolve per breakpoint from one definition: the mobile homepage frame is set to Phone mode and the whole display ramp collapses 2.5-3x while body and micro stay put, exactly as §1.6 specifies. This is how the CSS `clamp()` endpoints are expressed in a tool with no clamp.

## 2. Component library

10 component sets, 100 variants, every one bound to variables. No hard-coded colour or spacing survives in any component (verified - see §5).

| Component | Variants | Coverage |
|---|---|---|
| Button / On light | 24 | Primary · Secondary · Quiet × all 8 states |
| Button / On ink | 24 | Same, with the primary action inverted to paper |
| Card | 12 | Panel + Ink grounds × Default, Hover, Focus-visible, Active, Loading, Empty |
| Form field | 8 | All 8 states |
| Accordion | 5 | Collapsed, Expanded, Hover, Focus-visible, Active |
| Header | 9 | Desktop × 4 states, Phone × 4 states + Menu open |
| Navigation | 8 | Desktop links + phone Drawer × 4 states |
| Footer | 2 | Desktop, Phone |
| Trust strip item | 4 | Bewertung, Jahre, Versicherung, Mitgliedschaft |
| Consent panel | 4 | Hidden (v1 default), Shown, Focus-visible, Dismissed |

Where the inventory marks a state n/a (Disabled/Loading/Error/Success on the header, accordion and navigation; Error/Success on cards) it is recorded in the component description rather than shipped as an empty variant.

Buttons are **split into two sets by ground** rather than one 48-variant set. That is the system's own structural split - §2.4 forbids the bronze fill on ink, so the primary action is a genuinely different object there - and it keeps each set under the variant-explosion cap.

Focus rings are real geometry, not a note: a 2px ring at 2px offset on an absolutely-positioned child with stretch constraints, so it survives resizing. The system is emphatic that the reference's invisible keyboard focus is its worst failure, so this was built rather than described.

## 3. Homepages

Both follow §13's twelve sections in order, on the framed page - panels floating on the felt ground, inset by `frame-inset`, at `radius-xl`.

- **Desktop 1440**: 6,430px tall = **7.1 screens** (target 6-8). Content max-width 1180.
- **Mobile 390**: 7,469px tall = 8.8 screens at 844. **Zero horizontal overflow** at any nesting level.

Ground pacing alternates and never runs more than about three screens on one ground: panel → ink hero → panel-alt → panel → accent → panel → panel-alt → panel → panel-alt → panel → accent → ink footer.

The single `section-pad-pause` (160/80) is spent once, on the closing CTA band.

The six motion events are placed and labelled in the layer names (`[data-enter]`, `[data-enter-stagger]`) rather than animated, since Figma cannot express the reduced-motion contract or the no-JavaScript gate that make them correct.

---

## 4. Where the system was silent, and what was chosen

Each of these is an addition consistent with the system, not a reinterpretation. All are recorded in the variable or component description in the file itself.

1. **No type role for a control label.** Added text style `type/button`, composed *only* from existing tokens: body family, body-strong weight, body size, body leading, no tracking. No new value enters the system.
2. **No stroke-scoped ink or paper boundary.** §10.2 specifies a 1.5px ink boundary on the secondary button, but the only boundary colours in `tokens.css` are the 3:1 control greys. Binding a `TEXT_FILL`-scoped token to a stroke is precisely the scope violation this system warns about, so `line/ink-on-light` and `line/paper-on-ink` were added as `STROKE_COLOR`-scoped aliases of the *same* primitives.
3. **44px is not on the spacing ladder.** It is stated twice (touch targets, button min width), so it became its own token `layout/touch-target-min` rather than being rounded onto a ladder step.
4. **56px header height is not on the ladder either.** Recorded as mode-aware `layout/header-height` (64 desktop / 56 phone).
5. **`--content-max` is "full width" below 768px.** Encoded as 342 in Phone mode - the actual full width at the 390 design viewport (390 − 2×8 frame inset − 2×16 gutter). Desktop is 1180 as stated.
6. **The header's inner padding is never specified.** §10.1 gives only the outer frame inset. Desktop uses the panel gutter (32); the phone bar uses the 12px ladder step, because at 16 the bar overflows 390 by 1px (see §6).
7. **No icon stroke weight exists.** The chevron and the WhatsApp glyph reuse `border/control` (1.5px), the same weight, rather than introducing a second line width.
8. **Quiet button hover is unspecified.** It follows §10.1's header-link rule - secondary contrast by default, stepping to primary on hover - so no new behaviour or colour was introduced.
9. **Secondary button hover is unspecified.** It steps the ground one value, which is the system's own card idiom (§10.3).
10. **Inter-panel gap on the framed page is unspecified.** Bound to `frame-inset`, so the felt margin is uniform on all four sides.

## 5. Two contradictions inside the system - built as written, flagged here

**a. Focus ring colour on a primary button.** §10.2 says the primary button's focus ring is *paper*, citing 5.11:1. `tokens.css` `:focus-visible` says the ring on any light ground is *ink* (`--color-focus-on-light`), and §2.4 lists both. These disagree. **Built to `tokens.css`** - ink ring on light grounds, paper on ink grounds - because the ring sits at 2px offset, which puts it on the page ground, not on the fill. A paper ring there would run about 1.3:1 against the felt and be invisible, which is the exact defect the system was written to avoid. The declared 5.11:1 pair only holds where a ring touches the accent fill.

**b. "One border in the system."** §5.2 says the 1.5px control border exists for form fields and "nothing else does." §10.2 then gives the secondary button a 1.5px boundary. The secondary button was **built with the boundary**, since without it and without a fill it would be invisible; §10.2 is the more specific component contract. Worth resolving in v2 - either §5.2 admits the control boundary applies to any bounded control, or the secondary button gets a different treatment.

**c. Leading: prose vs. class.** §1.3 binds leading to five size bands and states whole-pixel results (86→90, 64→74, 26→36). The `tokens.css` role classes bind one ratio per role across a `clamp()` range, which at the phone end produces fractional leading (display-2 at 26px × 1.15 = 29.9px). Figma has per-mode values and no clamp, so **§1.3's band table was used** - it is the authoritative statement of the rule, the classes are its CSS-constrained approximation, and every resulting leading is a whole pixel as the system demands.

## 6. One measured deviation

**Mobile accent coverage is 1.13%, against a stated target of under 1%.** Desktop measures 0.365% with exactly the three painted accent fills §2.1 allows (header quote action, mid-page CTA, closing CTA). On mobile the header's quote action moves into the drawer, leaving two accent fills - but both CTA buttons are full-width at 390px, which pushes the share over the target.

This was **not** "fixed" by shrinking the buttons: a full-width primary CTA is the correct mobile pattern and the system treats the quote action as a stated conversion route. Flagging rather than trading a conversion requirement for a decorative budget.

Separately, **§10.1's phone header contents do not fit a 390px viewport at the specified type sizes.** Wordmark + full international number + WhatsApp + hamburger measured 541px against 374px available - 167px over. Resolved within the system's own allowance that contact actions may carry "text **or an accessible name**": the phone number stays visible as text (it is the conversion), while WhatsApp and the menu became 44×44 targets carrying accessible names, and the wordmark became a compact two-line lockup. It now fits with 7px to spare. If the captain wants the wordmark at full size on phone, something else in that bar has to give.

## 7. Sections left as honest placeholders, and why

Nothing was invented. Confirmed and used as real content: the phone number **+49 15567 692971** (phone and WhatsApp), the domain, the city, and the three service families.

| Section | Status | What is a placeholder |
|---|---|---|
| 2 · Hero | Copy real | The photograph. Real 4:3 ratio reserved so the real image shifts nothing. |
| 3 · Trust strip | Entirely placeholder | Rating, years, insurance sum, membership - all four values. |
| 4 · Leistungen | **Real** | The three service families are confirmed. |
| 5 · First CTA | **Real** | Phone number and quote action only. |
| 6 · Ablauf | Structure real | "Festpreis" is a business promise and is unconfirmed. |
| 7 · Einsatzgebiet | Bochum real | Coverage radius and district list. |
| 8 · Bewertungen + Teamfoto | Entirely placeholder | Review text, reviewer names, star ratings, team photograph. |
| 9 · Wie der Preis entsteht | Factors real | Every number behind them - tiering, per-km rate, surcharges, add-on prices. |
| 10 · FAQ | **Real** | Written to be answerable without a single unconfirmed fact. |
| 11 · Closing CTA | **Real** | Phone number and both actions. |
| 12 · Footer | Legal links real | E-mail, postal address, opening hours, coverage radius. |

Every placeholder renders in the out-of-brand violet with a dashed outline and reads "noch nicht bestätigt", so no frame can be mistaken for finished content. The reviews section shows **exactly two** cards, because the system requires a component that looks correct at two rather than one that merely stops looking broken at six.

**No photographs were sourced.** Image slots are Figma placeholder fills marked as unconfirmed, per the brief.

## 8. Verification performed

- **Contrast**: no colour was changed - `git diff` on `data/bochum-design-system-v1/` is empty. `node check-contrast.mjs` re-run: **85 permitted pairs, 85 pass, 3 forbidden pairs held, 0 problems.**
- **The three checks that checker explicitly does not cover** were run against the built file, since its own output names them as out of scope:
  - *Nearest painted ancestor*: every text node resolved against the nearest ancestor carrying a painted fill. **0 violations** - no light-ground token painted on ink, no ink-ground token painted on light, none of the three banned pairs present.
  - *Token scope*: **0 violations** after repair. The first pass found **15 real defects** - `TEXT_FILL`-scoped variables bound to strokes on the chevron, the WhatsApp glyph, the unconfirmed outlines and the form-field error/success/hover boundaries. Since the inventory itself puts those values on boundaries (§10.4) and outlines (tokens.css §8-9), the seven tokens involved were widened to include `STROKE_COLOR` rather than leaving illegal bindings.
  - *Content bounds ⊆ frame bounds*: **0 clipped nodes**. Four separate defects of this exact kind were caught and fixed during the build - card, navigation, footer and consent masters left at 10px while holding 200-600px of content. The cause each time was `resize()` called after a sizing mode was set, which silently resets it to FIXED.
- **Binding**: 0 unbound solid fills, 0 unbound strokes, 0 unbound text fills across all 10 component sets and both homepages.
- **Shadows**: 0 drop or inner shadows anywhere; 0 effect styles. Depth is ground change or scrim only.
- **Responsive**: 0 nodes overflowing the 390px mobile viewport horizontally at any nesting depth.
- **Visual review**: both finished homepage frames screenshotted and reviewed, plus every component set.

## 9. What could not be built, with reasons

- **Motion.** The four verbs, six-event budget, `pin`, the reduced-motion contract and the no-JavaScript gate are documented on the *Foundations / Motion + Imagery* page and marked in layer names, but not animated. Figma cannot express "removes motion while preserving final state", cannot express a script-driven animation reading the media query, and cannot express the `js-motion` gate - and a Figma smart-animate approximation would misrepresent a contract the system states as testable. The five pre-launch checks in §6.5 are all build-time tests and belong to the implementation, not the prototype.
- **Consent behaviour.** The panel's four states are built; "no third-party request on first load" is a network assertion, not a frame.
- **Native disclosure semantics.** The accordion is drawn as collapsed and expanded states; that it is `<details>`/`<summary>` and survives scripting being disabled is recorded in the component description.
- **`aria-*` attributes, `tel:` and `wa.me` targets, `data-unconfirmed` and `data-proof-source`** are carried in layer names so they survive into implementation, since Figma has no attribute layer.
- **Document rename.** The Plugin API refuses to set a document name, which is why the misnamed first file could not be repaired in place.

## 10. Suggested next decisions for the captain

1. Resolve the two internal contradictions in §5 (focus ring colour, and whether the secondary button may carry a boundary) so v2 has one owner per rule.
2. Confirm or retire each unconfirmed value in §7. Six sections cannot ship as-is; per §10.8 an unsubstantiated trust item should be **removed rather than softened**, which may mean the trust strip does not ship at all in v1.
3. Decide whether the mobile accent overage in §6 is acceptable, or whether the mobile CTA should stop being full-width.
4. Commission the team photograph. It is the single highest-value asset on the page and the one thing stock cannot substitute for.
