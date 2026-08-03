# Domo SQL-Formula Vendoring (Track E) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove `domo-to-sigma`'s live-MCP dependency for Beast Mode SQL → Sigma
formula translation by vendoring the already-tested `sigma-data-model-mcp` functions
into a committed, self-contained `converter/sql.mjs` bundle, and rewiring
`convert-beast-modes.rb` to call it via one local `node` invocation instead of an
agent relaying `convert_sql_to_sigma_formula` calls by hand.

**Architecture:** A third flavor of `tools/vendor-converters.sh`'s existing
bundle-from-mcp pattern — same ongoing "canonical source stays upstream, re-vendor
periodically" relationship as tableau/lookml/thoughtspot/qlik/powerbi/quicksight, but
a custom entry module (`build/formulas.js`, a shared SQL-formula toolkit, not a
top-level converter) and a custom export sanity-check (5 named functions, not the
generic `convert*ToSigma` regex). `convert-beast-modes.rb` gains a `--convert` mode
that resolves the converter via the same 3-tier ladder `powerbi-to-sigma` already
uses (vendored bundle default → `--mcp-dir`/`DOMO_MCP_DIR` dev override → exit-10
manual-MCP-call last resort), writes a small ephemeral `node` shim (mirroring
`migrate-powerbi.rb`'s `_convert.mjs` pattern) that replicates `tools.ts`'s existing
per-formula orchestration verbatim, and merges results back into the pending file.

**Tech Stack:** Ruby (2.6, no endless method defs), Node.js (ESM, no TypeScript at
runtime — only the vendored `.mjs`), esbuild (bundler), bash 3.2-portable shell.

**Design doc:** `docs/superpowers/specs/2026-08-03-domo-sql-formula-vendoring-design.md`
(read this first for full rationale — this plan implements it task-by-task).

## Global Constraints

- No changes to `sigma-data-model-mcp` (any repo/branch) — vendoring only reads its
  `origin/main` via a fresh clone, never modifies it.
- No new CI freshness gate for the domo bundle (matches the 6 mainline vendor-from-mcp
  converters, which have none — `PROVENANCE.json` is informational only).
- No Ruby port of `hasResidualCaseKeyword`/`hasResidualInfixOperator` regex logic —
  the vendored JS functions are called directly instead.
- `discovery/formula-overrides.json` override-eligibility is unchanged: it only fills
  a `sigmaFormula` that is missing/blank, never one that is present but
  `converted: false` (that widening is explicit non-goal / future follow-up).
- Ruby throughout this repo targets **Ruby 2.6** — no endless method defs (`def f = ...`).
- `tools/vendor-converters.sh` targets **macOS bash 3.2** — no associative arrays.
- Stage git commits with explicit file paths — never `git add -A` (shared working
  tree, other sessions may have uncommitted WIP).
- Any change under `plugins/domo-to-sigma/**` requires a strict-semver bump of
  `plugins/domo-to-sigma/.claude-plugin/plugin.json`'s `version` (currently `0.9.0`)
  or a `Skip-Version-Bump: <reason>` commit trailer — enforced by CI
  (`tools/check-plugin-version-bump.sh`).
- Work happens in a dedicated git worktree off current `origin/main`, never the
  shared `~/sigma-migration-skills` working directory. Commit frequently; never
  commit onto a branch name that has already been squash-merged into `main`.

---

### Task 1: Vendor the SQL-formula converter into `converter/sql.mjs`

**Files:**
- Modify: `tools/vendor-converters.sh`
- Create (generated artifact, committed): `plugins/domo-to-sigma/skills/domo-to-sigma/converter/sql.mjs`
- Create (generated artifact, committed): `plugins/domo-to-sigma/skills/domo-to-sigma/converter/PROVENANCE.json`

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: `converter/sql.mjs`, a self-contained ESM module exporting (at least)
  `lookSqlToSigmaRules(sql: string): string | null`,
  `lookConvertExpression(sql: string): string`,
  `hasResidualCaseKeyword(s: string): boolean`,
  `hasResidualInfixOperator(s: string): boolean`,
  `lookUnknownFunctions(sql: string): string[]` — Task 2 and Task 3 both import
  from this exact path (`plugins/domo-to-sigma/skills/domo-to-sigma/converter/sql.mjs`).

- [ ] **Step 1: Add the `domo` case to `skill_for()`**

Edit `tools/vendor-converters.sh`. Find:

```bash
    cognos|cognos-report) echo cognos-to-sigma ;;
    *) echo "" ;;
```

Replace with:

```bash
    cognos|cognos-report) echo cognos-to-sigma ;;
    domo) echo domo-to-sigma ;;
    *) echo "" ;;
```

- [ ] **Step 2: Add `domo` to the default `WANT` list**

Find:

```bash
WANT=("$@"); [ ${#WANT[@]} -eq 0 ] && WANT=(tableau lookml thoughtspot qlik powerbi quicksight cognos)
```

Replace with:

```bash
WANT=("$@"); [ ${#WANT[@]} -eq 0 ] && WANT=(tableau lookml thoughtspot qlik powerbi quicksight cognos domo)
```

- [ ] **Step 3: Add the domo special-case branch**

Find the end of the cognos branch (the line reading `ruby "$ROOT/tools/check-cognos-bundle.rb" --write` followed by `continue` and `fi`):

```bash
    ruby "$ROOT/tools/check-cognos-bundle.rb" --write
    continue
  fi

  entry="$SRC/build/$mod.js"
```

Replace with (inserting the new branch between the cognos branch and the generic path):

```bash
    ruby "$ROOT/tools/check-cognos-bundle.rb" --write
    continue
  fi

  # Domo is a third flavor: same ongoing vendor-from-mcp relationship as the
  # mainline 6 (canonical source stays upstream, re-vendor periodically — domo
  # inherits future accuracy fixes the same way they do), but its source module
  # doesn't follow the convert<Tool>ToSigma naming convention. It vendors
  # formulas.ts, a shared low-level SQL-formula toolkit already used internally
  # by lookml/dbt/snowflake/tableau's own converters — not a top-level
  # converter — so the entry file and the export sanity-check are both custom.
  if [ "$mod" = "domo" ]; then
    entry="$SRC/build/formulas.js"
    out="$dest/sql.mjs"
    [ -f "$entry" ] || { echo "FATAL: $entry missing (build the converter repo first)"; exit 1; }
    "$ESBUILD" "$entry" --bundle --format=esm --platform=node --outfile="$out" >/dev/null
    node --input-type=module -e "
      import * as m from '$out';
      const need = ['lookSqlToSigmaRules','lookConvertExpression','hasResidualCaseKeyword','hasResidualInfixOperator','lookUnknownFunctions'];
      const missing = need.filter(k => typeof m[k] !== 'function');
      if (missing.length) { console.error('FATAL: $out missing exports: ' + missing.join(', ')); process.exit(1); }
    "
    echo "✓ $skill/converter/sql.mjs  ($(du -h "$out" | cut -f1))  [vendored from formulas.ts, custom export check]"
    case "$STAMPED_DIRS" in *"|$dest|"*) : ;; *) STAMPED_DIRS="$STAMPED_DIRS|$dest|" ;; esac
    continue
  fi

  entry="$SRC/build/$mod.js"
```

- [ ] **Step 4: Verify the script's bash-3.2 portability didn't regress**

Run: `bash -n tools/vendor-converters.sh`
Expected: no output, exit 0 (syntax check only — confirms no bash-4+ constructs like
associative arrays were introduced).

- [ ] **Step 5: Clone `sigma-data-model-mcp` fresh into scratch space and build it**

Do NOT use `~/sigma-data-model-mcp` (it's on a dirty branch with ~20 untracked
scratch files per this effort's own convention — never touch it). Clone fresh:

```bash
rm -rf /tmp/sigma-data-model-mcp-vendor
git clone https://github.com/twells89/sigma-data-model-mcp.git /tmp/sigma-data-model-mcp-vendor
cd /tmp/sigma-data-model-mcp-vendor
git checkout main
npm ci
npm run build
ls build/formulas.js   # confirm it exists before proceeding
```

Expected: `build/formulas.js` exists; `npm run build` exits 0.

- [ ] **Step 6: Run the vendoring script against the fresh clone**

From the `sigma-migration-skills` worktree root:

```bash
bash tools/vendor-converters.sh /tmp/sigma-data-model-mcp-vendor domo
```

Expected output: a line `✓ domo-to-sigma/converter/sql.mjs  (NN K)  [vendored from
formulas.ts, custom export check]` and no `FATAL` lines. Confirm the files exist:

```bash
ls -la plugins/domo-to-sigma/skills/domo-to-sigma/converter/sql.mjs
cat plugins/domo-to-sigma/skills/domo-to-sigma/converter/PROVENANCE.json
```

Expected: `PROVENANCE.json` contains `"source_repo": "twells89/sigma-data-model-mcp"`,
a `source_commit` matching `git -C /tmp/sigma-data-model-mcp-vendor rev-parse --short HEAD`,
and `"vendored_modules": "sql.mjs"`.

- [ ] **Step 7: Smoke-test the bundle directly**

```bash
node --input-type=module -e "
  import * as m from './plugins/domo-to-sigma/skills/domo-to-sigma/converter/sql.mjs';
  console.log(m.lookSqlToSigmaRules('SUM(\`Net Revenue\`)'));
  console.log(m.hasResidualCaseKeyword('If(1,2,3)'));
  console.log(m.hasResidualCaseKeyword('CASE WHEN x THEN 1 END'));
"
```

Expected: three lines of output — a Sigma-formula string for the first (something
like `Sum([Net Revenue])`), `false` for the second, `true` for the third. If any
line errors or prints `undefined`, the bundle is broken — do not proceed to commit.

- [ ] **Step 8: Commit**

```bash
git add tools/vendor-converters.sh \
        plugins/domo-to-sigma/skills/domo-to-sigma/converter/sql.mjs \
        plugins/domo-to-sigma/skills/domo-to-sigma/converter/PROVENANCE.json
git commit -m "domo-to-sigma: vendor SQL-formula converter as converter/sql.mjs (Track E, 1/4)"
```

---

### Task 2: Rewire `convert-beast-modes.rb` with a `--convert` mode + 3-tier resolution

**Files:**
- Modify: `plugins/domo-to-sigma/skills/domo-to-sigma/scripts/convert-beast-modes.rb`
- Modify: `plugins/domo-to-sigma/skills/domo-to-sigma/test/test-convert-beast-modes.rb`

**Interfaces:**
- Consumes: nothing from Task 1 for its own tests (uses a hand-authored fake stub
  module so this task's tests are fast/deterministic and don't depend on upstream
  translation accuracy — that's Task 3's job against the real bundle). In practice,
  by the time this task runs, Task 1's real `converter/sql.mjs` already exists in
  the repo and this is what a live run will actually use.
- Produces: `resolve_sql_converter(mcp_dir, vendored)` (Ruby function, returns
  `[conv_path_or_nil, dev_module_or_nil, desc_or_nil]`), the `--convert` CLI flag,
  the `--converter-out PATH` CLI flag, the `--mcp-dir DIR` CLI flag. Task 4's
  `migrate-domo.rb` wiring calls `convert-beast-modes.rb --convert` and depends on
  its exit codes (0 = success, 10 = tier-3 gate, nonzero-other = hard failure) and
  on `discovery/formulas.pending.json` gaining `converted`/`warnings`/`note` keys
  per entry after this mode runs.

- [ ] **Step 1: Add `require 'open3'` and `require 'tmpdir'`**

Edit `plugins/domo-to-sigma/skills/domo-to-sigma/scripts/convert-beast-modes.rb`.
Find:

```ruby
require 'json'
require 'optparse'
```

Replace with:

```ruby
require 'json'
require 'optparse'
require 'open3'
require 'tmpdir'
```

- [ ] **Step 2: Add the vendored-path constant and `resolve_sql_converter`**

Find:

```ruby
OUT = ENV['DOMO_DISCOVERY_DIR'] || File.expand_path('../discovery', __dir__)
```

Replace with:

```ruby
OUT = ENV['DOMO_DISCOVERY_DIR'] || File.expand_path('../discovery', __dir__)

# Track E — the vendored SQL-formula converter (tools/vendor-converters.sh domo).
VENDORED_SQL = File.expand_path('../converter/sql.mjs', __dir__)

# Converter resolution, same 3-tier ladder as powerbi-to-sigma's
# migrate-powerbi.rb#resolve_converter: the vendored bundle is the DEFAULT (byte-
# identical output on any machine); a local sigma-data-model-mcp build is used
# ONLY when explicitly opted into via --mcp-dir/DOMO_MCP_DIR — no silent ~/…
# auto-discovery (that's the "works in my checkout, differs for the customer"
# footgun powerbi's own comment names). If neither resolves, the caller's
# --convert branch takes the last-resort exit-10 path. Returns
# [conv_module_path_or_nil, dev_build_dir_or_nil, description_or_nil].
def resolve_sql_converter(mcp_dir, vendored)
  dev_module = (mcp_dir && File.exist?(File.join(mcp_dir, 'build', 'formulas.js'))) ?
    File.join(mcp_dir, 'build', 'formulas.js') : nil
  conv = dev_module || (File.exist?(vendored) ? vendored : nil)
  desc =
    if conv && conv == vendored
      prov = File.join(File.dirname(vendored), 'PROVENANCE.json')
      commit = (JSON.parse(File.read(prov))['source_commit'] rescue nil)
      "VENDORED converter/sql.mjs#{commit ? " (pinned #{commit})" : ''} — no data egress"
    elsif conv
      "DEV BUILD #{conv} (explicit opt-in via --mcp-dir/DOMO_MCP_DIR)"
    end
  [conv, dev_module, desc]
end
```

- [ ] **Step 3: Write the failing test for `resolve_sql_converter`**

Append to `plugins/domo-to-sigma/skills/domo-to-sigma/test/test-convert-beast-modes.rb`,
just before the final `puts` / `if $failures.zero?` block:

```ruby
# ---------------------------------------------------------------------------
# resolve_sql_converter — Track E's 3-tier resolution (vendored default,
# --mcp-dir/DOMO_MCP_DIR dev override, nil when neither resolves).
# ---------------------------------------------------------------------------

puts '== resolve_sql_converter: vendored bundle wins when no mcp_dir given =='
Dir.mktmpdir('resolve-sql-conv') do |dir|
  vendored = File.join(dir, 'sql.mjs')
  File.write(vendored, '// fake bundle')
  File.write(File.join(dir, 'PROVENANCE.json'), JSON.generate({ 'source_commit' => 'abc1234' }))
  conv, dev_dir, desc = resolve_sql_converter(nil, vendored)
  ok(conv == vendored, 'resolves to the vendored path')
  ok(dev_dir.nil?, 'no dev build dir reported')
  ok(desc.include?('VENDORED') && desc.include?('abc1234'), 'description names VENDORED + pinned commit')
end

puts '== resolve_sql_converter: --mcp-dir wins over vendored when both present =='
Dir.mktmpdir('resolve-sql-conv-dev') do |dir|
  vendored = File.join(dir, 'sql.mjs')
  File.write(vendored, '// fake bundle')
  mcp_dir = File.join(dir, 'mcp')
  FileUtils.mkdir_p(File.join(mcp_dir, 'build'))
  File.write(File.join(mcp_dir, 'build', 'formulas.js'), '// fake dev build')
  conv, dev_dir, desc = resolve_sql_converter(mcp_dir, vendored)
  ok(conv == File.join(mcp_dir, 'build', 'formulas.js'), 'resolves to the dev build, not vendored')
  ok(dev_dir == mcp_dir, 'dev build dir reported')
  ok(desc.include?('DEV BUILD') && desc.include?('explicit opt-in'), 'description names DEV BUILD + opt-in')
end

puts '== resolve_sql_converter: nil when neither vendored nor --mcp-dir resolve =='
Dir.mktmpdir('resolve-sql-conv-none') do |dir|
  conv, dev_dir, desc = resolve_sql_converter(nil, File.join(dir, 'does-not-exist.mjs'))
  ok(conv.nil?, 'no converter resolves')
  ok(dev_dir.nil?, 'no dev dir')
  ok(desc.nil?, 'no description when nothing resolves')
end
```

Also add `require 'fileutils'` near the top of the test file (needed for
`FileUtils.mkdir_p` above). Find:

```ruby
require_relative '../scripts/convert-beast-modes'
require 'json'
require 'tmpdir'
```

Replace with:

```ruby
require_relative '../scripts/convert-beast-modes'
require 'json'
require 'tmpdir'
require 'fileutils'
```

- [ ] **Step 4: Run the test to verify it fails**

Run: `ruby plugins/domo-to-sigma/skills/domo-to-sigma/test/test-convert-beast-modes.rb`
Expected: FAIL — `undefined method 'resolve_sql_converter'` (or similar NameError),
since Step 2's code hasn't been added to the running file yet if you're doing TDD
strictly. (If Step 2 was already applied, this test should PASS immediately —
either order is fine as long as you confirm the assertions are meaningful by
temporarily breaking one, e.g. swap `conv == vendored` to `conv == 'wrong'` and
confirm it reports FAIL, then revert.)

- [ ] **Step 5: Run the test to verify it passes**

Run: `ruby plugins/domo-to-sigma/skills/domo-to-sigma/test/test-convert-beast-modes.rb`
Expected: `ALL PASS`, exit 0.

- [ ] **Step 6: Add the `--convert`, `--mcp-dir`, `--converter-out` CLI options**

Find:

```ruby
opts = {}
OptionParser.new do |o|
  o.on('--lint') { opts[:lint] = true }
  o.on('--in PATH')  { |v| opts[:in] = v }
  o.on('--out PATH') { |v| opts[:out] = v }
  o.on('--overrides PATH') { |v| opts[:overrides] = v }
end.parse!(ARGV)
```

Replace with:

```ruby
opts = {}
OptionParser.new do |o|
  o.on('--lint') { opts[:lint] = true }
  o.on('--convert') { opts[:convert] = true }
  o.on('--in PATH')  { |v| opts[:in] = v }
  o.on('--out PATH') { |v| opts[:out] = v }
  o.on('--overrides PATH') { |v| opts[:overrides] = v }
  # Track E 3-tier resolution: --mcp-dir/DOMO_MCP_DIR (tier 2, explicit dev
  # opt-in) and --converter-out (tier 3 resume — an agent-produced JSON array
  # of [{id, sigmaFormula, converted, warnings, note?}] filled by hand via the
  # manual convert_sql_to_sigma_formula MCP call the exit-10 path prints).
  o.on('--mcp-dir DIR') { |v| opts[:mcp_dir] = File.expand_path(v) }
  o.on('--converter-out PATH') { |v| opts[:converter_out] = v }
end.parse!(ARGV)
```

- [ ] **Step 7: Add the `--convert` branch**

Find:

```ruby
if opts[:lint]
  # ---- Validate a filled pending file → formulas.json --------------------
```

Replace with:

```ruby
if opts[:convert]
  # ---- Track E: run the SQL-formula converter over the whole pending file,
  # one node invocation, no agent/MCP call in the loop ----------------------
  path = opts[:in] || File.join(OUT, 'formulas.pending.json')
  pending = JSON.parse(File.read(path))

  if opts[:converter_out]
    # Tier 3 resume: an agent already ran convert_sql_to_sigma_formula by hand
    # per the exit-10 instructions below and saved [{id, sigmaFormula,
    # converted, warnings, note?}] to this file. Merge by id; never clobber
    # fields this tier doesn't supply.
    filled = JSON.parse(File.read(opts[:converter_out]))
    by_id = {}
    filled.each { |e| by_id[e['id']] = e }
    pending.each do |e|
      src = by_id[e['id']]
      next unless src
      e['sigmaFormula'] = src['sigmaFormula']
      e['converted']    = src['converted']
      e['warnings']     = src['warnings']
      e['note']         = src['note'] if src['note']
    end
    out = opts[:out] || path
    File.write(out, JSON.pretty_generate(pending))
    warn "  filled #{filled.size} formula(s) from --converter-out #{opts[:converter_out]}"
    exit 0
  end

  conv, _dev_dir, desc = resolve_sql_converter(opts[:mcp_dir] || ENV['DOMO_MCP_DIR'], VENDORED_SQL)
  if conv.nil?
    warn '  vendored converter (converter/sql.mjs) missing and no local sigma-data-model-mcp ' \
         'build (--mcp-dir / DOMO_MCP_DIR).'
    warn ''
    warn '  >>> GATE: for EACH entry in discovery/formulas.pending.json, call'
    warn '      convert_sql_to_sigma_formula(sql: normalizedSql), collect the result as'
    warn '      {id, sigmaFormula, converted, warnings, note?}, write the whole array to a'
    warn '      JSON file, then re-run:'
    warn '        ruby scripts/convert-beast-modes.rb --convert --converter-out <that file>'
    warn '      No formulas were translated.'
    exit 10
  end
  warn "  converter: #{desc}"

  import_specifier =
    (Gem.win_platform? && conv.to_s.match?(/\A[A-Za-z]:/)) ? 'file:///' + conv.gsub('\\', '/') : conv

  Dir.mktmpdir('domo-convert') do |dir|
    in_path  = File.join(dir, 'pending.json')
    res_path = File.join(dir, 'results.json')
    File.write(in_path, JSON.generate(pending))

    runner = File.join(dir, 'run.mjs')
    File.write(runner, <<~JS)
      import { readFileSync, writeFileSync } from 'node:fs';
      import { lookSqlToSigmaRules, lookConvertExpression, hasResidualCaseKeyword, hasResidualInfixOperator, lookUnknownFunctions } from #{import_specifier.to_json};
      const pending = JSON.parse(readFileSync(#{in_path.to_json}, 'utf8'));
      // Same per-formula orchestration as sigma-data-model-mcp's src/tools.ts
      // convert_sql_to_sigma_formula tool handler — try the rule engine first,
      // fall back to the total mechanical converter, then check for residual
      // untranslated SQL syntax the same way the live tool already does.
      const NOTE = 'Could not fully translate — output still contains raw SQL syntax Sigma has no equivalent for (CASE/WHEN/THEN, or an infix LIKE/BETWEEN), do not use as-is';
      const out = pending.map((entry) => {
        const sql = entry.normalizedSql;
        const warnings = lookUnknownFunctions(sql).map(fn => `${fn}() has no Sigma mapping — emitted as-is; verify it exists in Sigma.`);
        let sigmaFormula = lookSqlToSigmaRules(sql);
        if (sigmaFormula == null) sigmaFormula = lookConvertExpression(sql);
        const converted = !hasResidualCaseKeyword(sigmaFormula) && !hasResidualInfixOperator(sigmaFormula);
        const result = { ...entry, sigmaFormula, converted, warnings };
        if (!converted) result.note = NOTE;
        return result;
      });
      writeFileSync(#{res_path.to_json}, JSON.stringify(out));
    JS

    _stdout, stderr, status = Open3.capture3('node', runner)
    abort "FATAL: converter failed:\n#{stderr}" unless status.success?
    pending = JSON.parse(File.read(res_path))
  end

  out = opts[:out] || path
  File.write(out, JSON.pretty_generate(pending))
  unreliable = pending.count { |e| e['converted'] == false }
  if unreliable.positive?
    warn "  wrote #{out} (#{pending.size} formulas; #{unreliable} flagged converted:false — review before --lint)"
  else
    warn "  wrote #{out} (#{pending.size} formulas, all converted:true)"
  end
elsif opts[:lint]
  # ---- Validate a filled pending file → formulas.json --------------------
```

- [ ] **Step 8: Add the `converted:false` visibility warning to `resolve_entry`**

Find:

```ruby
  errs, lint_warns = lint_formula(sigma, entry['class'])
  resolved = entry.merge('sigmaFormula' => sigma, 'lintErrors' => errs, 'lintWarnings' => lint_warns)
  if used_override
    resolved['_source'] = 'formula-override'
    resolved['note'] = override['note'] if override['note']
    warnings << "#{entry['name'] || entry['id']}: sigmaFormula supplied by " \
      "discovery/formula-overrides.json (hand-authored) — automated conversion " \
      "(convert_sql_to_sigma_formula) did not produce a usable formula for this " \
      "Beast Mode; verify by hand. CASE WHEN / COUNT(DISTINCT) / double-bracketed " \
      "ALL-CAPS refs are fixed (sigma-data-model-mcp PR #115, #116) so this is NOT " \
      "that historical 74%-fail case — check refs/live-validation-2026-07-30.md " \
      "and this script's still-open gaps (WEEKDAY→DAYOFWEEK, CEILING/FLOOR " \
      "aggregates, untranslatable infix LIKE) for what actually still needs a " \
      "hand-authored formula."
  end
  [resolved, warnings]
```

Replace with:

```ruby
  errs, lint_warns = lint_formula(sigma, entry['class'])
  resolved = entry.merge('sigmaFormula' => sigma, 'lintErrors' => errs, 'lintWarnings' => lint_warns)
  if used_override
    resolved['_source'] = 'formula-override'
    resolved['note'] = override['note'] if override['note']
    warnings << "#{entry['name'] || entry['id']}: sigmaFormula supplied by " \
      "discovery/formula-overrides.json (hand-authored) — automated conversion " \
      "(convert_sql_to_sigma_formula) did not produce a usable formula for this " \
      "Beast Mode; verify by hand. CASE WHEN / COUNT(DISTINCT) / double-bracketed " \
      "ALL-CAPS refs are fixed (sigma-data-model-mcp PR #115, #116) so this is NOT " \
      "that historical 74%-fail case — check refs/live-validation-2026-07-30.md " \
      "and this script's still-open gaps (WEEKDAY→DAYOFWEEK, CEILING/FLOOR " \
      "aggregates, untranslatable infix LIKE) for what actually still needs a " \
      "hand-authored formula."
  elsif entry['converted'] == false
    # Track E: --convert already computed a REAL converted flag (via the
    # vendored hasResidualCaseKeyword/hasResidualInfixOperator) — surface it
    # loudly here rather than letting a "flagged unreliable but still has SOME
    # string in sigmaFormula" entry ride through --lint silently. Does NOT
    # change override-eligibility (still fills-missing-only, unchanged) — this
    # is visibility only.
    warnings << "#{entry['name'] || entry['id']}: automated conversion flagged this formula as " \
      "converted:false (still contains raw CASE/WHEN/THEN or an infix LIKE/BETWEEN Sigma has no " \
      "equivalent for) — review before shipping; consider a discovery/formula-overrides.json entry."
  end
  [resolved, warnings]
```

- [ ] **Step 9: Update the normalize-mode "next step" instructions**

Find:

```ruby
  warn "  wrote #{out} (#{pending.size} Beast Modes to translate)"
  warn "\n  Next (Phase 2): for each entry call convert_sql_to_sigma_formula(sql: normalizedSql),"
  warn "  write the result into `sigmaFormula`, apply preWarning overrides (CEILING/FLOOR/window/LOD),"
  warn "  then: ruby scripts/convert-beast-modes.rb --lint"
```

Replace with:

```ruby
  warn "  wrote #{out} (#{pending.size} Beast Modes to translate)"
  warn "\n  Next (Phase 2): ruby scripts/convert-beast-modes.rb --convert   # local node, no MCP call"
  warn "  then:            ruby scripts/convert-beast-modes.rb --lint"
```

- [ ] **Step 10: Write a fake-stub CLI test for `--convert`'s plumbing**

Append to `test-convert-beast-modes.rb`, after the `resolve_sql_converter` tests
added in Step 3:

```ruby
# ---------------------------------------------------------------------------
# --convert CLI mode — plumbing test against a hand-authored FAKE stub module
# (deterministic, no dependency on the real vendored bundle's translation
# accuracy — that's covered separately by test-convert-beast-modes-fixtures.rb
# against the real converter/sql.mjs). Exercises: shim generation, node
# invocation, result merge, and the converted:false marking.
# ---------------------------------------------------------------------------

puts '== CLI --convert: dev-build tier (--mcp-dir) runs the fake stub end-to-end =='
node_present = begin
  _o, _e, st = Open3.capture3('node', '--version')
  st.success?
rescue Errno::ENOENT
  false
end

if node_present
  Dir.mktmpdir('convert-mode-fake-stub') do |dir|
    mcp_dir = File.join(dir, 'fake-mcp')
    FileUtils.mkdir_p(File.join(mcp_dir, 'build'))
    File.write(File.join(mcp_dir, 'build', 'formulas.js'), <<~JS)
      export function lookSqlToSigmaRules(sql) {
        return sql.startsWith('FAIL_RULES') ? null : `RULES(${sql})`;
      }
      export function lookConvertExpression(sql) { return `EXPR(${sql})`; }
      export function hasResidualCaseKeyword(s) { return s.includes('BADCASE'); }
      export function hasResidualInfixOperator(s) { return s.includes('BADINFIX'); }
      export function lookUnknownFunctions(sql) { return sql.includes('UNKNOWNFN') ? ['UNKNOWNFN'] : []; }
    JS

    pending_path = File.join(dir, 'formulas.pending.json')
    out_path     = File.join(dir, 'formulas.pending.json') # in place
    File.write(pending_path, JSON.generate([
      { 'id' => 'calculation_clean-1', 'name' => 'Clean One', 'normalizedSql' => 'SUM([x])', 'sigmaFormula' => nil },
      { 'id' => 'calculation_fallback-1', 'name' => 'Fallback One', 'normalizedSql' => 'FAIL_RULES SUM([x])', 'sigmaFormula' => nil },
      { 'id' => 'calculation_badcase-1', 'name' => 'Bad Case One', 'normalizedSql' => 'BADCASE([x])', 'sigmaFormula' => nil },
      { 'id' => 'calculation_unknownfn-1', 'name' => 'Unknown Fn One', 'normalizedSql' => 'UNKNOWNFN([x])', 'sigmaFormula' => nil },
    ]))

    cmd = ['ruby', SCRIPT, '--convert', '--mcp-dir', mcp_dir, '--in', pending_path, '--out', out_path]
    output = IO.popen(cmd, err: [:child, :out], &:read)
    ok($?.success?, "--convert exits 0 against a fake dev-build stub\n#{output unless $?.success?}")
    ok(output.include?('DEV BUILD') && output.include?('explicit opt-in'), 'stderr names the DEV BUILD tier')

    result = JSON.parse(File.read(out_path))
    by_id = {}
    result.each { |e| by_id[e['id']] = e }

    ok(by_id['calculation_clean-1']['sigmaFormula'] == 'RULES(SUM([x]))', 'rule-engine path used when it returns non-null')
    ok(by_id['calculation_clean-1']['converted'] == true, 'clean formula marked converted:true')

    ok(by_id['calculation_fallback-1']['sigmaFormula'] == 'EXPR(FAIL_RULES SUM([x]))', 'falls back to lookConvertExpression when rules return null')

    ok(by_id['calculation_badcase-1']['sigmaFormula'] == 'RULES(BADCASE([x]))', 'residual-flagged formula is still emitted, never dropped')
    ok(by_id['calculation_badcase-1']['converted'] == false, 'residual CASE keyword marks converted:false')
    ok(by_id['calculation_badcase-1']['note'].to_s.include?('Could not fully translate'), 'converted:false entry carries a note')

    ok(by_id['calculation_unknownfn-1']['warnings'].any? { |w| w.include?('UNKNOWNFN') }, 'lookUnknownFunctions warning surfaced per entry')
  end

  puts '== CLI --convert: --converter-out tier-3 resume merges by id =='
  Dir.mktmpdir('convert-mode-tier3') do |dir|
    pending_path = File.join(dir, 'formulas.pending.json')
    conv_out     = File.join(dir, 'manual-mcp-results.json')
    File.write(pending_path, JSON.generate([
      { 'id' => 'calculation_manual-1', 'name' => 'Manual One', 'normalizedSql' => 'SUM([x])', 'sigmaFormula' => nil },
    ]))
    File.write(conv_out, JSON.generate([
      { 'id' => 'calculation_manual-1', 'sigmaFormula' => 'Sum([x])', 'converted' => true, 'warnings' => [] },
    ]))
    cmd = ['ruby', SCRIPT, '--convert', '--converter-out', conv_out, '--in', pending_path, '--out', pending_path]
    output = IO.popen(cmd, err: [:child, :out], &:read)
    ok($?.success?, "--converter-out resume exits 0\n#{output unless $?.success?}")
    result = JSON.parse(File.read(pending_path))
    ok(result.first['sigmaFormula'] == 'Sum([x])', 'manual MCP result merged into the pending file by id')
  end
else
  puts '== CLI --convert: SKIPPED (node not on PATH) =='
end
```

The `--convert` CLI's tier-3 exit-10 gate fires exactly when
`resolve_sql_converter` returns `nil` for its first element — Step 3's
`resolve_sql_converter: nil when neither vendored nor --mcp-dir resolve` test
already asserts that condition directly, so no separate CLI-level exit-10 test
is added here (it would just be re-testing the same branch through an extra
process-spawn layer for no new coverage).

- [ ] **Step 11: Run the full test file to verify it fails, then passes**

Run: `ruby plugins/domo-to-sigma/skills/domo-to-sigma/test/test-convert-beast-modes.rb`
Expected (before Step 6-9's implementation is in place): FAIL — CLI invocation
errors on the unrecognized `--convert` flag. After Step 6-9 are applied: `ALL PASS`,
exit 0.

- [ ] **Step 12: Commit**

```bash
git add plugins/domo-to-sigma/skills/domo-to-sigma/scripts/convert-beast-modes.rb \
        plugins/domo-to-sigma/skills/domo-to-sigma/test/test-convert-beast-modes.rb
git commit -m "domo-to-sigma: add --convert mode + 3-tier converter resolution (Track E, 2/4)"
```

---

### Task 3: Real-bundle accuracy fixture test

**Files:**
- Create: `plugins/domo-to-sigma/skills/domo-to-sigma/test/test-convert-beast-modes-fixtures.rb`

**Interfaces:**
- Consumes: Task 1's `converter/sql.mjs` (must exist on disk — this test aborts
  loudly if it's missing, per the tableau-exemplar pattern).
- Produces: nothing consumed by later tasks — this is a leaf test file.

- [ ] **Step 1: Write the fixture test file**

```ruby
#!/usr/bin/env ruby
# Accuracy fixture suite for the vendored converter/sql.mjs (Track E). Offline +
# deterministic. Pattern copied from tableau-to-sigma's test-converter-fixtures.rb
# (the exemplar this skill's own design doc cites): a symbol-count guard runs
# UNCONDITIONALLY so a re-vendor that drops/renames a needed export hard-aborts
# rather than silently skipping every fixture; if `node` is present, fixtures run
# for real against the bundle; if absent, SKIPPED loudly, never a silent pass.
#
#   ruby test/test-convert-beast-modes-fixtures.rb
require 'json'
require 'open3'
require 'tmpdir'

VENDORED = File.expand_path('../converter/sql.mjs', __dir__)

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# ---------------------------------------------------------------------------
# Representative Beast Mode SQL snippets (post-normalize_bm — backticks already
# rewritten to [brackets], matching what --convert actually feeds the bundle).
# Deliberately NOT the mcp's own 74-item corpus — that stays upstream-only; a
# domo-side dependency on it would reintroduce exactly the coupling Track E
# removes. :expect_converted false marks a formula this converter is KNOWN not
# to fully translate (still an honest, present sigmaFormula) — never asserted
# as a bug, just locked so a future upstream fix is noticed via NOTE below.
# ---------------------------------------------------------------------------
FIXTURES = [
  { id: 'D-1', sql: 'SUM([Net Revenue])',                        expect: 'Sum([Net Revenue])' },
  { id: 'D-2', sql: 'COUNT(DISTINCT [Order Id])',                 expect: 'CountDistinct([Order Id])' },
  { id: 'D-3', sql: 'AVG([Order Total])',                         expect: 'Avg([Order Total])' },
  { id: 'D-4', sql: 'SUM([Gross Profit]) / SUM([Net Revenue])',   expect: 'Sum([Gross Profit]) / Sum([Net Revenue])' },
  { id: 'D-5', sql: "CASE WHEN [Status] = 'Active' THEN 1 ELSE 0 END",
    expect: 'If([Status] = "Active", 1, 0)' },
  { id: 'D-6', sql: 'MAX([Order Date])',                          expect: 'Max([Order Date])' },
  { id: 'D-7', sql: 'MIN([Order Date])',                          expect: 'Min([Order Date])' },
  { id: 'D-8', sql: 'ROUND([Margin Pct], 2)',                     expect: 'Round([Margin Pct], 2)' },
  { id: 'D-9', sql: "DATEDIFF('day', [Order Date], [Ship Date])", expect: 'DateDiff("day", [Order Date], [Ship Date])' },
  { id: 'D-10', sql: 'COALESCE([Discount], 0)',                   expect: 'Coalesce([Discount], 0)' },
]
# NOTE (converted:false expected): the vendored converter has no Sigma mapping
# for LIKE/BETWEEN — this is intentional, not a bug (see design doc's Error
# Handling section). Locks the honesty signal itself, not a translation.
RESIDUAL_FIXTURES = [
  { id: 'D-R1', sql: "LOWER([Country]) LIKE 'usa'" },
  { id: 'D-R2', sql: '[Order Total] BETWEEN 100 AND 500' },
]

puts 'Accuracy fixtures — vendored converter/sql.mjs'
abort "FATAL: vendored converter missing at #{VENDORED} — run tools/vendor-converters.sh <mcp-clone> domo" \
  unless File.exist?(VENDORED)
bundle = File.read(VENDORED, encoding: 'utf-8')

# Symbol-count guard — UNCONDITIONAL, runs even without node. A re-vendor that
# drops or renames any of these 5 exports must hard-abort, never silently skip
# every fixture below.
NEEDED = %w[lookSqlToSigmaRules lookConvertExpression hasResidualCaseKeyword hasResidualInfixOperator lookUnknownFunctions]
missing = NEEDED.reject { |name| bundle.match?(/\b#{Regexp.escape(name)}\b/) }
abort "converter fixture harness: converter/sql.mjs is missing expected export(s): #{missing.join(', ')} " \
      '— the re-vendor dropped/renamed a needed function; update test-convert-beast-modes-fixtures.rb ' \
      'or investigate the upstream change.' unless missing.empty?

node_present = begin
  _o, _e, st = Open3.capture3('node', '--version')
  st.success?
rescue Errno::ENOENT
  false
end

if node_present
  Dir.mktmpdir('domo-conv-fixtures') do |dir|
    fx_path  = File.join(dir, 'fixtures.json')
    res_path = File.join(dir, 'results.json')
    all_fixtures = FIXTURES + RESIDUAL_FIXTURES
    File.write(fx_path, JSON.generate(all_fixtures.map { |x| { 'id' => x[:id], 'sql' => x[:sql] } }))

    import_specifier = Gem.win_platform? && VENDORED.match?(/\A[A-Za-z]:/) ? 'file:///' + VENDORED.gsub('\\', '/') : VENDORED
    runner = File.join(dir, 'run.mjs')
    File.write(runner, <<~JS)
      import { readFileSync, writeFileSync } from 'node:fs';
      import { lookSqlToSigmaRules, lookConvertExpression, hasResidualCaseKeyword, hasResidualInfixOperator } from #{import_specifier.to_json};
      const fixtures = JSON.parse(readFileSync(#{fx_path.to_json}, 'utf8'));
      const out = fixtures.map(({ id, sql }) => {
        let sigmaFormula = lookSqlToSigmaRules(sql);
        if (sigmaFormula == null) sigmaFormula = lookConvertExpression(sql);
        const converted = !hasResidualCaseKeyword(sigmaFormula) && !hasResidualInfixOperator(sigmaFormula);
        return { id, sigmaFormula, converted };
      });
      writeFileSync(#{res_path.to_json}, JSON.stringify(out));
    JS

    _o, e, st = Open3.capture3('node', runner)
    if !st.success?
      warn "FAIL — node fixture runner failed:\n#{e}"
      exit 1
    end

    rows = JSON.parse(File.read(res_path, encoding: 'utf-8'))
    by_id = {}
    rows.each { |r| by_id[r['id']] = r }

    FIXTURES.each do |fx|
      r = by_id[fx[:id]]
      check(r && r['sigmaFormula'] == fx[:expect] && r['converted'] == true,
            "#{fx[:id]}  #{fx[:sql].inspect} → #{fx[:expect].inspect} (converted:true)", fails)
    end

    RESIDUAL_FIXTURES.each do |fx|
      r = by_id[fx[:id]]
      check(r && !r['sigmaFormula'].to_s.empty? && r['converted'] == false,
            "#{fx[:id]}  #{fx[:sql].inspect} → present-but-converted:false (honest residual-LIKE/BETWEEN signal)", fails)
    end
  end
else
  warn '  WARN  node not found on PATH — accuracy fixtures SKIPPED ' \
       "(#{FIXTURES.size + RESIDUAL_FIXTURES.size} fixtures unexercised). " \
       'Install node (doctor.sh enforces it for the converter path) to run them.'
end

puts
if fails.empty?
  puts 'ALL PASS'
  exit 0
else
  puts "#{fails.size} FAILURE(S):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
```

- [ ] **Step 2: Run it and confirm the expected outcome**

Run: `ruby plugins/domo-to-sigma/skills/domo-to-sigma/test/test-convert-beast-modes-fixtures.rb`
Expected: `ALL PASS`, exit 0 (assuming Task 1's bundle is present and `node` is on
PATH). If any `D-*` fixture FAILs, that's a real, measured translation gap in the
vendored converter for that SQL shape — do not silently loosen the assertion;
either the fixture's expected string is wrong (fix the fixture) or the converter
genuinely doesn't handle that shape yet (document it as a known gap in
`refs/beast-mode-to-sigma.md`, matching how CEILING/FLOOR/WEEKDAY gaps are already
documented there).

- [ ] **Step 3: Commit**

```bash
git add plugins/domo-to-sigma/skills/domo-to-sigma/test/test-convert-beast-modes-fixtures.rb
git commit -m "domo-to-sigma: add converter/sql.mjs accuracy fixture suite (Track E, 3/4)"
```

---

### Task 4: Wire `migrate-domo.rb`, update docs, bump plugin version, final verification

**Files:**
- Modify: `plugins/domo-to-sigma/skills/domo-to-sigma/scripts/migrate-domo.rb:372-397`
- Modify: `plugins/domo-to-sigma/skills/domo-to-sigma/SKILL.md:322-328`
- Modify: `plugins/domo-to-sigma/skills/domo-to-sigma/refs/beast-mode-to-sigma.md:1-30,243-253`
- Modify: `plugins/domo-to-sigma/.claude-plugin/plugin.json`

**Interfaces:**
- Consumes: Task 2's `convert-beast-modes.rb --convert` (exit codes 0/10/other,
  and that it fills `sigmaFormula`/`converted`/`warnings`/`note` per pending entry).
- Produces: nothing consumed by later tasks — this is the final integration task.

- [ ] **Step 1: Wire `migrate-domo.rb`'s `phase_convert_beast_modes!`**

Find (`plugins/domo-to-sigma/skills/domo-to-sigma/scripts/migrate-domo.rb`, the body
of `phase_convert_beast_modes!` after the normalize step):

```ruby
  ok, code, _out = run_script!('convert-beast-modes.rb')
  fail_phase!('convert-beast-modes', "normalize step exited #{code}") unless ok

  pending_path = File.join(DISCOVERY, 'formulas.pending.json')
  pending = begin
    JSON.parse(File.read(pending_path))
  rescue StandardError
    []
  end
  unresolved = pending.count { |e| e['sigmaFormula'].nil? || e['sigmaFormula'].to_s.strip.empty? }
  if unresolved.positive?
    log "NOTE: #{unresolved} Beast Mode(s) still lack a sigmaFormula — normally filled by calling " \
        'convert_sql_to_sigma_formula per pending entry (see the script header) before --lint. ' \
        'Running --lint now anyway: unresolved entries are DROPPED from formulas.json (never shipped ' \
        'silently as-is), so this phase is only fully complete once formulas.pending.json is filled in ' \
        'and re-linted.'
  end

  ok, code, _out = run_script!('convert-beast-modes.rb', '--lint')
  fail_phase!('convert-beast-modes', "--lint step exited #{code}") unless ok

  if unresolved.positive?
    done_phase!('convert-beast-modes', "#{unresolved} Beast Mode(s) unresolved — see discovery/formulas.pending.json")
  else
    done_phase!('convert-beast-modes')
  end
end
```

Replace with:

```ruby
  ok, code, _out = run_script!('convert-beast-modes.rb')
  fail_phase!('convert-beast-modes', "normalize step exited #{code}") unless ok

  ok, code, _out = run_script!('convert-beast-modes.rb', '--convert')
  if !ok && code == 10
    fail_phase!('convert-beast-modes',
                'no vendored converter/sql.mjs and no --mcp-dir/DOMO_MCP_DIR — re-run ' \
                "'ruby scripts/convert-beast-modes.rb --convert' directly to see the manual " \
                'convert_sql_to_sigma_formula + --converter-out fallback instructions')
  end
  fail_phase!('convert-beast-modes', "--convert step exited #{code}") unless ok

  pending_path = File.join(DISCOVERY, 'formulas.pending.json')
  pending = begin
    JSON.parse(File.read(pending_path))
  rescue StandardError
    []
  end
  unresolved = pending.count { |e| e['sigmaFormula'].nil? || e['sigmaFormula'].to_s.strip.empty? }
  unreliable = pending.count { |e| e['converted'] == false }
  if unresolved.positive?
    log "NOTE: #{unresolved} Beast Mode(s) still lack a sigmaFormula after --convert — unexpected " \
        '(lookConvertExpression is a total fallback that never returns nil); check ' \
        "convert-beast-modes.rb --convert's stderr output above."
  end
  if unreliable.positive?
    log "NOTE: #{unreliable} Beast Mode(s) flagged converted:false by --convert — has a sigmaFormula " \
        '(never silently dropped) but still contains untranslated CASE/WHEN/THEN or an infix ' \
        'LIKE/BETWEEN; review before shipping (discovery/formula-overrides.json can supply a ' \
        'hand-authored replacement).'
  end

  ok, code, _out = run_script!('convert-beast-modes.rb', '--lint')
  fail_phase!('convert-beast-modes', "--lint step exited #{code}") unless ok

  if unresolved.positive? || unreliable.positive?
    done_phase!('convert-beast-modes',
                "#{unresolved} unresolved, #{unreliable} unreliable (converted:false) — see " \
                'discovery/formulas.pending.json')
  else
    done_phase!('convert-beast-modes')
  end
end
```

- [ ] **Step 2: Update `SKILL.md`'s Phase 2 section**

Find (`plugins/domo-to-sigma/skills/domo-to-sigma/SKILL.md`, around line 322):

```markdown
## Phase 2 — Translate Beast Modes

`ruby scripts/convert-beast-modes.rb` → feeds each Beast Mode SQL string through
`convert_sql_to_sigma_formula`. Apply the normalizations in
`refs/beast-mode-to-sigma.md` FIRST (strip backticks, `WEEKDAY`→`DAYOFWEEK`,
flag aggregate `CEILING`/`FLOOR`, reject unsupported `SQRT`/`CONVERT_TZ`).
Outputs `discovery/formulas.json` (Beast Mode id → Sigma formula).
```

Replace with:

```markdown
## Phase 2 — Translate Beast Modes

Three scripted steps, no agent/MCP call in the loop (`migrate-domo.rb` runs all
three automatically):
```bash
ruby scripts/convert-beast-modes.rb            # normalize → discovery/formulas.pending.json
ruby scripts/convert-beast-modes.rb --convert  # vendored converter/sql.mjs fills sigmaFormula/converted/warnings, locally via node
ruby scripts/convert-beast-modes.rb --lint     # validate → discovery/formulas.json
```
`--convert` resolves the converter via a 3-tier ladder: the vendored bundle
(default, no MCP/network), a local `sigma-data-model-mcp` build via
`--mcp-dir`/`DOMO_MCP_DIR` (explicit dev opt-in only), or — last resort, bundle
and `node` both absent — exit 10 with the manual `convert_sql_to_sigma_formula`
+ `--converter-out` fallback instructions. Applies the normalizations in
`refs/beast-mode-to-sigma.md` FIRST (strip backticks, `WEEKDAY`→`DAYOFWEEK`,
flag aggregate `CEILING`/`FLOOR`, reject unsupported `SQRT`/`CONVERT_TZ`).
Outputs `discovery/formulas.json` (Beast Mode id → Sigma formula).
```

- [ ] **Step 3: Update `refs/beast-mode-to-sigma.md`'s intro section**

Find (around line 1-22):

```markdown
# Beast Mode → Sigma formula mapping

Beast Mode is **MySQL-dialect SQL**. The primary translation path is the existing
`mcp__sigma-data-model__convert_sql_to_sigma_formula` tool — feed it the Beast
Mode string and it emits a Sigma formula. This doc is the **pre-processing +
verification layer**: normalizations to apply first, the function-by-function map
to sanity-check the converter's output, and the gotchas that the generic SQL
converter won't know are Domo-specific.

Source of truth: Domo "Beast Mode Functions Reference Guide" (captured 2026-06-02).

---

## Translation is delegated — this ref is the Domo-specific wrapper

The actual SQL→Sigma translation runs through the
`mcp__sigma-data-model__convert_sql_to_sigma_formula` MCP tool — it is the
**single source of truth** and already handles `CASE WHEN`, `IN` lists,
`DATEDIFF`, arithmetic, and `snake_case` → `[Title Case]` column references.
Don't re-implement those. This ref is the **Domo-specific PRE-normalization +
POST-lint** layer that `scripts/convert-beast-modes.rb` implements around that
call.
```

Replace with:

```markdown
# Beast Mode → Sigma formula mapping

Beast Mode is **MySQL-dialect SQL**. The primary translation path is the vendored
`converter/sql.mjs` (`scripts/convert-beast-modes.rb --convert`, running locally
via `node` — no MCP call, no network; see Track E,
`docs/superpowers/specs/2026-08-03-domo-sql-formula-vendoring-design.md`). This
doc is the **pre-processing + verification layer**: normalizations to apply
first, the function-by-function map to sanity-check the converter's output, and
the gotchas that the generic SQL converter won't know are Domo-specific.

Source of truth: Domo "Beast Mode Functions Reference Guide" (captured 2026-06-02).

---

## Translation is delegated — this ref is the Domo-specific wrapper

The actual SQL→Sigma translation runs through the vendored `converter/sql.mjs`
(`lookSqlToSigmaRules`/`lookConvertExpression`, re-vendored periodically from
`sigma-data-model-mcp`'s `src/formulas.ts` — same functions the
`convert_sql_to_sigma_formula` MCP tool itself calls) — it is the **single
source of truth** and already handles `CASE WHEN`, `IN` lists, `DATEDIFF`,
arithmetic, and `snake_case` → `[Title Case]` column references. Don't
re-implement those. This ref is the **Domo-specific PRE-normalization +
POST-lint** layer that `scripts/convert-beast-modes.rb` implements around that
call.
```

- [ ] **Step 4: Update `refs/beast-mode-to-sigma.md`'s "Translation workflow" section**

Find (around line 243-253):

```markdown
## Translation workflow (per Beast Mode)

1. Normalize (backticks, WEEKDAY, unsupported, aggregate CEILING/FLOOR, context).
2. Call `convert_sql_to_sigma_formula` with the normalized string.
3. Cross-check the result against the tables above; apply the Domo-specific
   gotchas the generic SQL converter misses (CEILING/FLOOR aggregates, `IN`→`or`,
   `DATEDIFF` arg order, format-specifier translation).
4. Validate the column posts without an error type (`diagnose_sigma_save_error`
   if it fails; remember `*Over` window-function limits per
   `feedback_sigma_window_functions`).
```

Replace with:

```markdown
## Translation workflow (per Beast Mode)

1. Normalize (backticks, WEEKDAY, unsupported, aggregate CEILING/FLOOR, context).
2. `ruby scripts/convert-beast-modes.rb --convert` runs the vendored
   `converter/sql.mjs` against every normalized string in one local `node`
   invocation (no MCP call).
3. Cross-check the result against the tables above; apply the Domo-specific
   gotchas the generic SQL converter misses (CEILING/FLOOR aggregates, `IN`→`or`,
   `DATEDIFF` arg order, format-specifier translation).
4. Validate the column posts without an error type (`diagnose_sigma_save_error`
   if it fails; remember `*Over` window-function limits per
   `feedback_sigma_window_functions`).
```

- [ ] **Step 5: Bump the plugin version**

Read `plugins/domo-to-sigma/.claude-plugin/plugin.json`, find the `"version"`
field (currently `"0.9.0"`), bump it to `"0.10.0"` (minor — new capability/behavior
change, no breaking interface change to anything external).

- [ ] **Step 6: Run the full domo test suite**

```bash
ruby plugins/domo-to-sigma/skills/domo-to-sigma/test/test-convert-beast-modes.rb
ruby plugins/domo-to-sigma/skills/domo-to-sigma/test/test-convert-beast-modes-fixtures.rb
bash plugins/domo-to-sigma/skills/domo-to-sigma/test/run-all.sh   # if present — run domo's full offline suite
```

Expected: `ALL PASS` / exit 0 on every suite; no new failures relative to the
pre-existing baseline (this repo's convention is "no NEW failures," not
necessarily zero across the whole monorepo — see the Environment section of
`project_domo_live_validation` memory for known pre-existing unrelated failures
elsewhere in the tree).

- [ ] **Step 7: Run the repo-wide gates**

```bash
ruby tools/check-shared.rb
ruby tools/vendor-converters.sh --help 2>/dev/null; bash -n tools/vendor-converters.sh
ruby tools/check-plugin-version-bump.sh "$(git merge-base origin/main HEAD)" HEAD
```

Expected: all exit 0. (These also run as pre-commit hooks in this repo per prior
sessions' experience — if a commit in this task fails a hygiene/lint gate, fix
and recommit rather than bypassing with `--no-verify`.)

- [ ] **Step 8: Commit**

```bash
git add plugins/domo-to-sigma/skills/domo-to-sigma/scripts/migrate-domo.rb \
        plugins/domo-to-sigma/skills/domo-to-sigma/SKILL.md \
        plugins/domo-to-sigma/skills/domo-to-sigma/refs/beast-mode-to-sigma.md \
        plugins/domo-to-sigma/.claude-plugin/plugin.json
git commit -m "domo-to-sigma: wire --convert into migrate-domo.rb, update docs, bump 0.9.0→0.10.0 (Track E, 4/4)"
```

---

## After this plan: live E2E validation (not part of this plan's task list)

Once all 4 tasks are implemented, reviewed, and merged via PR, re-run the same bar
Tracks A/B/C already established against a real Domo instance: `migrate-domo.rb`
end-to-end on a live page, `assert-phase6-ran.rb` exit 0, honest waiver-budget
tracking, orphan cleanup. This is a separate live-credentialed session step (see
the design doc's "Live E2E validation" section), not an offline-testable task —
intentionally excluded from this plan's task list per the brainstorming design.
