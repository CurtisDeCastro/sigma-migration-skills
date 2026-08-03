# Design — accept a page-level visual verdict when no per-tile manifest exists

**Date:** 2026-08-03. **Status:** approved, ready for implementation plan.
**Bead:** `beads-sigma-co6m`. **File:** `shared/scripts/assert-phase6-ran.rb` (canonical,
synced byte-identical to 8 plugins via `shared/manifest.json`).

## Problem

`assert-phase6-ran.rb`'s anchors-oracle substitution path (used whenever
`parity-final.json` reports `charts_total <= 0` — the normal case for every
converter that has no Tableau-style exportable view CSVs, i.e. every non-Tableau
converter that shares this file) requires FOUR conditions to hold before it will
accept anchors-verdict.json as a substitute for real chart-level parity:

```
a) verify-anchors.rb pass with EVERY anchor matched
b) every visual-verify tile confirmed
c) every displayed tile returns >=1 data row
d) every displayed tile has anchor coverage or a Phase 1d coverage waiver
```

Condition (b) is computed at `shared/scripts/assert-phase6-ran.rb:1132-1133`:

```ruby
_vv = (JSON.parse(File.read(File.join(opts[:tab], 'visual-verify', 'manifest.json'))) rescue nil)
_vv_ok = _vv.is_a?(Array) && _vv.any? && _vv.all? { |t| t['visual_verified'] == true }
```

`<workdir>/visual-verify/manifest.json` is written ONLY by
`plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/verify-visual-tiles.rb`,
which compares per-tile `<tile>.tableau.png` vs `<tile>.sigma.png` pairs. Verified
directly (`find`): no other plugin has an equivalent generator. `shared/manifest.json`
(lines 355-364) confirms `assert-phase6-ran.rb` is shared byte-identical across
**8 plugins**: looker, microstrategy, powerbi, quicksight, tableau, thoughtspot,
domo, hex. So condition (b) can never be satisfied by 7 of the 8 — the moment any
of them hits the `charts_total<=0` anchors-oracle path (their normal case), they
are capped below GREEN regardless of how correct the actual migration is.

**Discovered 2026-08-03** during `domo-to-sigma`'s Track E live E2E validation
(real Domo/Sigma instance, 100% real value-parity via `build-parity-plan.rb` +
`verify-parity.rb`, 5/5 anchors matched, 39/39 DM columns clean) — every other
condition held, but (b) blocked a clean gate exit because domo has no
`verify-visual-tiles.rb` equivalent. Not a domo defect; a shared-file gap.

## Decision

Every converter already CAN produce a page-level visual verdict via
`record-visual-check.rb` (an agent with vision reads the rendered page against
the source and records `pass` or `divergent` into `parity-final.json`). When no
`visual-verify/manifest.json` exists at all, accept that recorded page-level
verdict as satisfying condition (b) for every displayed tile on that page.
**Manifest-bearing converters (Tableau) are completely unaffected** — this is
purely a fallback for the "no manifest" case, not a loosening of the existing
per-tile check.

The recorded-verdict signal to reuse is the SAME one gate 8b already reads
(`shared/scripts/assert-phase6-ran.rb:2181-2187`, reading `parity-final.json`'s
`visual_checked`/`screenshot_path`/`visual_verdict`/`agent_vision` fields, which
`record-visual-check.rb` stamps):

```ruby
recorded = s['visual_checked'] || s['screenshot_path'] || s['visual_verdict'].to_s == 'divergent'
vision_blocked = (s.key?('agent_vision') && s['agent_vision'] == false) ||
                 s['visual_verdict'].to_s == 'not-executable'
```

`recorded` alone is not enough — gate 8b's own doctrine (§D5, line 2176-2180) is
that a verdict recorded without real vision (`agent_vision=false` or
`visual_verdict="not-executable"`) is a **blind attestation**, never a substitute
for a real check. The fallback for condition (b) must apply the exact same
`vision_blocked` exclusion, or it would accept exactly the kind of unverified
"looks fine" rubber-stamp this whole anchors/visual-verify system exists to
prevent.

Both `pass` and `divergent` verdicts satisfy condition (b) — `divergent` still
means an agent with vision genuinely read the render (the ONLY thing condition
(b) is checking); the imperfection it records is priced separately via the
existing `visual-divergent` waiver-budget injection (unchanged by this fix).

## Implementation

**1. `_vv_ok` computation** (`shared/scripts/assert-phase6-ran.rb:1132-1133`) —
`summary` (the parsed `parity-final.json`) is ALREADY loaded in this exact method
scope at line 1110, so no new file read is needed:

```ruby
_vv = (JSON.parse(File.read(File.join(opts[:tab], 'visual-verify', 'manifest.json'))) rescue nil)
if _vv.is_a?(Array) && _vv.any?
  _vv_ok = _vv.all? { |t| t['visual_verified'] == true }
  _vv_source = :manifest
else
  _page_recorded = summary['visual_checked'] || summary['screenshot_path'] ||
                   summary['visual_verdict'].to_s == 'divergent'
  _page_vision_blocked = (summary.key?('agent_vision') && summary['agent_vision'] == false) ||
                         summary['visual_verdict'].to_s == 'not-executable'
  _vv_ok = _page_recorded && !_page_vision_blocked
  _vv_source = :page_verdict
end
```

(`_vv_source` is a new small local used only by step 2 below, to pick the right
wording — not persisted anywhere.)

**2. Fix a real crash the fallback would otherwise expose** — the existing
success message (`shared/scripts/assert-phase6-ran.rb:1167-1174`) does
`"+ all #{_vv.size} tile(s) image-verified ..."`. `_vv` is `nil` in the no-manifest
case; once the fallback makes `_vv_ok` true without a manifest, this line raises
`NoMethodError: undefined method 'size' for nil` — a genuine bug the fallback
would otherwise introduce, not merely a cosmetic gap. Branch the message on
`_vv_source`:

```ruby
_vv_note = _vv_source == :manifest ? "all #{_vv.size} tile(s) image-verified" :
  "page-level visual verdict recorded (#{summary['visual_verdict'] || 'checked'})"
puts "[PASS] gate 2 (value parity): 0 exportable view CSVs (all worksheets dashboard-embedded) — " \
     "the ANCHORS ORACLE stands in: anchors-verdict.json pass " \
     "(#{_av['matched']}/#{_av['checked']} anchors matched, #{_av['anchors_matched_in_displayed'] || '?'} in displayed tiles) " \
     "+ #{_vv_note} + all displayed tiles return data " \
     "+ anchor coverage #{_cov['covered']}/#{_cov['displayed']} displayed tile(s)" \
     "#{_n_waived.positive? ? " (#{_n_waived} coverage-waived at Phase 1d)" : ''}." \
     "#{anchors_tol_note.call(_av)}"
```

**3. Failure message** (`shared/scripts/assert-phase6-ran.rb:1182`) — currently
`"b) every visual-verify tile confirmed (#{_vv_ok ? 'ok' : 'incomplete'})"`. No
change needed — stays accurate under the fallback (still prints `ok`/`incomplete`
based on the same `_vv_ok`), but the FAIL block's remediation text (lines
1179-1180, "If every worksheet is dashboard-embedded... the anchors oracle can
stand in") should gain one line naming the new fallback so an operator hitting
`incomplete` knows `record-visual-check.rb` is the fix, not just "go build a
Tableau-style manifest":

```
warn '         (no manifest.json + no recorded page-level visual verdict — run'
warn '          scripts/record-visual-check.rb to satisfy this condition when your'
warn "          converter has no visual-verify/manifest.json generator)"
```

(Placed only in the `_vv_ok` false branch, i.e. only shown when (b) is actually
the blocking condition — not printed unconditionally.)

## Explicitly out of scope

- **`shared/scripts/assert-phase6-ran.rb:1622-1627`** (gate 5/7's own separate
  `_vv_ok`-style read of the same manifest, used to credit "unmatched dashboard
  zones" against visually-verified worksheet NAMES). This is a different
  mechanism — it needs a per-tile/per-name manifest to do name-level matching,
  which a single page-level verdict cannot substitute for (there's no way to
  know WHICH zone a page-level "yes I looked" verdict vouches for). Not
  currently a live blocker for non-Tableau converters: confirmed via domo's own
  live run this session, gate 5/7 SKIPs entirely when `parity-final.json` has no
  `tile_census` — which none of the 7 non-Tableau converters emit today (only
  Tableau's `build-charts-from-signals.rb --meta` writes one). Leave this path
  alone; if a future converter starts emitting `tile_census`, it will need its
  own design pass, not a copy of this fix.
- **Giving non-Tableau converters their own per-tile `verify-visual-tiles.rb`
  equivalent.** Considered and explicitly rejected (confirmed with TJ,
  2026-08-03) as disproportionate — 7 new per-converter scripts, each needing
  its own per-element render capability, to solve a gap the page-level
  substitute already closes honestly.
- **Any change to gate 8b itself** (the page-level visual-comparison gate this
  fix reuses the recorded-verdict fields from). Gate 8b's own logic, its style
  checklist requirement, and its `vision_blocked` doctrine are untouched — this
  fix only reads the SAME already-stamped fields, at an earlier point in the
  file, for a different gate's condition.

## Testing

`shared/scripts/test-assert-phase6.rb` (340 lines, scenario-based, canonical —
fanned to the 6 non-Tableau plugins per an earlier session's "assert-phase6
offline harness promoted to a SHARED canonical" work) has ONE existing
anchors-oracle scenario (`'source PNG present, source-anchors.json under the
5-anchor floor -> exit 18'`, line 254) and it does not touch condition (b) at
all. Add new scenarios:

1. No `visual-verify/manifest.json`, no recorded visual verdict in
   `parity-final.json` → condition (b) reports `incomplete`, overall gate
   still fails at exit 18/19 (whatever the surrounding conditions produce) —
   confirms the fallback does NOT silently pass when nothing was recorded.
2. No manifest, `parity-final.json` has `visual_verdict: "pass"` recorded (and
   `agent_vision` true or absent) + all of (a)/(c)/(d) hold → gate 2 passes via
   the anchors oracle, success message says "page-level visual verdict recorded
   (pass)", not a crash.
3. Same as 2 but `visual_verdict: "divergent"` → still satisfies (b) (an agent
   looked), overall run still gets the pre-existing `visual-divergent`
   waiver-budget treatment elsewhere (unchanged).
4. No manifest, `parity-final.json` has `agent_vision: false` recorded → (b)
   stays `incomplete` (blind attestation correctly rejected, matching gate 8b's
   own doctrine).
5. Manifest PRESENT and fully verified → unchanged existing behavior (a
   regression guard proving Tableau's path is untouched).

Also add: a focused test (or an assertion within scenario 2) proving the
success-message line no longer raises `NoMethodError` when `_vv` is `nil` — this
is the concrete regression the fix must not reintroduce.

## Rollout

Edit only `shared/scripts/assert-phase6-ran.rb` (the canonical) +
`shared/scripts/test-assert-phase6.rb`. Run `ruby tools/sync-shared.rb` (or
this repo's equivalent propagation step) to fan the byte-identical change to
all 8 plugin copies, then `ruby tools/check-shared.rb` to confirm canonical ==
every vendored copy. This is a **shared-files-only PR** per this repo's
governance (`shared-file-governance`: one PR touches either a single plugin or
the shared files, never both) — no plugin-specific file changes ride along.
