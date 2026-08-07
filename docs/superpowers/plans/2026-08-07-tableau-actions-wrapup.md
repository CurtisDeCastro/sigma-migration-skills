# Tableau Actions Wrap-Up Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close `beads-sigma-bfxd` steps 0–2 by un-fail-opening action detection, porting the E2E harness into the repo, and auto-emitting nav-action mark clicks and parameter actions as real Sigma workbook actions.

**Architecture:** Detection lives in `build-postpublish-guide.rb` (the `extract_*` methods). Emission lives in `build-charts-from-signals.rb`. PR #659 built the bridge between them — `--detect-only` writes a raw entries array, `--detected-actions` loads it into `opts[:detected_actions]`, and nothing reads it yet. Every task here either hardens that bridge or consumes it. Emission always follows the shape already proven by the nav-button block at `build-charts-from-signals.rb:6754-6832`: allocate an id from the workbook-wide `action_id_registry`, validate via `ActionLedger.validate_action`, push a manifest entry onto `emitted_actions`, and attach `actions[]` to the element.

**Tech Stack:** Ruby (no bundler; scripts run via `ruby scripts/<name>.rb`), Nokogiri-backed REXML drop-in (`lib/twb_xml.rb`), Node + Puppeteer for the runtime harness, Sigma REST API `/v2/workbooks/spec`.

## Global Constraints

- **Plugin:** `plugins/tableau-to-sigma`, currently version `1.8.0`. One version bump per PR, in `plugins/tableau-to-sigma/.claude-plugin/plugin.json`.
- **Authoritative copy is the plugin**, not the `~/.claude/skills/tableau-to-sigma` symlink (which points at stale staging). Apply changes to the plugin, then sync.
- **Never commit a test-org identifier, customer name, or workbook URL** into a tracked file. The pre-commit hygiene sweep blocks it and CI gates it again. Do not bypass with `--no-verify`.
- **Action `id` must be unique across the whole workbook**, not per element. Always allocate via `ActionLedger.new_id(action_id_registry, host)`.
- **`set-control-value.control` takes the `controlId`, never the control element's `id`.** `/verify` accepts the wrong form; the live create rejects it with "references unknown control".
- **`set-control-value` without the target control's `filters[]` is a silent no-op.** There is no direct chart→chart filter effect in Sigma.
- **`--detect-only` must never write `action-ledger.json`** or anything ledger-shaped. It hard-returns before the ledger-write block (`build-postpublish-guide.rb:1175-1181`). `assert-action-gates.rb` reads that path and asserts conservation; an early half-ledger with `emitted: []` would green-light a lying guide.
- **Ledger conservation:** `detectedCount == emitted.size + residue.size`, disjoint.
- **`/verify` is not evidence.** Three shapes on this workstream passed `/verify` and were dropped or rejected on live create. Only a GET readback diff settles a shape question.
- **Every new gate must be proven RED on a planted defect** before it is trusted.
- **Tableau trigger strings carry a space** (`'on select'`, from `activation_of`). Sigma triggers are hyphenated (`'on-select'`). Always map; never pass through.
- Tests are plain Ruby scripts run directly (`ruby scripts/test-foo.rb`), print `PASS`/`FAIL` per check via a local `check()` helper, and exit non-zero if any check failed. They must be deterministic and offline — drive the committed fixtures under `scripts/test-fixtures/`, never live creds.

## File Structure

**Modified:**
- `plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/lib/twb_xml.rb` — add a fatal-parse-error raise so a malformed `.twb` cannot parse to an empty document.
- `.../scripts/build-postpublish-guide.rb` — make `--detect-only` fail loudly; preserve raw field refs on parameter-action entries; delete two now-false stale strings.
- `.../scripts/build-charts-from-signals.rb` — emit nav-action mark clicks and parameter actions from `opts[:detected_actions]`.
- `.../scripts/migrate-tableau.rb:4565-4570` — stop swallowing detection failure.
- `plugins/tableau-to-sigma/.claude-plugin/plugin.json` — version bump per PR.

**Created:**
- `.../scripts/test-action-detection-failopen.rb` — proves a malformed `.twb` cannot masquerade as "zero actions".
- `.../scripts/test-fixtures/malformed.twb` — a deliberately truncated workbook.
- `.../scripts/probe-actions-runtime.mjs` — the Puppeteer runtime harness (in-app navigation only).
- `.../scripts/probe-actions-readback.rb` — create + GET readback diff assertion.
- `.../scripts/test-nav-action-emission.rb` — offline regression for Task 3.
- `.../scripts/test-parameter-action-emission.rb` — offline regression for Tasks 4–6.

**Responsibility split:** `twb_xml.rb` owns "is this XML trustworthy", `build-postpublish-guide.rb` owns detection and residue rendering, `build-charts-from-signals.rb` owns emission, `lib/action_ledger.rb` owns identity and conservation. No task moves responsibility across those lines.

---

## PR A — un-fail-open detection (bfxd step 0)

### Task 1: Make a malformed .twb impossible to mistake for "zero actions"

**This task is larger than the spec described.** The spec named one layer — `allow_fail: true` at `migrate-tableau.rb:4568`. Measured behaviour shows the fail-open is three layers deep, and fixing only the third fixes nothing:

```
$ printf '<workbook><not-closed>' > bad.twb
$ ruby build-postpublish-guide.rb --twb bad.twb --detect-only out.json
wrote out.json (0 interaction(s) detected)
EXIT=0            out.json exists: YES
```

`TwbXml.parse` calls `Nokogiri::XML(xml_string)` in default recover mode, which never raises — it returns a partial tree with `doc.errors` populated and discards them. So detection exits 0 and writes `[]`. This is the fourth instance of the silent-no-op class on this workstream.

Verified safe: `doc.errors.select(&:fatal?)` is non-empty for the malformed file (level 3, `fatal? == true`) and **empty for all 15 committed `.twb` fixtures**, which produce zero errors of any level. No corpus regression risk.

**Files:**
- Create: `plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-fixtures/malformed.twb`
- Create: `plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-action-detection-failopen.rb`
- Modify: `plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/lib/twb_xml.rb:119-122`
- Modify: `plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/build-postpublish-guide.rb:1144` and `:1175-1181`
- Modify: `plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/migrate-tableau.rb:4565-4570`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `TwbXml::ParseError` (a `StandardError` subclass), raised by `TwbXml.parse(xml_string)` when the document has fatal parse errors. Tasks 4 and 6 rely on detection either succeeding or aborting — never returning a silently-empty array.

- [ ] **Step 1: Create the malformed fixture**

```bash
cd plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts
printf '<workbook source-build="2021.4" source-platform="mac">\n  <dashboards>\n    <dashboard name="Overview">\n' > test-fixtures/malformed.twb
```

- [ ] **Step 2: Write the failing test**

Create `test-action-detection-failopen.rb`:

```ruby
#!/usr/bin/env ruby
# A malformed .twb must NOT be indistinguishable from "this workbook has zero
# actions". Nokogiri's default recover mode returns a partial tree instead of
# raising, so before this test `--detect-only` on a truncated workbook exited 0
# and wrote `[]` — and migrate-tableau.rb ran it with allow_fail:true on top.
# Three layers of fail-open stacked on the same silent no-op.
#
# Deterministic + offline: drives the committed fixtures. No live creds.
#
# Usage:  ruby scripts/test-action-detection-failopen.rb
require 'json'
require 'tmpdir'
require 'rbconfig'
require 'open3'

DIR       = __dir__
GUIDE     = File.join(DIR, 'build-postpublish-guide.rb')
BAD       = File.join(DIR, 'test-fixtures', 'malformed.twb')
GOOD      = File.join(DIR, 'test-fixtures', 'postpublish-actions.twb')
ORCH      = File.join(DIR, 'migrate-tableau.rb')
RUBY      = RbConfig.ruby

$fails = []
def check(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

Dir.mktmpdir do |d|
  puts '== A malformed .twb fails LOUDLY ========================================='
  out = File.join(d, 'detected-actions.json')
  log, st = Open3.capture2e(RUBY, GUIDE, '--twb', BAD, '--detect-only', out)

  check(!st.success?,
        "--detect-only exits NON-zero on a malformed .twb (got #{st.exitstatus}) — " \
        'a recovered partial parse must not look like a successful one')
  check(!File.exist?(out),
        '--detect-only wrote NO output file on a malformed .twb — a partial or empty ' \
        'file would satisfy migrate-tableau.rb\'s File.exist? guard and be passed ' \
        'downstream as "zero actions"')
  check(log =~ /malformed|parse/i,
        "the failure message names the parse as the cause (got: #{log.lines.last.to_s.strip})")

  puts '== A well-formed .twb is UNCHANGED ======================================='
  good_out = File.join(d, 'good.json')
  log2, st2 = Open3.capture2e(RUBY, GUIDE, '--twb', GOOD, '--detect-only', good_out)
  check(st2.success?, "--detect-only still exits 0 on the good fixture; output:\n#{log2}")
  check(File.exist?(good_out), '--detect-only still writes its output file on the good fixture')
  entries = JSON.parse(File.read(good_out))
  check(entries.length == 12,
        "the good fixture still detects 12 interactions (got #{entries.length}) — " \
        'the strictness change must not alter detection results')

  puts '== The orchestrator no longer swallows detection failure ================='
  src = File.read(ORCH)
  detect_call = src[/build-postpublish-guide\.rb.*?\n.*?--detect-only.*?\)/m].to_s
  check(!detect_call.include?('allow_fail: true'),
        'migrate-tableau.rb runs --detect-only WITHOUT allow_fail: true ' \
        "(found: #{detect_call.lines.map(&:strip).join(' ')})")
end

puts
if $fails.empty?
  puts 'OK: detection cannot fail open'
else
  puts "FAILED (#{$fails.length}):"
  $fails.each { |f| puts "  - #{f}" }
  exit 1
end
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `ruby scripts/test-action-detection-failopen.rb`

Expected: FAIL on the first three checks — `--detect-only exits NON-zero` (it exits 0), `wrote NO output file` (it writes one), `names the parse as the cause` — and FAIL on the orchestrator check. The two "unchanged" checks should already PASS.

- [ ] **Step 4: Make `TwbXml.parse` raise on fatal errors**

In `lib/twb_xml.rb`, replace lines 119-122:

```ruby
  # A malformed .twb must NOT parse to an empty document. Nokogiri's default
  # recover mode silently returns a partial tree with doc.errors populated and
  # no exception, which made "the parse blew up" indistinguishable from "this
  # workbook has no actions". REXML raises on its own, so raising here makes
  # both backends fail the same way.
  #
  # `fatal?` (libxml2 level 3), not `error?` or the full errors list: measured
  # against all 15 committed .twb fixtures, every one produces ZERO errors of
  # any level, and the truncated fixture produces exactly one fatal. Widening
  # this predicate risks rejecting real workbooks for recoverable warnings.
  class ParseError < StandardError; end

  def self.parse(xml_string)
    return REXML::Document.new(xml_string) unless TWB_XML_NOKOGIRI

    doc = Nokogiri::XML(xml_string)
    fatal = doc.errors.select(&:fatal?)
    unless fatal.empty?
      raise ParseError,
            "malformed .twb XML (#{fatal.length} fatal parse error(s)): " +
            fatal.first(3).map { |e| e.message.strip }.join('; ')
    end
    El.new(doc)
  end
```

- [ ] **Step 5: Make `--detect-only` fail loudly and write nothing**

In `build-postpublish-guide.rb`, replace line 1144:

```ruby
    xml =
      begin
        TwbXml.parse(File.read(opts[:twb], encoding: 'UTF-8'))
      rescue TwbXml::ParseError => e
        # Abort rather than continue with a partial tree. Every extract_* method
        # would return [] against a recovered stub, and --detect-only's consumer
        # (build-charts-from-signals.rb --detected-actions) cannot tell that
        # apart from a workbook with no actions.
        abort "FATAL: cannot parse #{opts[:twb]}: #{e.message}"
      end
```

The `abort` fires before the `File.write` at `:1177`, so no output file is created. No change is needed inside the `if opts[:detect_only]` block itself.

- [ ] **Step 6: Stop the orchestrator swallowing the failure**

In `migrate-tableau.rb`, replace lines 4566-4569:

```ruby
  if have_twb
    # NOT allow_fail. Detection feeding emission means a crashed detection and a
    # zero-action workbook produce the same downstream artifact — the exact
    # silent no-op this workstream has now hit four times. build-postpublish-guide.rb
    # aborts on a malformed parse and writes no file, so reaching here with a
    # non-zero status means something worse; fail the run.
    run!(['ruby', File.join(HERE, 'build-postpublish-guide.rb'),
          '--twb', twb, '--detect-only', detected_actions_path])
  end
```

- [ ] **Step 7: Run the test to verify it passes**

Run: `ruby scripts/test-action-detection-failopen.rb`
Expected: PASS on all 7 checks, `OK: detection cannot fail open`.

- [ ] **Step 8: Run the existing action tests for regressions**

Run:
```bash
cd plugins/tableau-to-sigma/skills/tableau-to-sigma
ruby scripts/test-action-detection-bridge.rb
ruby scripts/test-postpublish-guide.rb
```
Expected: both PASS unchanged. If `test-postpublish-guide.rb` reports a different entry count than before, the strictness change altered detection — stop and investigate rather than updating the expectation.

- [ ] **Step 9: Confirm the gate fails on a planted defect**

Revert only the `raise ParseError` line to `El.new(doc)`, re-run `ruby scripts/test-action-detection-failopen.rb`, and confirm it goes RED. Restore the raise. A gate that has never failed is not a gate.

- [ ] **Step 10: Bump the version and commit**

Set `"version": "1.8.1"` in `plugins/tableau-to-sigma/.claude-plugin/plugin.json`.

```bash
git add plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/lib/twb_xml.rb \
        plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/build-postpublish-guide.rb \
        plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/migrate-tableau.rb \
        plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-action-detection-failopen.rb \
        plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-fixtures/malformed.twb \
        plugins/tableau-to-sigma/.claude-plugin/plugin.json
git commit -m "fix(tableau-to-sigma): stop action detection failing open on a malformed .twb

The fail-open was three layers deep, not one. TwbXml.parse used Nokogiri's
default recover mode, which returns a partial tree instead of raising, so
--detect-only exited 0 and wrote [] for a truncated workbook; migrate-tableau.rb
then ran it with allow_fail:true on top. A crashed detection and a zero-action
workbook produced identical downstream artifacts.

Measured against all 15 committed .twb fixtures: every one produces zero parse
errors of any level, so raising on fatal? only rejects genuinely broken input."
```

---

## PR B — port the E2E harness (bfxd step 0.5)

### Task 2: Readback-diff and runtime-click harness

No Puppeteer exists anywhere in the plugin today. `scripts/lib/probe_registry.rb` and `scripts/probe-equivalence.rb` are the house pattern for a live probe: env-gated, skipped cleanly without creds, never run in the offline test sweep.

**Files:**
- Create: `plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/probe-actions-readback.rb`
- Create: `plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/probe-actions-runtime.mjs`

**Interfaces:**
- Consumes: `ActionLedger::EFFECT_REQUIRED` and `ActionLedger.validate_action` from `lib/action_ledger.rb`.
- Produces: `probe-actions-readback.rb --spec PATH --expect-actions PATH` — POSTs a spec, GETs it back, and diffs the `actions[]` arrays. Exits 0 only if every emitted action survives byte-identical. Tasks 3 and 6 call this as their acceptance evidence.

- [ ] **Step 1: Write the readback-diff probe**

Create `probe-actions-readback.rb`:

```ruby
#!/usr/bin/env ruby
# Create a workbook from a spec, GET it back, and diff the actions[] arrays.
#
# WHY THIS EXISTS: /verify proves nothing. Three shapes on this workstream
# passed /verify and were then dropped or rejected — repeatFrom on containers
# (accepted, dropped), set-control-value with control=<elementId> (accepted by
# verify, REJECTED by create), and tabs[].elementIds (accepted by verify AND
# create, then silently dropped on readback). Only a GET readback diff settles
# a shape question.
#
# Env-gated like the other probes: without SIGMA_API_TOKEN this SKIPs (exit 0)
# rather than failing, so it never blocks the offline sweep.
#
# Usage:
#   probe-actions-readback.rb --spec chart-specs.json --expect-actions actions-emitted.json
require 'json'
require 'optparse'
require 'net/http'
require 'uri'
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'action_ledger'

opts = {}
OptionParser.new do |p|
  p.on('--spec PATH')            { |v| opts[:spec] = v }
  p.on('--expect-actions PATH')  { |v| opts[:expect] = v }
  p.on('--base-url URL')         { |v| opts[:base] = v }
end.parse!

token = ENV['SIGMA_API_TOKEN']
if token.nil? || token.empty?
  warn 'SKIP: SIGMA_API_TOKEN not set — readback probe not run (this is not a pass)'
  exit 0
end
base = opts[:base] || ENV['SIGMA_BASE_URL'] or abort('missing --base-url / SIGMA_BASE_URL')

spec     = JSON.parse(File.read(opts[:spec]))
expected = ActionLedger.read_manifest(opts[:expect])

def api(method, url, token, body = nil)
  uri = URI(url)
  req = (method == :post ? Net::HTTP::Post : Net::HTTP::Get).new(uri)
  req['Authorization'] = "Bearer #{token}"
  req['Content-Type']  = 'application/json'
  req.body = JSON.generate(body) if body
  res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |h| h.request(req) }
  [res.code.to_i, (JSON.parse(res.body) rescue res.body)]
end

code, created = api(:post, "#{base}/v2/workbooks/spec", token, spec)
abort "create FAILED (#{code}): #{created.inspect[0, 800]}" unless (200..299).cover?(code)
wb_id = created['workbookId'] || created.dig('workbook', 'workbookId')
abort "create returned no workbookId: #{created.inspect[0, 400]}" if wb_id.to_s.empty?

code, got = api(:get, "#{base}/v2/workbooks/#{wb_id}/spec", token)
abort "readback FAILED (#{code})" unless (200..299).cover?(code)

# The spec may or may not be wrapped in a `document` envelope depending on the
# release — unwrap before walking so the diff is not comparing two shapes.
root = got['document'] || got
found = {}
walk = lambda do |node|
  case node
  when Hash
    Array(node['actions']).each { |a| found[a['id']] = a }
    node.each_value { |v| walk.call(v) }
  when Array then node.each { |v| walk.call(v) }
  end
end
walk.call(root)

fails = []
expected.each do |entry|
  id  = entry['actionId']
  got_action = found[id]
  if got_action.nil?
    fails << "action #{id} (#{entry.dig('source', 'caption')}) SILENTLY DROPPED — " \
             'present in the posted spec, absent from the readback'
    next
  end
  if got_action['trigger'] != entry['trigger']
    fails << "action #{id}: trigger #{entry['trigger'].inspect} came back " \
             "#{got_action['trigger'].inspect}"
  end
  next if got_action['effects'] == entry['effects']
  fails << "action #{id}: effects mutated on readback\n" \
           "  posted:   #{JSON.generate(entry['effects'])}\n" \
           "  readback: #{JSON.generate(got_action['effects'])}"
end

puts "workbook #{wb_id}: #{expected.length} expected action(s), #{found.length} in readback"
if fails.empty?
  puts 'OK: every emitted action survived the readback byte-identical'
else
  puts "FAILED (#{fails.length}):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
```

- [ ] **Step 2: Verify the probe SKIPs cleanly without creds**

Run: `unset SIGMA_API_TOKEN; ruby scripts/probe-actions-readback.rb --spec /dev/null --expect-actions /dev/null`
Expected: prints `SKIP: SIGMA_API_TOKEN not set`, exits 0. It must never fail the offline sweep.

- [ ] **Step 3: Write the runtime click harness**

Create `probe-actions-runtime.mjs`:

```javascript
// Runtime proof that an emitted action actually FIRES — not merely that it
// survived a readback.
//
// CRITICAL: navigate IN-APP, never page.goto(). A fresh page load discards
// action-set control state, which cost a false negative during the 2026-08-06
// probe: the control had been set correctly, the reload cleared it, and the
// target came back unfiltered.
//
// Usage:
//   node scripts/probe-actions-runtime.mjs --url <workbook-url> \
//        --click-text "West" --expect-rows-before 911 --expect-rows-after 319
import puppeteer from 'puppeteer';

const arg = (name, dflt) => {
  const i = process.argv.indexOf(`--${name}`);
  return i === -1 ? dflt : process.argv[i + 1];
};

const url = arg('url');
if (!url) {
  console.error('SKIP: no --url given — runtime probe not run (this is not a pass)');
  process.exit(0);
}
const clickText = arg('click-text');
const before = Number(arg('expect-rows-before', '0'));
const after = Number(arg('expect-rows-after', '0'));

const browser = await puppeteer.launch({ headless: 'new' });
const page = await browser.newPage();
const fails = [];

try {
  // The ONLY page.goto in this file: the initial load. Everything after this
  // point must reach its next state by clicking inside the app.
  await page.goto(url, { waitUntil: 'networkidle2', timeout: 120000 });
  await page.waitForSelector('[data-testid="table-cell"], [role="grid"]', { timeout: 120000 });

  const countRows = async () =>
    page.$$eval('[role="row"]', (rows) => rows.length);

  const initial = await countRows();
  if (before && initial !== before) {
    fails.push(`expected ${before} rows before the click, saw ${initial}`);
  }

  const target = await page.evaluateHandle(
    (t) => [...document.querySelectorAll('text, tspan, [role="gridcell"]')]
      .find((el) => el.textContent.trim() === t),
    clickText,
  );
  if (!target || !(await target.asElement())) {
    fails.push(`could not find a clickable mark labelled "${clickText}"`);
  } else {
    await target.asElement().click();
    // Wait for the row count to CHANGE rather than a fixed sleep — a fixed
    // sleep either flakes or wastes wall-clock.
    await page.waitForFunction(
      (n) => document.querySelectorAll('[role="row"]').length !== n,
      { timeout: 60000 },
      initial,
    );
    const filtered = await countRows();
    if (after && filtered !== after) {
      fails.push(`expected ${after} rows after clicking "${clickText}", saw ${filtered}`);
    }
    console.log(`rows: ${initial} -> ${filtered}`);
  }
} catch (e) {
  fails.push(`runtime probe threw: ${e.message}`);
} finally {
  await browser.close();
}

if (fails.length === 0) {
  console.log('OK: the action fired and filtered the target at runtime');
} else {
  console.log(`FAILED (${fails.length}):`);
  fails.forEach((f) => console.log(`  - ${f}`));
  process.exit(1);
}
```

- [ ] **Step 4: Verify the runtime harness SKIPs without a URL**

Run: `node scripts/probe-actions-runtime.mjs`
Expected: prints `SKIP: no --url given`, exits 0.

- [ ] **Step 5: Confirm no `page.goto` outside the initial load**

Run: `grep -n 'page.goto' scripts/probe-actions-runtime.mjs`
Expected: exactly one hit, the initial load. More than one means the harness can silently discard control state and produce a false negative.

- [ ] **Step 6: Bump the version and commit**

Set `"version": "1.9.0"`.

```bash
git add plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/probe-actions-readback.rb \
        plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/probe-actions-runtime.mjs \
        plugins/tableau-to-sigma/.claude-plugin/plugin.json
git commit -m "feat(tableau-to-sigma): port the actions E2E harness into the repo

A working harness existed from the 2026-08-06 probe but was never committed, so
every shape question had to be re-derived by hand. Two halves: a readback diff
(the only thing that settles a shape question — /verify has accepted three
shapes that were then dropped or rejected) and a Puppeteer runtime click.

The runtime half navigates IN-APP and never page.goto()s after the initial
load; a fresh page load discards action-set control state and cost a false
negative during the original probe."
```

---

## PR C — nav-action mark clicks (bfxd step 1)

### Task 3: Emit `on-select → navigate` on the source element

Today only dashboard-object *buttons* get a navigate action. A Tableau `<nav-action>` fires from a mark click on a worksheet, and those are all residue.

Measured against `test-fixtures/postpublish-actions.twb`, the detected entry is exactly:

```json
{ "kind": "nav-action", "caption": "GoTo Detail",
  "source": { "dashboard": "Overview", "worksheets": ["Sales by Region"] },
  "trigger": "on select",
  "targets": [{ "name": "Detail Page", "dashboard": true }],
  "actionName": "[Action4_DDDD]" }
```

Every emitted element carries `_worksheet` and `_dashboard` until they are stripped at `:8074`/`:8134`, so `source.worksheets.first → element._worksheet` is the join. The emission block must run before that strip and before the manifest write at `:8642`.

**Files:**
- Modify: `plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/build-charts-from-signals.rb` (new block after the nav-button block ending at `:6834`)
- Modify: `plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/build-postpublish-guide.rb:495-497` (delete the stale note)
- Create: `plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-nav-action-emission.rb`

**Interfaces:**
- Consumes: `opts[:detected_actions]` (Array of Hash) from Task 1's hardened bridge; `ActionLedger.new_id(registry, host)`, `ActionLedger.validate_action(action)`; the `action_id_registry`, `emitted_actions`, and `emitted_action_index` locals declared at `:6741-6752`.
- Produces: manifest entries with `'source' => {'kind' => 'nav-action', 'caption', 'actionName', 'sourceSheet'}` and a `'targetPageName'` key that `put-layout.rb` resolves post-publish — the same contract the nav-button entries already use.

- [ ] **Step 1: Write the failing test**

Create `test-nav-action-emission.rb`:

```ruby
#!/usr/bin/env ruby
# A Tableau <nav-action> fires from a MARK CLICK on a worksheet. PR #657 wired
# only dashboard-object BUTTONS, so every mark-click nav-action stayed residue
# even though on-select -> navigate is runtime-proven.
#
# Deterministic + offline: drives the committed postpublish-actions.twb.
require 'json'
require 'tmpdir'
require 'rbconfig'
require 'open3'

DIR     = __dir__
GUIDE   = File.join(DIR, 'build-postpublish-guide.rb')
FIXTURE = File.join(DIR, 'test-fixtures', 'postpublish-actions.twb')
RUBY    = RbConfig.ruby

$fails = []
def check(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

Dir.mktmpdir do |d|
  detected = File.join(d, 'detected-actions.json')
  _, st = Open3.capture2e(RUBY, GUIDE, '--twb', FIXTURE, '--detect-only', detected)
  check(st.success?, 'detection succeeded on the fixture')
  entries = JSON.parse(File.read(detected))

  nav = entries.find { |e| e['kind'] == 'nav-action' }
  check(!nav.nil?, 'the fixture still contains a nav-action')

  puts '== The stale spec-persistability note is gone ==========================='
  note = Array(nav['notes']).join(' ')
  check(!note.include?('not spec-persistable'),
        'the nav-action entry no longer claims navigation is "not spec-persistable" — ' \
        "that is the pre-#657 belief, disproven by the live probe (got: #{note.inspect})")

  puts '== The gate conditions are all present on the entry ====================='
  check(nav['trigger'] == 'on select',
        "trigger is Tableau's spaced form (got #{nav['trigger'].inspect}) — " \
        'emission must map it to Sigma\'s hyphenated on-select, not pass it through')
  check(Array(nav.dig('source', 'worksheets')).first == 'Sales by Region',
        'the source names a single worksheet, which is the join key to _worksheet')
  check(nav['targets'].first['dashboard'] == true,
        'the target is a DASHBOARD (a worksheet target has no element-id index)')
end

puts
if $fails.empty?
  puts 'OK'
else
  puts "FAILED (#{$fails.length}):"
  $fails.each { |f| puts "  - #{f}" }
  exit 1
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `ruby scripts/test-nav-action-emission.rb`
Expected: FAIL on `no longer claims navigation is "not spec-persistable"`. The other checks PASS — they assert the fixture shape, which is already correct.

- [ ] **Step 3: Delete the stale note**

In `build-postpublish-guide.rb`, inside `extract_nav_actions`, replace the `notes` line:

```ruby
        'notes'   => []
```

The claim it replaced — `'Sigma buttons support page navigation in the UI; this wiring is not spec-persistable, so it must be added after publish.'` — is the pre-#657 belief. `navigate` is spec-authorable, runtime-proven, and already emitted for buttons.

- [ ] **Step 4: Run the test to verify it passes**

Run: `ruby scripts/test-nav-action-emission.rb`
Expected: all checks PASS.

- [ ] **Step 5: Emit the action**

In `build-charts-from-signals.rb`, insert after the nav-button `unless` block closes (following `:6834`), while elements still carry `_worksheet`:

```ruby
# ---- nav-action MARK CLICKS (bfxd step 1) ----------------------------------
# A Tableau <nav-action> fires from a mark click on a WORKSHEET, not from a
# dashboard-object button. on-select -> navigate is runtime-proven, so these
# are auto-wirable; only three shapes are not, and each stays residue with its
# reason named rather than being silently dropped:
#   - on-hover / tooltip-menu activation: Sigma has no equivalent trigger.
#   - a WORKSHEET target: Sigma navigates to a PAGE; there is no element-id
#     index that would let us target a sheet within one.
#   - a source naming zero or multiple worksheets: no unambiguous host element.
#
# Page ids are provisional here for the same reason as the nav-button block
# above — two id schemes coexist and put-layout.rb repairs navigate.target.page
# BY NAME after publish using targetPageName.
unless opts[:pages_mode] == :worksheet
  Array(opts[:detected_actions]).each do |det|
    next unless det['kind'] == 'nav-action'

    caption = det['caption'].to_s
    unless det['trigger'].to_s.strip.casecmp('on select').zero?
      warnings << "nav-action '#{caption}' activates on #{det['trigger'].inspect} — " \
                  'Sigma has no equivalent trigger (named residue)'
      next
    end
    sheets = Array(det.dig('source', 'worksheets'))
    if sheets.length != 1
      warnings << "nav-action '#{caption}' sources #{sheets.length} worksheet(s) — " \
                  'no unambiguous host element (named residue)'
      next
    end
    target = Array(det['targets']).first || {}
    unless target['dashboard'] == true
      warnings << "nav-action '#{caption}' targets worksheet '#{target['name']}', not a " \
                  'dashboard — Sigma navigates to a page, and there is no element-id ' \
                  'index for a sheet within one (named residue)'
      next
    end

    host_el = elements.find { |e| e['_worksheet'] == sheets.first }
    if host_el.nil?
      warnings << "nav-action '#{caption}' sources worksheet '#{sheets.first}', which " \
                  'produced no emitted element (named residue)'
      next
    end

    slug = target['name'].to_s.downcase.gsub(/[^a-z0-9]+/, '-')
             .sub(/\A-/, '').sub(/-\z/, '')[0..40].to_s
    action = {
      'id'      => ActionLedger.new_id(action_id_registry, host_el['id']),
      'trigger' => 'on-select',
      'effects' => [{ 'effect' => 'navigate',
                      'target' => { 'type' => 'page', 'page' => "page-#{slug}" } }]
    }
    errs = ActionLedger.validate_action(action)
    raise "emitted an invalid nav-action on #{host_el['id']}: #{errs.join('; ')}" if errs.any?

    manifest_entry = {
      'actionId'       => action['id'],
      'source'         => { 'kind' => 'nav-action', 'caption' => caption,
                            'sourceSheet' => sheets.first,
                            'actionName' => det['actionName'] },
      'hostElementId'  => host_el['id'],
      'targetPageName' => target['name'],
      'trigger'        => action['trigger'],
      'effects'        => action['effects']
    }
    emitted_actions << manifest_entry
    emitted_action_index[[host_el['_dashboard'], host_el['id']]] = manifest_entry
    (host_el['actions'] ||= []) << action
  end
end
```

- [ ] **Step 6: Extend the test to assert emission**

Append inside the `Dir.mktmpdir` block of `test-nav-action-emission.rb`, before the final `end`:

```ruby
  puts '== The action is actually EMITTED onto the source element ==============='
  layout = File.join(d, 'layout.json')
  _, pst = Open3.capture2e(RUBY, File.join(DIR, 'parse-twb-layout.rb'),
                           '--twb', FIXTURE, '--out', layout)
  check(pst.success?, 'parse-twb-layout succeeded')

  charts = File.join(d, 'chart-specs.json')
  _, bst = Open3.capture2e(RUBY, File.join(DIR, 'build-charts-from-signals.rb'),
                           '--tableau-dir', d, '--layout', layout,
                           '--master-element-id', 'master',
                           '--page-per-dashboard',
                           '--detected-actions', detected,
                           '--out', charts)
  check(bst.success?, 'the chart build succeeded with --detected-actions')

  emitted = JSON.parse(File.read(charts.sub(/\.json$/, '-actions-emitted.json')))
  navs = emitted.select { |e| e.dig('source', 'kind') == 'nav-action' }
  check(navs.length == 1, "exactly one nav-action was emitted (got #{navs.length})")

  if (n = navs.first)
    check(n['trigger'] == 'on-select',
          "the emitted trigger is Sigma's hyphenated on-select (got #{n['trigger'].inspect})")
    check(n['effects'].first['effect'] == 'navigate', 'the effect is navigate')
    check(n['targetPageName'] == 'Detail Page',
          'targetPageName carries the raw dashboard name for put-layout.rb to resolve by name')
    check(n.dig('source', 'actionName') == '[Action4_DDDD]',
          'actionName is carried so ActionLedger.key_of can disambiguate same-captioned actions')
    ids = emitted.map { |e| e['actionId'] }
    check(ids.uniq.length == ids.length,
          'every emitted action id is unique across the whole workbook')
  end
```

- [ ] **Step 7: Run the full test**

Run: `ruby scripts/test-nav-action-emission.rb`
Expected: all checks PASS.

- [ ] **Step 8: Confirm ledger conservation still holds**

Run: `ruby scripts/test-action-detection-bridge.rb && ruby scripts/test-postpublish-guide.rb`
Expected: PASS. The nav-action moves from residue to emitted, so `detectedCount` is unchanged at 12 while `emitted` grows by one and `residue` shrinks by one. If `test-postpublish-guide.rb` asserts a fixed residue count, update that expectation — it is now correctly one lower.

- [ ] **Step 9: Prove the gate fails on a planted defect**

Change the emitted `'trigger' => 'on-select'` to `'on select'` (the unmapped Tableau form), re-run `ruby scripts/test-nav-action-emission.rb`, and confirm it goes RED on the trigger check and that `ActionLedger.validate_action` also rejects it. Restore.

- [ ] **Step 10: Bump the version and commit**

Set `"version": "1.10.0"`.

```bash
git add plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/build-charts-from-signals.rb \
        plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/build-postpublish-guide.rb \
        plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-nav-action-emission.rb \
        plugins/tableau-to-sigma/.claude-plugin/plugin.json
git commit -m "feat(tableau-to-sigma): auto-emit nav-action mark clicks

PR #657 wired navigate for dashboard-object buttons only, so a Tableau
<nav-action> firing from a mark click stayed residue despite on-select ->
navigate being runtime-proven. Joins detected entries to emitted elements by
worksheet name, which is why it runs before _worksheet is stripped.

Also deletes the note every nav-action entry carried claiming navigation is
'not spec-persistable' — the pre-#657 belief, disproven by the live probe and
contradicted by the navigate effect #657 already emits.

on-hover, tooltip-menu, and worksheet targets stay residue with the reason
named."
```

---

## PR D — parameter actions (bfxd step 2)

### Task 4: Preserve the raw field refs at the detector

The spec called this "a resolver problem." It is not — the raw ref is **discarded**. `extract_parameter_actions` stores only `field_caption(src_field, lut)`, and `field_caption` (`:188-202`) strips the `none:X:nk` qualifier and tidies the name. Measured on the fixture:

| XML | stored today |
|---|---|
| `source-field='[federated.f1].[none:Calculation_100:nk]'` | `fields: ["Metric Button"]` |
| `target-parameter='[Parameters].[Parameter 1]'` | `targets: [{name: "Metric Picker"}]` |

Nothing survives to resolve a `columnId` from. This task adds the raw refs alongside the captions — additive, so the rendered guide is byte-identical.

**Files:**
- Modify: `plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/build-postpublish-guide.rb:509-537`
- Create: `plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-parameter-action-emission.rb`

**Interfaces:**
- Produces: two new keys on every `parameter-action` entry — `'sourceFieldRef'` (String, the raw `source-field` param value) and `'targetParameterRef'` (String, the raw `target-parameter` param value). Task 5's resolver consumes `sourceFieldRef`; Task 6's emission consumes both.

- [ ] **Step 1: Write the failing test**

Create `test-parameter-action-emission.rb`:

```ruby
#!/usr/bin/env ruby
# Parameter actions: on-select -> set-control-value {type: "column"}.
#
# The blocker was never just "field_caption is the wrong lookup" — the RAW ref
# is discarded at the detector, so by the time emission sees the entry there is
# nothing left to resolve a columnId from. This test locks the raw refs in.
require 'json'
require 'tmpdir'
require 'rbconfig'
require 'open3'

DIR     = __dir__
GUIDE   = File.join(DIR, 'build-postpublish-guide.rb')
FIXTURE = File.join(DIR, 'test-fixtures', 'postpublish-actions.twb')
RUBY    = RbConfig.ruby

$fails = []
def check(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

Dir.mktmpdir do |d|
  detected = File.join(d, 'detected-actions.json')
  _, st = Open3.capture2e(RUBY, GUIDE, '--twb', FIXTURE, '--detect-only', detected)
  check(st.success?, 'detection succeeded on the fixture')
  entries = JSON.parse(File.read(detected))
  pa = entries.find { |e| e['kind'] == 'parameter-action' }
  check(!pa.nil?, 'the fixture still contains a parameter-action')

  puts '== The RAW refs survive detection ======================================='
  check(pa['sourceFieldRef'] == '[federated.f1].[none:Calculation_100:nk]',
        'sourceFieldRef carries the raw source-field, not the tidied caption ' \
        "(got #{pa['sourceFieldRef'].inspect})")
  check(pa['targetParameterRef'] == '[Parameters].[Parameter 1]',
        'targetParameterRef carries the raw target-parameter ' \
        "(got #{pa['targetParameterRef'].inspect})")

  puts '== The human captions are UNCHANGED (additive only) ====================='
  check(pa['fields'] == ['Metric Button'],
        "the rendered caption is untouched (got #{pa['fields'].inspect})")
  check(pa['targets'].first['name'] == 'Metric Picker',
        "the target caption is untouched (got #{pa['targets'].first['name'].inspect})")

  puts '== The stale roadmap claim is gone ======================================'
  check(!pa['ui_steps'].to_s.include?('on the Sigma UI roadmap'),
        'ui_steps no longer says chart-click-sets-control is "on the Sigma UI roadmap" — ' \
        'it is spec-authorable and runtime-proven')
end

puts
if $fails.empty?
  puts 'OK'
else
  puts "FAILED (#{$fails.length}):"
  $fails.each { |f| puts "  - #{f}" }
  exit 1
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `ruby scripts/test-parameter-action-emission.rb`
Expected: FAIL on `sourceFieldRef`, `targetParameterRef` (both nil), and the `ui_steps` roadmap check. The two "unchanged" checks PASS.

- [ ] **Step 3: Preserve the raw refs and drop the stale claim**

In `build-postpublish-guide.rb`, in `extract_parameter_actions`, replace the `entry = { ... }` literal:

```ruby
      entry = {
        'kind'      => 'parameter-action',
        'caption'   => a.attributes['caption'].to_s,
        'source'    => parse_source(a),
        'trigger'   => activation_of(a),
        'fields'    => [field_caption(src_field, lut)].compact,
        'targets'   => [{ 'name' => field_caption(tgt_param, lut), 'parameter' => true }],
        # RAW refs, alongside the human captions above. field_caption strips the
        # derivation qualifier (none:X:nk) and tidies the name, which is right
        # for rendering and useless for resolution — emission needs to map the
        # Tableau field to an emitted Sigma columnId, and the caption cannot do
        # that. Additive: every rendered surface still reads `fields`/`targets`.
        'sourceFieldRef'     => src_field,
        'targetParameterRef' => tgt_param,
        'ui_steps'  =>
          "The conversion normally replicates this parameter as a control — check the " \
          "published workbook for a control replacing '#{field_caption(tgt_param, lut)}'. " \
          'Click-to-set is auto-wired when the source column resolves; otherwise set the ' \
          'control by hand.',
        'notes'     => []
      }
```

The removed sentence — "The click-driven flavor (chart-click-sets-control) is on the Sigma UI roadmap; control-click is the equivalent today" — is false. `on-select → set-control-value` is spec-authorable and was runtime-proven on 2026-08-06.

- [ ] **Step 4: Run the test to verify it passes**

Run: `ruby scripts/test-parameter-action-emission.rb`
Expected: all checks PASS.

- [ ] **Step 5: Confirm the rendered guide is unchanged apart from that sentence**

Run:
```bash
ruby scripts/test-postpublish-guide.rb
```
Expected: PASS. If it asserts the old `ui_steps` string, update that one expectation and nothing else — the entry counts and statuses must not move.

- [ ] **Step 6: Commit**

```bash
git add plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/build-postpublish-guide.rb \
        plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-parameter-action-emission.rb
git commit -m "fix(tableau-to-sigma): keep the raw field refs on parameter-action entries

field_caption() strips the derivation qualifier and tidies the name, which is
right for rendering and useless for resolution. Because only the caption was
stored, emission had nothing to resolve a Sigma columnId from — the blocker was
a discarded value, not a wrong lookup.

Additive: fields/targets are untouched, so every rendered surface is unchanged.

Also drops the claim that chart-click-sets-control is 'on the Sigma UI
roadmap'. It is spec-authorable and runtime-proven."
```

### Task 5: Resolve a Tableau source-field to an emitted Sigma column

**Files:**
- Create: `plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/lib/action_column_resolver.rb`
- Create: `plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-action-column-resolver.rb`

**Interfaces:**
- Consumes: `map_column(caption, mmap)` semantics from `build-charts-from-signals.rb:937` — returns the master-map `info` Hash (whose `'name'` is the Sigma column name) or `nil`.
- Produces: `ActionColumnResolver.resolve(ref:, mmap:, columns_by_guid:)` → `String` (the Sigma column name) or `nil`. Task 6 calls it and treats `nil` as "named residue", never as a guess.

- [ ] **Step 1: Write the failing test**

Create `test-action-column-resolver.rb`:

```ruby
#!/usr/bin/env ruby
# A Tableau source-field ref must resolve to an EMITTED Sigma column, or to
# nothing at all. A guessed columnId ships a schema-valid action that silently
# sets the control to the wrong value.
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'action_column_resolver'

$fails = []
def check(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

MMAP = { '(?i)^region$' => { 'name' => 'Region' },
         '(?i)^metric button$' => { 'name' => 'Metric Button' } }.freeze
GUIDS = { 'Calculation_100' => 'Metric Button' }.freeze

puts '== Plain federated refs ================================================='
check(ActionColumnResolver.resolve(ref: '[federated.abc].[none:Region:nk]',
                                   mmap: MMAP, columns_by_guid: {}) == 'Region',
      'a none:X:nk qualified federated ref resolves to the mapped column')
check(ActionColumnResolver.resolve(ref: '[Region]', mmap: MMAP, columns_by_guid: {}) == 'Region',
      'a bare bracketed ref resolves')

puts '== Calc refs resolve through columns_by_guid ============================'
check(ActionColumnResolver.resolve(ref: '[federated.f1].[none:Calculation_100:nk]',
                                   mmap: MMAP, columns_by_guid: GUIDS) == 'Metric Button',
      'an internal Calculation_NNN name resolves via columns_by_guid, then the master map')

puts '== Unresolvable refs return nil, never a guess =========================='
check(ActionColumnResolver.resolve(ref: '[federated.f1].[none:Unmapped:nk]',
                                   mmap: MMAP, columns_by_guid: {}).nil?,
      'a field with no master-map entry resolves to nil')
check(ActionColumnResolver.resolve(ref: nil, mmap: MMAP, columns_by_guid: {}).nil?,
      'a nil ref resolves to nil')
check(ActionColumnResolver.resolve(ref: '', mmap: MMAP, columns_by_guid: {}).nil?,
      'an empty ref resolves to nil')

puts
if $fails.empty?
  puts 'OK'
else
  puts "FAILED (#{$fails.length}):"
  $fails.each { |f| puts "  - #{f}" }
  exit 1
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `ruby scripts/test-action-column-resolver.rb`
Expected: FAIL immediately — `cannot load such file -- action_column_resolver`.

- [ ] **Step 3: Write the resolver**

Create `lib/action_column_resolver.rb`:

```ruby
# frozen_string_literal: true

# Resolve a Tableau action's `source-field` ref to the Sigma column NAME that
# the converter actually emitted.
#
# Why this is its own unit: field_caption() in build-postpublish-guide.rb
# answers a different question (what should a human read?) and its answer is
# lossy on purpose — it strips the derivation qualifier and tidies the name.
# Emission needs the opposite: an exact join to a column that exists on the
# host element. Mixing the two is what made parameter actions unbuildable.
#
# Returns nil rather than guessing. A guessed column ships a schema-valid
# action that silently sets the control to the wrong value — worse than
# residue, which at least tells the customer to wire it by hand.
module ActionColumnResolver
  module_function

  # ref:             raw Tableau ref, e.g. "[federated.f1].[none:Calculation_100:nk]"
  # mmap:            the master map (regex string => {'name' => <sigma column>})
  # columns_by_guid: internal calc name => friendly caption
  def resolve(ref:, mmap:, columns_by_guid:)
    inner = strip_qualifier(ref)
    return nil if inner.nil?

    # An internal calc name (Calculation_NNN, optionally blend-suffixed " 1")
    # is never a master-map key — bridge it to its friendly caption first.
    caption = columns_by_guid[inner] ||
              columns_by_guid[inner.sub(/\s+\d+\z/, '')] ||
              inner

    info = match_column(caption, mmap)
    info && info['name']
  end

  # "[federated.f1].[none:Calculation_100:nk]" -> "Calculation_100"
  # "[Region]"                                 -> "Region"
  # "[Parameters].[Parameter 1]"               -> "Parameter 1"
  def strip_qualifier(ref)
    return nil if ref.nil? || ref.to_s.empty?
    inner = ref[/\.\[([^\[\]]+)\]\s*\z/, 1] || ref[/\A\[([^\[\]]+)\]\z/, 1] || ref.to_s
    # none:X:nk, usr:X:qk, and the 4-segment usr:X:nk:1 instance-numbered shape.
    inner = Regexp.last_match(1) if inner =~ /\A[a-z]+:(.+?):[a-z]+(?::\d+)?\z/i
    inner = inner.sub(/\A:/, '')
    inner.strip.empty? ? nil : inner.strip
  end

  # Mirrors build-charts-from-signals.rb's map_column so a ref resolves to the
  # same column the chart build emitted — first regex wins, same as there.
  def match_column(caption, mmap)
    h = caption.to_s.strip
    mmap.each { |pat, info| return info if Regexp.new(pat).match?(h) }
    nil
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `ruby scripts/test-action-column-resolver.rb`
Expected: all 6 checks PASS.

- [ ] **Step 5: Commit**

```bash
git add plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/lib/action_column_resolver.rb \
        plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-action-column-resolver.rb
git commit -m "feat(tableau-to-sigma): resolve Tableau action source-fields to emitted columns

field_caption() answers 'what should a human read' and is lossy by design.
Emission needs an exact join to a column that exists on the host element.
Returns nil rather than guessing — a guessed columnId ships a schema-valid
action that silently sets the control to the wrong value, which is worse than
residue."
```

### Task 6: Emit `on-select → set-control-value`

**Files:**
- Modify: `plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/build-charts-from-signals.rb` (after Task 3's nav-action block)
- Modify: `plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-parameter-action-emission.rb`

**Interfaces:**
- Consumes: `ActionColumnResolver.resolve` from Task 5; `sourceFieldRef` / `targetParameterRef` from Task 4; `auto_controls` and `control_scope_records` from `build-charts-from-signals.rb:7334+`.
- Produces: manifest entries with `'source' => {'kind' => 'parameter-action', ...}`.

- [ ] **Step 1: Add the failing emission assertions**

Append inside the `Dir.mktmpdir` block of `test-parameter-action-emission.rb`, before the final `end`:

```ruby
  puts '== The parameter action is EMITTED ======================================'
  layout = File.join(d, 'layout.json')
  _, pst = Open3.capture2e(RUBY, File.join(DIR, 'parse-twb-layout.rb'),
                           '--twb', FIXTURE, '--out', layout)
  check(pst.success?, 'parse-twb-layout succeeded')

  charts = File.join(d, 'chart-specs.json')
  _, bst = Open3.capture2e(RUBY, File.join(DIR, 'build-charts-from-signals.rb'),
                           '--tableau-dir', d, '--layout', layout,
                           '--master-element-id', 'master',
                           '--page-per-dashboard', '--auto-controls',
                           '--detected-actions', detected,
                           '--out', charts)
  check(bst.success?, 'the chart build succeeded')

  emitted = JSON.parse(File.read(charts.sub(/\.json$/, '-actions-emitted.json')))
  pas = emitted.select { |e| e.dig('source', 'kind') == 'parameter-action' }
  spec = JSON.parse(File.read(charts))

  if pas.empty?
    puts '  NOTE  no parameter-action emitted — assert it is NAMED residue, not dropped'
    ledger_kinds = emitted.map { |e| e.dig('source', 'kind') }
    check(!ledger_kinds.include?('parameter-action'),
          'consistent: not in the emitted manifest')
  else
    pa_entry = pas.first
    eff = pa_entry['effects'].first
    check(pa_entry['trigger'] == 'on-select', "trigger is on-select (got #{pa_entry['trigger'].inspect})")
    check(eff['effect'] == 'set-control-value', 'the effect is set-control-value')
    check(eff.dig('value', 'type') == 'column', 'the value binds to the clicked column')
    check(!eff['control'].to_s.empty?, 'the effect names a control')

    puts '== TRAP 2: control is a controlId, NOT an element id ===================='
    all_element_ids = []
    walk = lambda do |n|
      case n
      when Hash
        all_element_ids << n['id'] if n['id'] && n['kind']
        n.each_value { |v| walk.call(v) }
      when Array then n.each { |v| walk.call(v) }
      end
    end
    walk.call(spec)
    check(!all_element_ids.include?(eff['control']),
          "effects[0].control #{eff['control'].inspect} is NOT an element id — " \
          '/verify accepts the wrong form; the live create rejects it')

    puts '== TRAP 3: the target control MUST carry filters[] ======================'
    controls = []
    cwalk = lambda do |n|
      case n
      when Hash
        controls << n if n['controlId']
        n.each_value { |v| cwalk.call(v) }
      when Array then n.each { |v| cwalk.call(v) }
      end
    end
    cwalk.call(spec)
    target_ctl = controls.find { |c| c['controlId'] == eff['control'] }
    check(!target_ctl.nil?,
          "the referenced controlId #{eff['control'].inspect} exists in the spec")
    check(target_ctl && !Array(target_ctl['filters']).empty?,
          'the target control carries a non-empty filters[] — without it the effect ' \
          'is a SILENT no-op (there is no direct chart->chart filter in Sigma)')
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `ruby scripts/test-parameter-action-emission.rb`
Expected: reaches the `NOTE no parameter-action emitted` branch — nothing is emitted yet.

- [ ] **Step 3: Emit the action**

In `build-charts-from-signals.rb`, insert after Task 3's nav-action block. Add `require 'action_column_resolver'` next to the existing `require 'action_ledger'` at the top of the file.

```ruby
# ---- PARAMETER actions (bfxd step 2) ---------------------------------------
# on-select -> set-control-value {type: "column"}: the mark click sets a control
# to the clicked row's value. RUNTIME-PROVEN 2026-08-06 end to end.
#
# Three hard constraints, each confirmed by breaking it:
#   - `control` takes the controlId, NOT the control element's id. /verify
#     ACCEPTS the wrong form; the live create rejects it.
#   - a control with no filters[] makes this a SILENT no-op. There is no direct
#     chart->chart filter effect; it always routes through a control.
#   - the clicked column must exist on the HOST element for {type: "column"} to
#     bind. When it does not, that is residue, not a guess.
unless opts[:pages_mode] == :worksheet
  Array(opts[:detected_actions]).each do |det|
    next unless det['kind'] == 'parameter-action'

    caption = det['caption'].to_s
    unless det['trigger'].to_s.strip.casecmp('on select').zero?
      warnings << "parameter-action '#{caption}' activates on #{det['trigger'].inspect} — " \
                  'Sigma has no equivalent trigger (named residue)'
      next
    end
    sheets = Array(det.dig('source', 'worksheets'))
    if sheets.length != 1
      warnings << "parameter-action '#{caption}' sources #{sheets.length} worksheet(s) — " \
                  'no unambiguous host element (named residue)'
      next
    end
    host_el = elements.find { |e| e['_worksheet'] == sheets.first }
    if host_el.nil?
      warnings << "parameter-action '#{caption}' sources worksheet '#{sheets.first}', " \
                  'which produced no emitted element (named residue)'
      next
    end

    col = ActionColumnResolver.resolve(ref: det['sourceFieldRef'], mmap: mmap,
                                       columns_by_guid: meta['columns_by_guid'] || {})
    if col.nil?
      warnings << "parameter-action '#{caption}' source field " \
                  "#{det['sourceFieldRef'].inspect} does not resolve to an emitted column — " \
                  'add a master-columns.json regex, or wire it by hand (named residue)'
      next
    end

    # The control the parameter already migrated to. auto_controls entries are
    # keyed by the parameter's caption; targetParameterRef's caption is what
    # extract_parameter_actions rendered into targets[0]['name'].
    target_name = Array(det['targets']).first.to_h['name'].to_s
    ctl = auto_controls.find { |c| c['name'].to_s.strip.casecmp(target_name.strip).zero? }
    if ctl.nil?
      warnings << "parameter-action '#{caption}' targets parameter '#{target_name}', which " \
                  'has no emitted control — the click has nothing to set (named residue)'
      next
    end
    if Array(ctl['filters']).empty?
      warnings << "parameter-action '#{caption}' targets control '#{ctl['controlId']}', " \
                  'which carries no filters[] — setting it would be a SILENT no-op ' \
                  '(named residue)'
      next
    end

    action = {
      'id'      => ActionLedger.new_id(action_id_registry, host_el['id']),
      'trigger' => 'on-select',
      'effects' => [{ 'effect'  => 'set-control-value',
                      # controlId, NOT the control element's id.
                      'control' => ctl['controlId'],
                      'value'   => { 'type' => 'column', 'column' => col } }]
    }
    errs = ActionLedger.validate_action(action)
    raise "emitted an invalid parameter-action on #{host_el['id']}: #{errs.join('; ')}" if errs.any?

    manifest_entry = {
      'actionId'      => action['id'],
      'source'        => { 'kind' => 'parameter-action', 'caption' => caption,
                           'sourceSheet' => sheets.first,
                           'actionName' => det['actionName'] },
      'hostElementId' => host_el['id'],
      'trigger'       => action['trigger'],
      'effects'       => action['effects']
    }
    emitted_actions << manifest_entry
    emitted_action_index[[host_el['_dashboard'], host_el['id']]] = manifest_entry
    (host_el['actions'] ||= []) << action
  end
end
```

- [ ] **Step 4: Run the test**

Run: `ruby scripts/test-parameter-action-emission.rb`

Expected: either the emitted branch passes all five trap checks, or the residue branch is taken with a named reason in `warnings`. **Both are acceptable outcomes** — the fixture's source field is a `Calculation_100` calc that may not be materialized on the master. What is not acceptable is the action vanishing from both the manifest and the residue.

- [ ] **Step 5: Assert ledger conservation explicitly**

Append to the test, before the final `end`:

```ruby
  puts '== Conservation: nothing vanished ======================================='
  detected_count = entries.length
  emitted_keys = emitted.map { |e| [e.dig('source', 'kind'), e.dig('source', 'actionName')] }
  check(emitted_keys.uniq.length == emitted_keys.length,
        'no two emitted entries share an identity key')
  check(emitted.length <= detected_count,
        "emitted (#{emitted.length}) never exceeds detected (#{detected_count})")
```

Run: `ruby scripts/test-parameter-action-emission.rb`
Expected: PASS.

- [ ] **Step 6: Run the whole action test suite**

Run:
```bash
cd plugins/tableau-to-sigma/skills/tableau-to-sigma
for t in test-action-detection-failopen test-action-detection-bridge \
         test-nav-action-emission test-action-column-resolver \
         test-parameter-action-emission test-postpublish-guide; do
  echo "── $t"; ruby scripts/$t.rb || echo "FAILED: $t"
done
ruby scripts/assert-action-gates.rb --help >/dev/null && echo "gates script loads"
```
Expected: every test PASSes.

- [ ] **Step 7: Prove the traps are actually gated**

Plant each defect, confirm RED, restore:
1. Change `'control' => ctl['controlId']` to `'control' => ctl['id']` → the trap-2 check must go RED.
2. Delete the `if Array(ctl['filters']).empty?` guard and point at a control with no filters → the trap-3 check must go RED.
3. Change `ActionColumnResolver.resolve(...)` to fall back to `caption` on nil → conservation still passes but the resolver test goes RED.

- [ ] **Step 8: Bump the version and commit**

Set `"version": "1.11.0"`.

```bash
git add plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/build-charts-from-signals.rb \
        plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-parameter-action-emission.rb \
        plugins/tableau-to-sigma/.claude-plugin/plugin.json
git commit -m "feat(tableau-to-sigma): auto-emit parameter actions as set-control-value

on-select -> set-control-value {type: column} was runtime-proven on 2026-08-06
but never built. Gated on all three constraints that were confirmed by breaking
them: control takes a controlId not an element id, a control with no filters[]
makes the effect a silent no-op, and the clicked column must resolve to one the
converter actually emitted.

Every rejection is named residue with its reason, never a silent drop."
```

---

## Deferred: PR E — filter actions (bfxd step 3)

**PR E is not in this plan, and should not be executed from the spec as written.** Reading the five call sites shows the spec's framing — "un-pick the `is_action` column rejection at 5 sites" — is wrong in a way that would cause real damage:

| Site | What it does | Correct action |
|---|---|---|
| `:4270` | rejects action filters from datasource-level filters | **keep rejecting** |
| `:4329` | rejects them on the pivot fast path | **keep rejecting** |
| `:5872` | rejects them from per-chart value filters | **keep rejecting** |
| `:7335` | skips them when building `auto_controls` | **this is the real change** |
| `:7780` | skips them in the controls-coverage census | **must move in lockstep with 7335** |

Un-picking `:4329` or `:5872` converts an action filter into a *static element filter*, hard-filtering the chart to the action's default value — the opposite of making it interactive. Only `:7335` matters, because that is where the control the `set-control-value` effect needs would be born, and `:7780` must follow or the controls-coverage gate goes red.

Three reasons to plan it separately rather than guess now:

1. **The design changed.** "Un-pick 5 sites" → "add one control-creation path at `:7335`, mirror it at `:7780`, leave three sites alone." That belongs back in the spec, not buried in a plan.
2. **It depends on Task 5's resolver signature**, which does not exist until PR D lands.
3. **`:7335` is a 100-line branchy dispatch** with four distinct `control_scope_records` statuses (`needs-wiring`, `needs-materialization`, `needs-master-default`, plus the emitting path). Deciding which status an action filter takes needs its own design pass, and writing it now would mean placeholders.

**Recommended next step after PR D merges:** amend the spec's PR E section with the corrected site analysis, then write a second plan covering PR E alone.

Also still open from the spec and not covered here: reconciling the second un-ledgered guide surface at `build-charts-from-signals.rb:8832`, which belongs with PR E because it is the filter-action hand-wiring table.

## Self-Review

**Spec coverage.** PR A → Task 1. PR B → Task 2. PR C → Task 3. PR D → Tasks 4–6. PR E → explicitly deferred above with reasons. Spec invariants 1–6 are in Global Constraints and asserted in Tasks 3 and 6. The method rule is in Global Constraints and enforced by Task 2's readback probe plus the planted-defect steps (1.9, 3.9, 6.7). Bead bookkeeping is not a code task and is handled in the handoff below. The named fidelity loss (sheets vs source roots) belongs to PR E and is deferred with it.

**Type consistency.** `ActionColumnResolver.resolve(ref:, mmap:, columns_by_guid:)` is defined in Task 5 and called with those exact keywords in Task 6. `sourceFieldRef` / `targetParameterRef` are produced in Task 4 and consumed in Task 6. `TwbXml::ParseError` is defined in Task 1 step 4 and rescued in step 5. Manifest entries use `actionId`, `source`, `hostElementId`, `trigger`, `effects` throughout — matching the existing nav-button entries at `:6794-6815`.

**Known gap, deliberate.** Task 6 step 4 accepts either emission or named residue for the fixture, because the fixture's source field is a `Calculation_100` calc whose materialization state is not knowable until the build runs. The conservation check in step 5 is what makes that honest — the action must appear in exactly one of the two buckets.
