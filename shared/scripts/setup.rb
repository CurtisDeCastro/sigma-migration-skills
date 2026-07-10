#!/usr/bin/env ruby
# Store Sigma credentials so any coding agent can load them:
#   - ~/.claude/settings.json   — Claude Code auto-loads this into the env
#   - ~/.sigma-migration/env    — neutral, sourceable file every other agent
#                                 (Cursor, Cortex Code, plain shell) can use
# get-token.sh and lib/sigma_rest.rb fall back to the neutral file when the
# env vars aren't already set, so the skill works under any agent.
#
# THE USER RUNS THIS ONCE, in a real terminal. Two modes:
#   * interactive (a TTY): prompts for each value (secret hidden), OR
#   * flags (no TTY / automation):
#       ruby scripts/setup.rb --client-id <id> --client-secret <secret> \
#         [--base-url https://aws-api.sigmacomputing.com] [--connection-id <uuid>]
# When stdin is NOT a TTY (agent harness, piped run) and the required values
# were not passed as flags, this prints the exact flag invocation and exits 2
# instead of hanging forever on a prompt nobody can answer.

require 'io/console'
require 'json'
require 'fileutils'
require 'optparse'

SETTINGS_PATH = File.expand_path("~/.claude/settings.json")
NEUTRAL_PATH  = File.expand_path("~/.sigma-migration/env")
DEFAULT_BASE  = "https://aws-api.sigmacomputing.com"

flags = {}
OptionParser.new do |p|
  p.banner = "usage: ruby scripts/setup.rb [--client-id ID --client-secret SECRET] " \
             "[--base-url URL] [--connection-id UUID]"
  p.on('--base-url URL',       "Sigma API base URL (default: #{DEFAULT_BASE})") { |v| flags[:base] = v }
  p.on('--client-id ID',       'Sigma API client id (not a secret)')            { |v| flags[:cid]  = v }
  p.on('--client-secret SEC',  'Sigma API client secret')                       { |v| flags[:sec]  = v }
  p.on('--connection-id UUID', 'full warehouse-connection UUID (optional)')     { |v| flags[:conn] = v }
  p.on('-h', '--help') { puts p; exit 0 }
end.parse!

# Upsert `export KEY='value'` lines into the neutral cred file (0600), preserving
# any other vars already there (e.g. Tableau creds from setup-tableau.rb).
def upsert_neutral_env(pairs)
  FileUtils.mkdir_p(File.dirname(NEUTRAL_PATH), mode: 0o700)
  body = File.exist?(NEUTRAL_PATH) ? File.read(NEUTRAL_PATH) : ""
  pairs.each do |k, v|
    line = "export #{k}='#{v}'"
    if body =~ /^export #{Regexp.escape(k)}=.*$/
      body = body.sub(/^export #{Regexp.escape(k)}=.*$/, line)
    else
      body += "\n" unless body.empty? || body.end_with?("\n")
      body += line + "\n"
    end
  end
  File.write(NEUTRAL_PATH, body)
  File.chmod(0o600, NEUTRAL_PATH)
end

puts "Sigma credential setup — the user runs this ONCE (interactive or via flags)."
puts "Values are stored in #{SETTINGS_PATH} and loaded automatically into every Claude Code session."
puts

interactive = $stdin.tty?
need_prompt = flags[:cid].to_s.empty? || flags[:sec].to_s.empty?

if need_prompt && !interactive
  # No TTY and no flags: NEVER hang on gets — print the exact invocation instead.
  warn 'ERROR: stdin is not a TTY, so the interactive prompts cannot run — and'
  warn '--client-id/--client-secret were not passed. Run it non-interactively:'
  warn ''
  warn '  ruby scripts/setup.rb \\'
  warn "    --client-id <SIGMA_CLIENT_ID> --client-secret '<SIGMA_CLIENT_SECRET>' \\"
  warn "    [--base-url #{DEFAULT_BASE}] [--connection-id <uuid>]"
  warn ''
  warn '…or run it once from a real terminal (it will prompt). Never inline the'
  warn 'secret into a shared command log — prefer the interactive prompt when a'
  warn 'human is present.'
  exit 2
end

base = flags[:base].to_s
cid  = flags[:cid].to_s
sec  = flags[:sec].to_s
conn = flags[:conn].to_s

if need_prompt
  if base.empty?
    print "Base URL [#{DEFAULT_BASE}]: "
    base = $stdin.gets.chomp
  end
  # Client ID is NOT a secret — echo it so the reader can eyeball it. A hidden
  # (noecho) prompt here was a recurring quickstart confusion: people paste the
  # wrong value blind and only discover it when auth fails.
  if cid.empty?
    print "Client ID (not a secret — will echo): "
    cid = $stdin.gets.chomp
  end
  if sec.empty?
    print "Client Secret (hidden): "
    sec = $stdin.noecho(&:gets).chomp
    puts
  end
end
base = DEFAULT_BASE if base.empty?

if [base, cid, sec].any?(&:empty?)
  abort "Base URL, Client ID, and Client Secret are all required. Aborting without writing settings."
end

# The one-command orchestrators (migrate-looker.py, migrate-qlik.rb, ...) need
# the FULL warehouse-connection UUID for DM conversion. Capturing it here (when
# known) saves an export step on every run. Optional — Enter to skip.
if conn.empty? && need_prompt
  print "Connection ID (full warehouse-connection UUID, optional — Enter to skip): "
  conn = $stdin.gets.chomp
end

settings = File.exist?(SETTINGS_PATH) ? JSON.parse(File.read(SETTINGS_PATH)) : {}
settings["env"] ||= {}
settings["env"]["SIGMA_BASE_URL"]      = base
settings["env"]["SIGMA_CLIENT_ID"]     = cid
settings["env"]["SIGMA_CLIENT_SECRET"] = sec
settings["env"]["SIGMA_CONNECTION_ID"] = conn unless conn.empty?

FileUtils.mkdir_p(File.dirname(SETTINGS_PATH))
File.write(SETTINGS_PATH, JSON.pretty_generate(settings))

pairs = {
  "SIGMA_BASE_URL"      => base,
  "SIGMA_CLIENT_ID"     => cid,
  "SIGMA_CLIENT_SECRET" => sec,
}
pairs["SIGMA_CONNECTION_ID"] = conn unless conn.empty?
upsert_neutral_env(pairs)

redacted_secret = sec.length > 8 ? "#{sec[0..3]}…#{sec[-4..]} (#{sec.length} chars)" : "(#{sec.length} chars)"

puts
puts "Credentials saved to:"
puts "  #{SETTINGS_PATH}  (Claude Code auto-loads this)"
puts "  #{NEUTRAL_PATH}  (any other agent / shell)"
puts
puts "  SIGMA_BASE_URL:      #{base}"
puts "  SIGMA_CLIENT_ID:     #{cid}"
puts "  SIGMA_CLIENT_SECRET: #{redacted_secret}"
puts "  SIGMA_CONNECTION_ID: #{conn.empty? ? '(skipped)' : conn}"
puts
puts "If the Client ID above looks like a URL or doesn't match what Sigma showed you, re-run this script."
puts "Claude Code: open a new session (or run `! source ~/.claude/settings.json`)."
puts "Other agents / shell: run `source ~/.sigma-migration/env` once per shell —"
puts "though get-token.sh and the Ruby scripts auto-source it for you."
