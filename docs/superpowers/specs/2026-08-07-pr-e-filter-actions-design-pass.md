# PR E (filter actions) — design pass findings

Investigation date 2026-08-07. Worktree `/Users/tjwells/wt-actions-emitters`, branch
`feat/tableau-actions-emitters`, HEAD `ed012519`.

Every claim below is tagged **[V]** verified by executing code, **[VR]** verified by reading the
exact source line (cited), or **[I]** inferred. Probe scripts live in the session scratchpad
(`probe.rb` / `probe2.rb` / `probe3.rb` + `scripts-copy/`), not in the repo. No production file
was modified.

---

## 0. Headline: the spec's own corrected framing is still wrong

The spec says `:7335` (really **`build-charts-from-signals.rb:7419`**) is "the real change".
**It is not, on its own — it is very nearly a no-op.** [V]

`:7419` sits inside a loop over `(meta['shared_filters'] || []) + promoted_int_dim_filters`
(`build-charts-from-signals.rb:7418`). `meta['shared_filters']` is populated **only** from
`//shared-view/filter` (`parse-twb-layout.rb:2149-2163`). [VR]

Tableau's `[Action (X)]` filters are **per-worksheet `sheet_link` filters**, not shared-view
filters. Measured on the one real corpus workbook that has a filter action
(`corpus/tableau/orders-overview/workbook-content.twb`): [V]

```
shared_filters total=3  is_action=0        <-- ZERO reach :7419
worksheets carrying [Action (Region)]: 5   <-- Gross Margin %…, Gross Revenue…,
                                               Monthly Revenue Trend, Order Channel…,
                                               Return Rate…
zones carrying [Action (Region)]:      5   (same five, in layout.json)
```

Reproduce:
```
ruby scripts/parse-twb-layout.rb corpus/tableau/orders-overview/workbook-content.twb /tmp/oo.json
# then inspect /tmp/oo-meta.json shared_filters vs worksheets[*].filters
```

So **un-picking `:7419` alone emits nothing for the corpus workbook.** The population of action
filters lives in `meta['worksheets'][ws]['filters']` and `layout[].zones[].filters`. A
shared-view action filter is theoretically possible (a filter action scoped "All Using This Data
Source") but does not occur in this repo's corpus. [V for absence, I for possibility]

**Consequence:** PR E must add a **new emitter**, not un-pick a line. `:7419` should stay as-is
(defensively rejecting the rare shared-view case, which carries none of the data the emitter
needs anyway).

---

## 1. Complete map of the `auto_controls` dispatch (`:7416`–`:7740`)

Loop header `:7418`; per-branch behaviour below. "Record" = `control_scope_records` push.

| # | Line | Guard / input | Record status | Control emitted? | Warning |
|---|---|---|---|---|---|
| 1 | 7419 | `f['is_action']` | **none** | no | **none** (silent) |
| 2 | 7421-7424 | `cap.nil?` | **none** | no | "shared filter #N has no resolvable column_caption … skipping auto-control" |
| 3 | 7429-7442 | `f['topn']` truthy | `needs-wiring` | no | native top-N, N + direction + order_expr named |
| 4 | 7443-7452 | `map_column` miss → `materialized_calc_column` hit | falls through to emit path | yes | "binds to a calculated field that is ALREADY materialized … wiring it" |
| 5 | 7460-7473 | still nil, caption is in `calc_formula_by_caption` | **`needs-materialization`** (+ `tableau_formula`, `sigma_formula`) | no | materialize on master + add master-columns.json regex |
| 6 | 7474-7492 | still nil, `f['is_datasource_filter']` | **`needs-master-default`** (+ `datasource_filter`, `is_active_flag`, `members`) | no | "always-on … NOT optional … gate blocks GREEN" |
| 7 | 7493-7496 | still nil, neither | **none** | no | "has no master-map entry — add a regex to master-columns.json" |
| 8 | 7502-7516 | resolved, but `control_targets` returns `targets.empty?` | **`dropped`** (+ `intended`, `unreachable`) | no | "DROPPED auto-control … no chart root carries a matching column" |
| 9 | 7517-7535 | resolved + reachable | **`emitted`** (+ `intended`, `targets`, `zone_dashboards`, `action_worksheets`, `unreachable`) | pending controlType | — |
| 9a | 7537-7646 | `kind` `list` / `list+condition` | stays `emitted` (may gain `integer_dim`, `decode`) | **yes** (`list`/`segmented`) | exclude-mode, condition, null-option helper, integer decode |
| 9b | 7647-7676 | `kind` `relative-date` | stays `emitted` | **yes** (`date-range`) | rolling vs frozen mode named |
| 9c | 7677-7708 | `kind` `number-range` | stays `emitted` | **yes** (`date-range`/`range-slider`/`slider`) | ISO-8601 normalization |
| 9d | 7709-7726 | `kind` `wildcard`, pattern parsed | stays `emitted` | **yes** (`text`) | mode + pattern named |
| 9e | 7713-7719 | `kind` `wildcard`, pattern **not** parsed | **downgraded to `needs-wiring`** | no | "STAYS-MANUAL … NOT treated as 'All'" |
| 9f | 7727-7736 | **any other `kind`** | **downgraded to `needs-wiring`** | no | "kind=… has no controlType mapping — NOT emitted" |

Note branches 9e/9f **mutate a record already pushed at `:7527`** (`control_scope_records.reverse.find`).
That is the only place in this loop where a record's status changes after the fact.

### What an action filter actually carries

`normalize_filter` **returns early** for `is_action` (`parse-twb-layout.rb:378-381`), so the hash
has exactly seven keys and nothing else: [V]

```json
{"raw_class":"categorical","raw_param":"[federated.…].[Action (Region)]",
 "column_guid":"Action (Region)","column_caption":"Action (Region)",
 "datatype":null,"is_action":true,"kind":"action"}
```

Therefore, for an action filter, branches **3, 5, 6, 9a–9e are all structurally unreachable**:
no `topn`, no `is_datasource_filter`, no `members`/`exclude`/`excludes_null`/`min`/`max`/
`wildcard`/`period_type`, no `datatype`, and `kind == 'action'`. [VR]

### Measured behaviour of a naive un-pick

Probe: inject a synthetic action filter with exactly that shape into `shared_filters`, un-pick
`:7419` **and** `:7864`, run the real script. [V]

* With a master map that does **not** match the raw caption → branch **7**:
  `"shared filter on 'Action (Region)' has no master-map entry"`, **no record at all**, and the
  census reports `1 UNACCOUNTED (Action (Region)) — must be 0`.
* With a master map that **does** match `Action (Region)` → branch **9f**:
  `"shared filter 'Action (Region)' kind=\"action\" has no controlType mapping — NOT emitted"`,
  record `ctl-action-region` / name `"Action (Region)"` / status `needs-wiring`. Census green.

Two facts fall straight out:

1. **The caption must be unwrapped `[Action (X)]` → `X` before `map_column`,** or nothing ever
   resolves and the control is named `Action (Region)` in the customer's UI. [V]
2. **`case f['kind']` needs an explicit `when 'action'` branch** or the emitter can only ever
   produce `needs-wiring`. [V]

---

## 2. What an action filter should do in each branch

The closest existing branch is **9a (`list`)** — an action filter is always a discrete member
filter on a dimension. But it must be built from the **resolved column**, not from the filter
hash, because the filter hash is empty (§1).

Recommended dispatch for a new `when 'action'` branch (or, better, a new emitter — see §7):

| Situation | Status | Emit? | Rationale |
|---|---|---|---|
| Unwrap fails (`raw_param` has no `[Action (…)]`) | `needs-wiring` | no | can't name a column; never guess |
| `map_column(X)` hits | **`emitted`** | yes — `controlType: 'list'`, `mode: 'include'`, `selectionMode: 'multiple'`, `values: []`, `source` → master column, `filters` → `targets` | `values: []` in include mode is this codebase's own "default to all" (`:7550-7552` comment) — correct unfiltered initial state |
| `map_column` misses, `materialized_calc_column(X)` hits | **`emitted`** | yes | identical to branch 4; reuse verbatim |
| `map_column` misses, `calc_formula_by_caption[X]` hits | **`needs-materialization`** | no | reuse branch 5 wholesale, including `tableau_formula`/`sigma_formula` — the agent materializes and re-runs. Do **not** invent a new status. |
| `map_column` misses, no calc | **`needs-wiring`** *(not branch 7's silent-ish path)* | no | branch 7 pushes **no record**, which is what made the census go red in the probe. An action filter must always leave a record. |
| resolved but `targets.empty?` | **`dropped`** | no | reuse branch 8 |
| resolved column is INTEGER / numeric | `emitted` **+ decode** | yes, via `route_integer_dim_decode` | `scan-workbook-gaps.rb:98` states a numeric list-control target 400s then 500s at query time. The existing guard is `if f['integer_dim'] && …` (`:7611`) and `integer_dim` is **absent** on action filters — integer-ness must be re-derived from the resolved master column. **This is a real, verified gap.** [VR] |

**`needs-master-default` is never correct for an action filter** — `is_datasource_filter` is set
only on shared-view filters whose shared-view is named after a datasource
(`parse-twb-layout.rb:2160`). [VR]

**No new status is needed.** The four existing statuses cover every case.

---

## 3. The `:7864` lockstep requirement (real line: `build-charts-from-signals.rb:7859-7893`)

The census builds `expected` from `meta['parameters']` + `meta['shared_filters']` (skipping
`is_action` at **`:7864`**), and `accounted` from `control_scope_records` **keyed by `name`**
(`:7871`), then `param_controls + auto_controls` by name with `||=` (`:7872`).

Downstream: `assert-phase6-ran.rb` **gate 7c, exit 31** reads `*-controls-coverage.json` `detail`
rows and fails BY NAME on any row that is not `emitted`, not declared in `control-scope.json`
(matched on `name`/`sourceName`, `assert-phase6-ran.rb:1864-1874`), and not in
`controls-waivers.json`. That is what goes red. [VR]

**Exactly what must change, and the three ways it breaks:**

1. **Record-or-don't-expect.** The census only stays green if every action filter added to
   `expected` is guaranteed a `control_scope_records` entry. **Measured failure:** un-picking both
   `:7419` and `:7864` while `map_column` misses lands on branch 7, which pushes no record →
   `1 UNACCOUNTED … must be 0` → gate 7c exit 31. [V]
2. **Name must match on both sides.** `expected` uses `f['column_caption'].to_s.strip` — the raw
   `"Action (Region)"`. If the emitter (correctly) names the control `"Region"`, the census row is
   still `"Action (Region)"` and is UNACCOUNTED. **`:7864`'s caption must be unwrapped in exactly
   the same way as the emitter's.** [V]
3. **Name collision silently masks a failure.** `accounted[name] = status` is a plain assignment —
   **last writer wins** — and `expected` dedupes by caption (`seen_f`). **Measured:** with a real
   quick filter `Region` *and* an action filter unwrapping to `Region`, two `control_scope_records`
   both named `"Region"` (`ctl-region-overview` = `needs-wiring`, `ctl-region` = `emitted`)
   collapsed to **one** census row reading `emitted`. The `needs-wiring` one vanished. [V]
   Tableau users filter on Region *and* action-filter on Region constantly, so this is the common
   case, not an edge. Gate 7c's `ctl_declared` map is name-keyed too, so it has the same hole.

**Recommendation:** if the emitter reads the worksheet/zone population (§0), `:7864` needs no
change at all — the census simply never sees action filters and stays green by accident. That is
worse, not better: the coverage ledger would carry no evidence for N emitted controls. So PR E
should **add** action filters to `expected` from the worksheet/zone population, deduped by
*unwrapped* caption, and **should change the census key from `name` to `[kind, name]` or
`controlId`** to close item 3. Without that key change PR E can ship a green gate over a
`needs-wiring` control.

---

## 4. The source→target join

`detect-only` output for `test-fixtures/postpublish-actions.twb` (`--detect-only /tmp/d.json`): [V]

```json
{"kind":"filter-action","caption":"Region Filter",
 "source":{"dashboard":"Overview","worksheets":["Sales by Region"]},
 "trigger":"on select","actionName":"[Action1_AAAA]",
 "fields":["Region"],
 "targets":[{"name":"Overview","dashboard":true,
             "sheets":["Sales by Region","Region Detail","Filter Panel Sheet"]}]}
```

### (a) source element
`det['source']['worksheets']` → `elements.find { |e| e['_worksheet'] == sheets.first }`, exactly
as the parameter-action emitter does (`:7928-7939`). Then the **HOST-COLUMN BINDING** guard
(`:7970-7981`) — `value: {type:'column', column: <hostColumnId>}` requires the column be on the
host. Reuse verbatim.

Fork: `parse_source` (`build-postpublish-guide.rb:253-275`) emits **no `worksheets` key** when the
action's source is `type='dashboard'` ("any sheet on dashboard X"). The parameter-action emitter
turns that into residue (`sheets.length != 1`). For a filter action a dashboard-source means
**every** sheet is a source — N host elements, N actions. PR E must decide: fan out or residue.
Recommend **fan out**, since a dashboard-wide "use as filter" is common; each host still passes
the host-column guard independently. [VR]

### (b) the column, and the two blockers

**`fields` is unusable as-is.** `link_fields` (`build-postpublish-guide.rb:298-311`) runs each ref
through `field_caption`, which `ActionColumnResolver`'s own header calls deliberately lossy
("Mixing the two is what made parameter actions unbuildable"). Worse, it flattens the link
expression's `target~s0=<source>` pairs into a single `uniq`'d list with no roles. Measured on a
probe fixture with a non-identity mapping: `fields: ["Region Name","Region"]` — order is
[target, source], but when source == target `uniq` collapses to one entry, so **arity cannot even
be read off the list**. [V]

**Fix:** extend `extract_action_blocks`'s `filter-action` case with a raw, non-lossy
`fieldPairs` (mirroring PR D's `sourceFieldRef`). The link expression parses cleanly: [V]

```
decoded: tsl:Overview?[federated.f1].[Region Name]~s0=<[federated.f1].[Region]~na>
split on "&", then "=":  lhs.sub(/~s\d+$/,'') = TARGET ref
                         rhs[/\A<(.+)>\z/,1].sub(/~na$/,'') = SOURCE ref
→ [["[federated.f1].[Region Name]", "[federated.f1].[Region]"]]
```
Verified for identity, mismatched, two-pair, and `none:Calculation_100:nk` source refs — the last
of which `ActionColumnResolver.strip_qualifier` already handles.

**Blocker 2 — `special-fields=all` has no `<link>` at all.** The *only real* filter action in the
repo corpus is exactly this shape: [V]

```xml
<action caption='Filter 1 (generated)' name='[Action1_82E31…]'>
  <source dashboard='Orders Overview' type='sheet' worksheet='Revenue by Region' />
  <command command='tsc:tsl-filter'>
    <param name='special-fields' value='all' />
    <param name='target' value='Orders Overview' />
  </command></action>
```
`fields` becomes the literal sentinel `["(all shared fields)"]`
(`build-postpublish-guide.rb:437`). Any emitter that does `map_column(fields.first)` will try to
map that string. This is the **default** action Tableau's "Use as Filter" button creates, so it is
the majority case, not an edge. [V]

**The resolution for both blockers is the same signal:** the **worksheet-level `[Action (X)]`
filters**. Tableau materializes which field the action actually binds into a hidden
`<group caption='Action (Region)' … user:auto-column='sheet_link'>` on each affected sheet. In
orders-overview: 6 sheets on the dashboard, the source `Revenue by Region` carries none, and
**all five non-source sheets carry `[Action (Region)]`**. [V]

That gives the resolved column caption (`Region`) *and* the true affected-sheet set, for
`special-fields=all` and explicit-link actions alike.

**Recommended join:**
* `detected_actions` (kind `filter-action`) → source sheet, trigger, `actionName`, ledger identity.
* worksheet-level `[Action (X)]` filters → the column X and the real affected sheets.
* the new `fieldPairs` → disambiguation when a dashboard has ≥2 filter actions (see §7).
* `targets` / `expand_target` → useful for the *stated fidelity loss* (§5) but **not** as the
  primary target signal.

### (c) the control
Build it into **`auto_controls`**, not a new array. `:8692` iterates `param_controls +
auto_controls` to build `ctl_rewrites`, and `:8737-8742` rewrites `set-control-value`'s `control`
in lockstep. A control outside those two arrays never gets its per-page suffix and the effect
ships a dangling controlId — the exact "references unknown control" live rejection the
parameter-action header calls out. [VR]

Latent bug worth flagging: `:8739-8740` is `nxt = ctl_rewrites[eff['control']]; eff['control'] =
nxt if … && nxt`. If a control is skipped for a page by `_scope_dashboards` (`:8695-8696`), no
rewrite entry exists and the effect keeps the **un-suffixed** id → dangling. Filter-action
controls will be dashboard-scoped, so PR E hits this where parameter actions mostly did not. [VR]

---

## 5. The named fidelity loss — confirmed, and it has no current home

**Confirmed in code.** `control_targets` (`:7109-7131`) buckets in-scope elements by
`root_of.call(e)` into a `roots` hash and emits **one target per root**
(`:7115-7125`). Measured: `intended` listed 2 elements, both root `master`; `targets` had **one**
entry. [V]

So when Tableau's `<param name='exclude' value='Metric Buttons'/>` separates two sheets that both
source the master, Sigma cannot separate them — the control's single master-rooted filter reaches
the excluded sheet too. `expand_target` **does** honour `exclude` at detection time (fixture:
`sheets` correctly omits `Metric Buttons`) [V], which makes this worse, not better: the detected
entry claims an exclusion the emitted spec silently cannot honour.

**Where it must be surfaced — and the spec's stated placement does not currently work.**

The spec says "written into the residue guide as a stated loss". But
`build-postpublish-guide.rb:1218` is `File.write(opts[:out], render_guide(ledger['residue'],
opts))` — the guide renders **residue only**, and `ActionLedger.join` puts an auto-emitted action
in `emitted`, disjointly (`action_ledger.rb:95-104`). An auto-emitted filter action therefore
**drops out of POSTPUBLISH_GUIDE.md entirely** and the loss has nowhere to land. [VR]

PR E must pick one and it is a real scope item:
* **(A)** add a `fidelity` / `notes` field to the emitted manifest entry **and** give
  `render_guide` an "auto-wired, with caveats" section fed from `ledger['emitted']`. Matches the
  spec's words; changes the guide's contract and `ActionGates.guide_residue_violations`.
* **(B)** route it through `warnings` → `coverage.json` (`severity: 'degraded'`), the converter's
  existing channel for named losses, **plus** the emitted-manifest field. Least disruptive.
* Either way, also record it on the `control_scope_records` entry so `control-scope.json` carries
  the evidence gate 7c reads.

Recommend **(B) + the manifest field**, and amend the spec sentence rather than bending the guide.

---

## 6. The second guide surface — `<out>-actions.md` (real line: `:9118-9169`)

It is driven off **layout zones**, not the detection ledger:
`(z['filters'] || []).select { |f| f['is_action'] }`, `dim = raw[/\[Action \(([^)]+)\)\]/, 1]`,
`'target' => z['caption']` (`:9128-9138`). It then writes a table under the heading *"For each row
below, in the published Sigma workbook: select the source element, open Actions → Add filter
action…"* — i.e. it tells the customer to hand-wire precisely what PR E will auto-build.

For orders-overview it would emit five rows (Region → each of the five target zones). [V, from the
verified zone dump]

**What must happen:**
1. Re-drive the filter-action half from the ledger, not the zones:
   `ActionLedger.join(detected: opts[:detected_actions], emitted: emitted_actions)['residue']
   .select { |e| e['kind'] == 'filter-action' }`. Both locals are in scope at `:9124`
   (`emitted_actions` declared `:6743`, `opts[:detected_actions]` `:137`). [VR]
   The zone-driven rows have no `actionName`, so they **cannot** be joined by
   `ActionLedger.key_of` as they stand — this is a rewrite of the row source, not a filter added
   on top.
2. Keep the nav-button half (`:9157-9166`) unchanged.
3. Keep the file emitted even when the filter half is empty, or update the four surfaces that
   reference it: `refs/script-map.md:95`, `refs/phase-5-workbook.md:73`,
   `refs/postpublish-interactivity.md:19`, `scan-workbook-gaps.rb:906`.

**Bonus defect found while reading — fix it in PR E.** `:5834-5840` claims to surface action
filters per chart:
```ruby
action_filters = (z['filters'] || []).select { |f|
  f['column'].to_s.include?('[Action (') || f['column'].to_s.start_with?('[Action ') }
```
Normalized filters have **no `column` key** — the keys are exactly
`raw_class, raw_param, column_guid, column_caption, datatype, is_action, kind`. [V] So
`action_filters` is always empty and the warning **`'X' has N Tableau action filter(s) —
skipped`** *never fires*. `refs/phase-5-workbook.md:73` documents a warning that cannot occur,
and `:5871`'s comment "skip action filters — already warned above" is false: today they are
skipped in total silence. Use `f['is_action']`.

---

## 7. What makes this harder than it looks

1. **The emitter has to be written from scratch against a different data source.** Not a five-line
   un-pick. (§0)
2. **`special-fields=all` is the majority shape** and carries no field list; the whole design hangs
   on the worksheet-level `[Action (X)]` back-channel. (§4)
3. **Two filter actions on the same field are indistinguishable.** The Tableau group is named
   `[Action (<field caption>)]`, so two actions on `Region` from different source sheets produce
   the identical marker on the target sheets. `fieldPairs` + `actionName` can disambiguate the
   *detected* side; the *worksheet* side cannot be split. **[I]** — no corpus workbook exercises it.
4. **Compound filter actions (N field pairs)** → N controls and N `set-control-value` effects on
   one action. `ActionLedger.validate_action` allows an N-effect array
   (`action_ledger.rb:47-70`) [VR], but N controls per action multiplies the collision surface in §3.
5. **controlId collision with a real quick filter of the same caption** — both slug to
   `ctl-<caption>`. Survived the probe only because the per-page duplication pass suffixed one of
   them; on a single-page build it is a live "Duplicate id" 400. **Namespace action-filter
   controls distinctly** (e.g. `ctl-xf-<caption>`) and reflect that in the census key. [V]
6. **Numeric/integer dimensions.** `route_integer_dim_decode` exists for exactly this, but its
   guard reads `f['integer_dim']`, which action filters never carry. (§2)
7. **Control placement vs. dangling controlId.** `_scope_dashboards` + the `:8739` nil-guard. (§4c)
8. **Corpus regression risk is low if `:7419` is left alone**, and that is the strongest argument
   for the §0 recommendation: leaving `:4271` / `:4330` / `:5873` / `:7419` untouched makes every
   zero-action workbook byte-identical by construction, satisfying the spec's own mitigation
   without needing to prove it.

### Cannot be determined without a live Sigma org

* Whether a `list` control with `mode: 'include'` and `values: []` truly means "no filtering"
  at query time. The codebase asserts it (`:7550-7552`) but nothing has round-tripped it for an
  action-driven control.
* Whether `set-control-value` writing a **numeric** host column into a control whose filter target
  was Text()-decoded matches anything. Strongly suspect a type mismatch; PR-18's decode was built
  for user-driven selection, not click-driven assignment. **This is the single most likely
  runtime-silent failure.**
* Whether the target control element must live on the **same page** as the action's host element,
  or whether a workbook-global controlId reference is accepted.
* Whether multiple `set-control-value` effects on one `on-select` trigger apply atomically.
* Whether a control that is BOTH driven by a `set-control-value` effect AND user-editable behaves
  sanely (Tableau's `auto-clear='true'` — deselecting a mark clears the filter — has no obvious
  Sigma analogue; `clear-control` is a separate effect with no second trigger to hang it on).
* Whether an action-driven control can be visually hidden. A Tableau filter action shows no widget;
  emitting a visible list control per action changes the dashboard's look.
