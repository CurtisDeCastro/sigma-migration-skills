#!/usr/bin/env ruby
# frozen_string_literal: true
#
# test_shared_script_closure.rb — structural guards on the shared fan-out
# (issue #539). Two live-caught failure modes, both invisible to every existing
# gate because each individual file was perfectly valid:
#
#  1. A GATE'S REMEDY SCRIPT WAS MISSING. assert-phase6-ran.rb is shared to 7
#     plugins and its gate 8b tells the operator to run
#     `ruby scripts/record-visual-check.rb …` — but that script shipped in only 2
#     of those 7. A live QuickSight migration could not satisfy its own mandatory
#     gate; the run had to borrow another plugin's copy, and the two existing
#     copies had DIFFERENT flag sets (looker's rejected --no-vision-waiver), so
#     the remedy's behaviour depended on which copy you happened to find.
#
#  2. A SHARED SCRIPT'S DEPENDENCY WASN'T FANNED OUT. Promoting that recorder to
#     shared/ fanned out the script but not the two libs it require_relative's
#     (lib/cli_encoding, lib/blind_grade — which existed only under tableau), so
#     every newly-created copy died on LoadError at startup. check-shared only
#     compares files that ARE registered; it cannot see a dependency that was
#     never registered at all. Static require-parsing is unreliable here
#     (requires can be conditional, and paths can be ../lib/…), so this asserts
#     the thing that actually matters: each copy LOADS.
#
# Offline, creds-free, no network (--help only; nothing is executed for real).
# Run: ruby shared/lib/test_shared_script_closure.rb
require 'json'
require 'open3'
require 'set'

ROOT = File.expand_path('../..', __dir__)
Dir.chdir(ROOT)

$fail = 0
def ok(desc); r = yield; puts "#{r ? '  ok  ' : ' FAIL '} #{desc}"; $fail += 1 unless r; end

MANIFEST = JSON.parse(File.read('shared/manifest.json'))
ENTRIES = MANIFEST['shared'].each_with_object({}) do |e, h|
  h[e['canonical']] = e['targets'].map { |t| t.is_a?(Hash) ? t['path'] : t }
end

# ── 1. Every registered fan-out target actually exists on disk. A registered
#       entry whose target file is absent means the fan-out never ran (or a
#       target path is a typo) — check-shared compares CONTENT and would report
#       a mismatch, but this states the simpler precondition outright.
missing_targets = ENTRIES.flat_map { |c, ts| ts.reject { |t| File.exist?(t) }.map { |t| "#{c} -> #{t}" } }
ok('every shared-manifest target file exists') do
  missing_targets.each { |m| warn "    MISSING #{m}" }
  missing_targets.empty?
end

# ── 2. Gate remedies ship with their gate. Parses `scripts/<name>.rb` out of a
#       shared assert-* gate's own operator-facing text and requires that any
#       such script which is ITSELF shared exists in every plugin the gate ships
#       to. (A plugin-private remedy is that plugin's own business.)
SHARED_BASENAMES = ENTRIES.keys.map { |c| File.basename(c) }.to_set
missing_remedies = []
ENTRIES.each do |gate, gate_targets|
  next unless File.basename(gate).start_with?('assert-') && gate.end_with?('.rb')
  next unless File.exist?(gate)
  remedies = File.read(gate).scan(%r{scripts/([a-z0-9_-]+\.rb)}).flatten.uniq
                            .select { |r| SHARED_BASENAMES.include?(r) }
  gate_targets.each do |t|
    remedies.each do |r|
      path = File.join(File.dirname(t), r)
      missing_remedies << "#{File.basename(gate)} in #{t.split('/')[1]} names scripts/#{r} — ABSENT there" unless File.exist?(path)
    end
  end
end
ok('every shared script a shared gate names as its remedy ships with that gate') do
  missing_remedies.each { |m| warn "    #{m}" }
  missing_remedies.empty?
end

# ── 3. Dependency closure, verified BEHAVIOURALLY: every fanned-out copy of a
#       shared entry-point script must load (no LoadError) in its own plugin.
#       This is the guard that catches a promoted script whose require_relative'd
#       libs were not registered alongside it.
CHECKABLE = ENTRIES.keys.select do |c|
  c.start_with?('shared/scripts/') && c.end_with?('.rb') &&
    File.read(c).include?('OptionParser')   # entry points that parse flags support --help
end
load_errors = []
CHECKABLE.each do |c|
  ENTRIES[c].each do |t|
    dir = File.dirname(t)
    _o, err, = Open3.capture3('ruby', File.basename(t), '--help', chdir: dir)
    next unless err.include?('LoadError')
    dep = err[/cannot load such file -- (\S+)/, 1].to_s
    load_errors << "#{t}: LoadError#{dep.empty? ? '' : " (#{File.basename(dep)})"}"
  end
end
ok('every fanned-out shared entry-point script LOADS in its plugin (deps travelled with it)') do
  load_errors.each { |m| warn "    #{m}" }
  load_errors.empty?
end

puts($fail.zero? ? "\nALL PASS — fan-out targets exist, gates ship their remedies, and every shared script loads with its deps" : "\n#{$fail} FAILURE(S)")
exit($fail.zero? ? 0 : 1)
