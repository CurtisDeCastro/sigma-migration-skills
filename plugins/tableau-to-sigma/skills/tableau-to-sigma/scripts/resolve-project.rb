#!/usr/bin/env ruby
# frozen_string_literal: true
#
# resolve-project.rb — resolve a numeric Tableau *vizportal* project id (the
# `/projects/<N>` number in a Tableau Cloud/Server URL) to the project's REAL
# identity (LUID + name + contents), WITHOUT guessing.
#
# WHY THIS EXISTS (field failure, 2026-07): given a URL like
# `.../#/site/<site>/projects/1234567`, an agent noticed the REST API doesn't
# expose that numeric id, poked at GraphQL for a while, then GUESSED the target
# project from name/recency — wrong — and spent the whole session migrating the
# wrong content. The numeric id is a *vizportal URL id*: REST "Query Projects"
# returns ONLY luid (`id`), name, description, parentProjectId, owner, and
# contentCounts — no numeric id, so no REST call can resolve it. The Metadata
# API (GraphQL) CAN: `Workbook.projectVizportalUrlId` is "the ID of the project
# in which the workbook is visible", alongside `projectLuid`/`projectName`.
#
# HOW: query every workbook's (and, schema permitting, every published
# datasource's) project fields, group by projectVizportalUrlId, and look up the
# URL's number. Exact match → the project's luid/name/contents. No match (the
# project is empty, or the Metadata API is disabled on a self-hosted Server) →
# there is NO way to resolve the number: exit 2 with a candidates table from
# REST Query Projects. Present the candidates to the user and ASK — never
# assume. A wrong project guess invalidates an entire migration run.
#
# Usage:
#   ruby scripts/resolve-project.rb --url "https://prod-useast-b.online.tableau.com/#/site/examplecorp/projects/1234567"
#   ruby scripts/resolve-project.rb --vizportal-id 1234567 [--out <path>.json]
#
# Exit codes:
#   0 — resolved; JSON printed (and written to --out when given):
#       {vizportal_id, project_luid, project_name, workbooks: [{luid,name}],
#        datasources: [{luid,name}]}
#   2 — could not resolve (no such vizportal id in the metadata graph, empty
#       project, Metadata API disabled, or bad/unparseable arguments). Prints
#       the CANDIDATES table (name, luid, content counts) — present it to the
#       user and ask which project. NEVER assume.
#   3 — auth/transport failure (bad creds, unreachable server) + remediation.
#
# Offline testing: --fixture-graphql / --fixture-rest inject canned responses
# (see scripts/test-resolve-project.rb) so the resolver logic is testable with
# no credentials and no network. Live calls happen only in the CLI block below.

require 'json'
require 'optparse'
require 'fileutils'
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'tableau_rest'

module ResolveProject
  # Metadata API (GraphQL) — the ONLY API that carries the vizportal URL id.
  # Same transport as extract-calc-fields.rb (POST /api/metadata/graphql via
  # Tableau.graphql).
  WORKBOOKS_QUERY   = '{ workbooks { luid name projectVizportalUrlId projectLuid projectName } }'
  DATASOURCES_QUERY = '{ publishedDatasources { luid name projectVizportalUrlId projectLuid projectName } }'

  module_function

  # Pull the numeric project id out of a Tableau URL. Handles the common
  # spellings:
  #   .../#/site/<site>/projects/1234567
  #   .../#/site/<site>/projects/1234567/workbooks     (trailing segments)
  #   .../#/projects/1234567?order=name                (default site + query)
  # Returns the id as a String, or nil when the URL carries no /projects/<N>.
  def parse_vizportal_id(url)
    m = url.to_s.match(%r{/projects/(\d+)(?:[/?#]|$)})
    m && m[1]
  end

  # Group Metadata-API rows by projectVizportalUrlId. Rows are the GraphQL
  # `workbooks` / `publishedDatasources` arrays; each carries
  # projectVizportalUrlId / projectLuid / projectName. Ids are canonicalized
  # to String (the API has returned both String and Int shapes).
  # Returns { "<vid>" => {vizportal_id:, project_luid:, project_name:,
  #                       workbooks: [{luid:,name:}], datasources: [...]} }
  def group_by_project(workbooks, datasources = [])
    groups = {}
    add = lambda do |row, bucket|
      vid = row['projectVizportalUrlId']
      next if vid.nil? || vid.to_s.strip.empty?
      key = vid.to_s
      g = (groups[key] ||= { vizportal_id: key, project_luid: row['projectLuid'],
                             project_name: row['projectName'],
                             workbooks: [], datasources: [] })
      g[:project_luid] ||= row['projectLuid']
      g[:project_name] ||= row['projectName']
      g[bucket] << { luid: row['luid'], name: row['name'] }
    end
    (workbooks || []).each { |r| add.call(r, :workbooks) }
    (datasources || []).each { |r| add.call(r, :datasources) }
    groups
  end

  # Exact-match lookup. Returns the group Hash or nil.
  def resolve(groups, vizportal_id)
    groups[vizportal_id.to_s]
  end

  # Flatten a REST "Query Projects" response page into candidate rows
  # [{name:, luid:, workbooks:, datasources:, description:}]. contentCounts is
  # only present when the REST call requested it (fields=_all_); missing counts
  # render as nil ("?" in the table).
  def candidate_rows(projects_response)
    list = projects_response.dig('projects', 'project') || []
    list = [list] unless list.is_a?(Array)
    list.map do |p|
      counts = p['contentCounts'] || {}
      { name: p['name'], luid: p['id'],
        workbooks: counts['workbookCount']&.to_i,
        datasources: counts['datasourceCount']&.to_i,
        description: p['description'] }
    end
  end

  def format_candidates_table(rows)
    out = +"CANDIDATE PROJECTS (REST Query Projects — REST has NO numeric/vizportal id, so this list cannot be matched to the URL automatically):\n"
    out << format("  %-40s %-38s %9s %11s\n", 'NAME', 'LUID', 'WORKBOOKS', 'DATASOURCES')
    rows.each do |r|
      out << format("  %-40s %-38s %9s %11s\n",
                    r[:name].to_s[0, 40], r[:luid], r[:workbooks] || '?', r[:datasources] || '?')
    end
    out << "\n"
    out << "⛔ DO NOT GUESS. Present these candidates to the user and ask which project\n"
    out << "   they meant — NEVER assume from name or recency. A wrong project guess\n"
    out << "   invalidates the entire migration run.\n"
    out
  end
end

# ---- CLI (live paths guarded here — nothing above touches the network) -----
if $PROGRAM_NAME == __FILE__
  opts = {}
  parser = OptionParser.new do |p|
    p.banner = 'usage: ruby scripts/resolve-project.rb --url "<tableau url>" | --vizportal-id N [--out <path>.json]'
    p.on('--url URL', 'Full Tableau URL containing /projects/<N>') { |v| opts[:url] = v }
    p.on('--vizportal-id N', 'The numeric project id directly') { |v| opts[:vizportal_id] = v }
    p.on('--out PATH', 'Write the resolved-project JSON here') { |v| opts[:out] = v }
    # Offline-test injection seams (no creds, no network) — used by
    # test-resolve-project.rb; not part of the operator surface.
    p.on('--fixture-graphql PATH') { |v| opts[:fixture_graphql] = v }
    p.on('--fixture-rest PATH')    { |v| opts[:fixture_rest] = v }
    p.on('-h', '--help') { puts p; exit 0 }
  end
  parser.parse!

  vid = opts[:vizportal_id] || ResolveProject.parse_vizportal_id(opts[:url])
  if vid.nil? || vid.to_s !~ /\A\d+\z/
    warn opts[:url] ? "ERROR: no numeric /projects/<id> segment found in URL: #{opts[:url]}" :
                      'ERROR: pass --url "<tableau url>" or --vizportal-id N'
    warn parser
    exit 2
  end

  # -- transport: fixtures (offline) or live Metadata API + REST ------------
  offline = opts[:fixture_graphql] || opts[:fixture_rest]
  wb_rows, ds_rows = [], []
  metadata_err = nil

  if opts[:fixture_graphql]
    fx = JSON.parse(File.read(opts[:fixture_graphql]))
    wb_rows = fx.dig('workbooks_response', 'data', 'workbooks') || []
    ds_rows = fx.dig('datasources_response', 'data', 'publishedDatasources') || []
  elsif !offline
    # Mint a Tableau token in-process (same pattern as migrate-tableau.rb's
    # tableau_env): PAT creds from env / ~/.sigma-migration/env; a pre-set
    # TABLEAU_AUTH_TOKEN is the fallback.
    begin
      Tableau.refresh_token!
    rescue Tableau::Error => e
      if ENV['TABLEAU_AUTH_TOKEN'].to_s.empty?
        warn "AUTH FAILURE: could not mint a Tableau token in-process: #{e.message}"
        warn '  Fix: run `ruby scripts/setup-tableau.rb` once (PAT setup), or set'
        warn '  TABLEAU_SERVER_URL / TABLEAU_SITE_CONTENT_URL / TABLEAU_PAT_NAME /'
        warn '  TABLEAU_PAT_SECRET (or a live TABLEAU_AUTH_TOKEN + TABLEAU_SITE_ID).'
        warn '  Do NOT hand-roll a signin curl — use the scripts.'
        exit 3
      end
    end

    begin
      resp = Tableau.graphql(ResolveProject::WORKBOOKS_QUERY)
      if resp.is_a?(Hash) && resp['errors'] && !resp['errors'].empty?
        metadata_err = "GraphQL errors: #{resp['errors'].inspect[0, 300]}"
      else
        wb_rows = resp.dig('data', 'workbooks') || []
      end
    rescue Tableau::Error => e
      # Metadata API disabled (404 on self-hosted Server) or otherwise
      # unavailable — degrade to the candidates path rather than crash.
      metadata_err = e.message.lines.first&.chomp
    end

    if metadata_err.nil?
      begin
        dresp = Tableau.graphql(ResolveProject::DATASOURCES_QUERY)
        if dresp.is_a?(Hash) && (dresp['errors'].nil? || dresp['errors'].empty?)
          ds_rows = dresp.dig('data', 'publishedDatasources') || []
        else
          warn 'NOTE: publishedDatasources does not expose the project fields on this schema — resolving from workbooks only.'
        end
      rescue Tableau::Error
        warn 'NOTE: publishedDatasources query failed — resolving from workbooks only.'
      end
    end
  end

  groups = ResolveProject.group_by_project(wb_rows, ds_rows)
  hit = ResolveProject.resolve(groups, vid)

  if hit
    puts "RESOLVED vizportal project id #{vid}:"
    puts "  project_name: #{hit[:project_name]}"
    puts "  project_luid: #{hit[:project_luid]}"
    puts "  workbooks:    #{hit[:workbooks].size}"
    hit[:workbooks].each { |w| puts "    - #{w[:name]} (#{w[:luid]})" }
    unless hit[:datasources].empty?
      puts "  datasources:  #{hit[:datasources].size}"
      hit[:datasources].each { |d| puts "    - #{d[:name]} (#{d[:luid]})" }
    end
    payload = JSON.pretty_generate(
      'vizportal_id' => vid.to_i,
      'project_luid' => hit[:project_luid],
      'project_name' => hit[:project_name],
      'workbooks' => hit[:workbooks].map { |w| { 'luid' => w[:luid], 'name' => w[:name] } },
      'datasources' => hit[:datasources].map { |d| { 'luid' => d[:luid], 'name' => d[:name] } }
    )
    if opts[:out]
      FileUtils.mkdir_p(File.dirname(opts[:out]))
      File.write(opts[:out], payload + "\n")
      puts "  wrote #{opts[:out]}"
    end
    puts payload
    exit 0
  end

  # -- no exact match → candidates table + STOP-AND-ASK (exit 2) ------------
  warn metadata_err ? "Metadata API unavailable (#{metadata_err}) — cannot resolve the numeric id at all." :
                      "No workbook/datasource in the metadata graph sits in a project with vizportal id #{vid} (empty project, or a stale link)."
  rows = []
  if opts[:fixture_rest]
    rows = ResolveProject.candidate_rows(JSON.parse(File.read(opts[:fixture_rest])))
  else
    begin
      page = 1
      loop do
        j = Tableau.request(:get, "#{Tableau.base_path}/projects?fields=_all_&pageSize=100&pageNumber=#{page}")
        rows.concat(ResolveProject.candidate_rows(j))
        total = j.dig('pagination', 'totalAvailable').to_i
        break if page * 100 >= total || (j.dig('projects', 'project') || []).empty?
        page += 1
      end
    rescue Tableau::Error => e
      warn "AUTH/TRANSPORT FAILURE listing projects via REST: #{e.message.lines.first&.chomp}"
      warn '  Fix: run `ruby scripts/setup-tableau.rb` once (PAT setup), then re-run.'
      exit 3
    end
  end

  warn ''
  warn ResolveProject.format_candidates_table(rows.sort_by { |r| r[:name].to_s.downcase })
  exit 2
end
