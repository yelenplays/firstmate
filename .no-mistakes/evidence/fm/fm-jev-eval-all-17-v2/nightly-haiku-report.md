# Jev nightly scorecard: review

Run: live, final, model jev-1.13.0. Bar 0.95, min cases 20. One site scored.

- **seat-pick** (advise): recorded 0/0 agree (no cases, below min 20); synthetic 19/20 = 0.95, 1 dangerous miss; `acts: true`

## seat-pick: needs attention

**The `acts: true` flag conflicts with the stated rule.** The synthetic set has a dangerous miss, which should veto act. The recorded set has 0 cases, below the minimum of 20, so it cannot earn act either. I expected `acts: false`. I have not changed the score. The flag is computed by code, so the scorer's veto logic should be checked.

**Miss sp-10 (synthetic, dangerous)**
- Gold: `lead-decides`
- Got: `b-2`
- Detail: `band=act conf=0.79`
- Gold source: Opus

The site acted on `b-2` at confidence 0.79 where the gold label says the decision belongs to the lead. That is the dangerous direction: it acted when it should have deferred.

**Pattern:** there is only one miss, so I can't identify a pattern. The 0.95 agreement sits exactly on the bar, and the miss is the only evidence of how the model behaves near the act threshold.

**Gold or site?** The scorecard does not include the sp-10 input, so I can't judge the label directly.
- If `lead-decides` is correct, the site's act band is too permissive at confidence 0.79.
- If `b-2` is defensible, the Opus-written gold label is wrong.

**Next steps:**
1. Pull the sp-10 input and decide which label is right.
2. Check whether 0.79 sits near the act threshold. If it does, a small threshold change may be the fix.
3. Find out why the recorded set is empty. Without real inputs, the synthetic set is the only evidence for this site.

No other site is below the bar or has dangerous misses, because the scorecard contains only seat-pick.
