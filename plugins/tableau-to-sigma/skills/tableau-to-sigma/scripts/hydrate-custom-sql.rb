#!/usr/bin/env ruby
# Hydrate a published-datasource (sqlproxy) Tableau workbook so the converter can
# build a real Sigma data model from it.
#
# THE PROBLEM (see also extract-custom-sql.rb): when a workbook connects to a
# *published data source* via <connection class='sqlproxy' dbname='<PubDS>'>, the
# actual Custom SQL lives in the published data source object on Tableau Server —
# NOT in the .twb. The .twb carries only a placeholder relation (table='[sqlproxy]')
# plus cached column metadata. Fed to the converter as-is, that yields a 0-column
# element pointing at a non-existent "sqlproxy" table → POST "Source not found".
#
# THE FIX (approach A — embed, don't post-process): splice the retrieved Custom
# SQL into the datasource as a <relation type='text'> and present the connection
# as the real warehouse connection. The existing converter then emits a normal
# kind:'sql' element — reusing all its proven Custom-SQL shaping (column formulas,
# LOD/window helpers, the mixed-case identifier quoting fix), with ZERO new
# data-model-shaping code here.
#
# To keep the emitted SQL Snowflake-safe regardless of the source column casing,
# the Custom SQL is WRAPPED and its output columns projected with upper-snake
# aliases:  SELECT "Sales Region" AS SALES_REGION, ... FROM ( <original SQL> ) t
# and the cached <metadata-records> remote-names are rewritten to those aliases
# (captions preserved for display). This means every downstream reference (fact
# columns, LOD GROUP BY / helper subqueries) resolves against a bare upper-snake
# identifier, which is exactly what the converter and Sigma expect.
#
# Usage (CLI):
#   ruby scripts/hydrate-custom-sql.rb \
#     --twb /tmp/<name>/workbook-content.twb \
#     --custom-sql /tmp/<name>/custom-sql.json \
#     [--columns /tmp/<name>/probed-columns.json]  # {"<PubDS or caption>": ["col", ...]}
#     --db CSA --schema TJ \
#     --out /tmp/<name>/workbook-hydrated.twb
#
# The module (HydrateCustomSql) is pure/offline and unit-tested by
# test-hydrate-custom-sql.rb.

require 'json'
require 'optparse'
require 'rexml/document'

module HydrateCustomSql
  module_function

  # Upper-snake alias for a warehouse output column — mirrors the converter's
  # normalizeColumnName so the spliced metadata-record remote-names line up with
  # the SQL output identifiers the converter expects.
  def alias_for(name)
    name.to_s.gsub(/[^A-Za-z0-9]+/, '_').gsub(/\A_+|_+\z/, '').upcase
  end

  # Quote a source column reference only when it is NOT already a safe bare
  # identifier (has spaces / mixed case / punctuation / leading digit). Matches
  # the "only quote when needed" rule in the converter's identifier fix, so
  # already-uppercase columns pass through untouched.
  def quote_ref(name)
    a = alias_for(name)
    (name.to_s == a && name.to_s !~ /\A[0-9]/) ? name.to_s : %("#{name}")
  end

  # Wrap the original Custom SQL and project its output columns with upper-snake
  # aliases. The original query is preserved verbatim inside the subquery, so
  # arbitrarily complex SQL (joins, CTEs, expressions) is untouched.
  def wrap_sql(query, columns)
    raise ArgumentError, 'no output columns' if columns.nil? || columns.empty?
    proj = columns.map { |c| "#{quote_ref(c)} AS #{alias_for(c)}" }.join(', ')
    "SELECT #{proj} FROM (\n#{query.to_s.strip}\n) t"
  end

  # Quick check (cheap, offline): does this .twb have any top-level datasource on
  # a sqlproxy connection with no real relation? Used by the migrate orchestrator
  # to decide whether to run the (Tableau-token-requiring) hydration path at all.
  def twb_has_sqlproxy?(twb_path)
    return false unless File.exist?(twb_path)
    doc = REXML::Document.new(File.read(twb_path))
    doc.each_element('/workbook/datasources/datasource') do |ds|
      conn = ds.elements['connection']
      return true if conn && sqlproxy_connection?(conn) && !has_real_relation?(conn)
    end
    false
  rescue StandardError
    false
  end

  # A sqlproxy / published-datasource connection carries no real schema of its own.
  def sqlproxy_connection?(conn)
    return false unless conn
    (conn.attributes['class'].to_s == 'sqlproxy')
  end

  # Does this datasource already carry embedded Custom SQL or a real base table?
  # (If so we leave it alone — nothing to hydrate.)
  def has_real_relation?(conn)
    return false unless conn
    conn.each_element('.//relation') do |rel|
      type = (rel.attributes['type'] || 'table').to_s
      tbl  = rel.attributes['table'].to_s
      return true if type == 'text' && !rel.text.to_s.strip.empty?
      return true if type == 'table' && !tbl.empty? && tbl != '[sqlproxy]' && tbl != '[Extract].[Extract]'
    end
    false
  end

  # Column names cached in the datasource's own <metadata-records> (the published
  # DS's real column names, as Tableau saw them). Fallback when no probe was run.
  def cached_columns(conn)
    cols = []
    conn.each_element('.//metadata-records/metadata-record') do |mr|
      remote = (mr.get_text('remote-name')&.value || '').strip
      cols << remote unless remote.empty?
    end
    cols
  end

  # The published-datasource name this sqlproxy connection points at
  # (<connection dbname='<PubDS>'>) — the join key to a custom-sql.json block's
  # downstreamDatasources / name.
  def published_ds_name(conn)
    (conn.attributes['dbname'] || '').to_s
  end

  # Pick the Custom SQL query for a datasource from the extracted blocks.
  #   1. a block whose downstreamDatasources name matches the sqlproxy dbname
  #   2. a block whose own name matches the dbname / datasource caption
  #   3. if exactly one block exists overall, use it (unambiguous)
  # Returns [query, block] or [nil, nil].
  def query_for(conn, ds_caption, blocks)
    pub = published_ds_name(conn)
    want = [pub, ds_caption].map { |s| s.to_s.downcase }.reject(&:empty?)

    by_downstream = blocks.find do |b|
      (b['downstreamDatasources'] || []).any? { |d| want.include?(d['name'].to_s.downcase) }
    end
    return [by_downstream['query'], by_downstream] if by_downstream && by_downstream['query']

    by_name = blocks.find { |b| want.include?(b['name'].to_s.downcase) }
    return [by_name['query'], by_name] if by_name && by_name['query']

    with_sql = blocks.select { |b| !b['query'].to_s.strip.empty? }
    return [with_sql.first['query'], with_sql.first] if with_sql.size == 1

    [nil, nil]
  end

  # Rewrite one datasource's connection in place: swap the sqlproxy placeholder
  # for a <relation type='text'> carrying the wrapped SQL, present the connection
  # as the warehouse, and rewrite metadata-record remote-names to the aliases.
  # Returns true if hydrated.
  def hydrate_datasource!(ds, query:, columns:, db:, schema:, warehouse_class: 'snowflake')
    conn = ds.elements['connection']
    return false unless conn
    return false if query.to_s.strip.empty? || columns.nil? || columns.empty?

    wrapped = wrap_sql(query, columns)

    # Present as the real warehouse (the converter treats sqlproxy/extract
    # placeholders as no-schema; a concrete class + db/schema makes it a live source).
    conn.attributes['class'] = warehouse_class
    conn.attributes['dbname'] = db if db && !db.empty?
    conn.attributes['schema'] = schema if schema && !schema.empty?

    rel_name = conn.elements['.//relation']&.attributes&.[]('name') || ds.attributes['caption'] || 'CustomSQL'

    # Drop existing placeholder relations, insert the text relation.
    conn.elements.each('.//relation') { |r| r.parent.delete_element(r) }
    rel = REXML::Element.new('relation')
    rel.add_attribute('name', rel_name)
    rel.add_attribute('type', 'text')
    rel.text = wrapped
    conn.add_element(rel)
    # Keep <relation> ahead of <metadata-records> (canonical Tableau order).
    mr = conn.elements['metadata-records']
    conn.delete_element(rel) && conn.insert_before(mr, rel) if mr

    # Rewrite metadata-record remote-names to the upper-snake aliases so the
    # converter's fact columns resolve against the SQL output identifiers, while
    # the caption (display name) is preserved.
    conn.each_element('.//metadata-records/metadata-record') do |m|
      rn = m.get_text('remote-name')
      next unless rn
      m.elements['remote-name'].text = alias_for(rn.value.strip)
    end
    true
  end

  # Walk all top-level datasources; hydrate every sqlproxy one we can resolve.
  # columns_by_key: optional {published-ds-or-caption(downcased) => [col,...]} from a probe.
  # Returns an array of {caption, published_ds, columns, source} for reporting.
  def hydrate!(doc, blocks:, columns_by_key: {}, db:, schema:, warehouse_class: 'snowflake')
    hydrated = []
    doc.each_element('/workbook/datasources/datasource') do |ds|
      conn = ds.elements['connection']
      next unless conn
      next unless sqlproxy_connection?(conn)
      next if has_real_relation?(conn)

      caption = (ds.attributes['caption'] || '').to_s
      pub = published_ds_name(conn)
      query, _blk = query_for(conn, caption, blocks)
      next if query.to_s.strip.empty?

      key_probe = [pub.downcase, caption.downcase].find { |k| columns_by_key.key?(k) }
      columns = key_probe ? columns_by_key[key_probe] : cached_columns(conn)
      col_source = key_probe ? 'probe' : 'cached-metadata'
      next if columns.nil? || columns.empty?

      if hydrate_datasource!(ds, query: query, columns: columns, db: db, schema: schema,
                             warehouse_class: warehouse_class)
        hydrated << { 'caption' => caption, 'published_ds' => pub,
                      'columns' => columns.size, 'column_source' => col_source }
      end
    end
    hydrated
  end
end

# ── CLI ──────────────────────────────────────────────────────────────────────
if __FILE__ == $PROGRAM_NAME
  opts = {}
  OptionParser.new do |o|
    o.on('--twb PATH')         { |v| opts[:twb] = v }
    o.on('--custom-sql PATH')  { |v| opts[:csql] = v }
    o.on('--columns PATH')     { |v| opts[:cols] = v }
    o.on('--db NAME')          { |v| opts[:db] = v }
    o.on('--schema NAME')      { |v| opts[:schema] = v }
    o.on('--warehouse-class C'){ |v| opts[:wcls] = v }
    o.on('--out PATH')         { |v| opts[:out] = v }
  end.parse!
  abort 'usage: --twb PATH --custom-sql PATH --db DB --schema SCHEMA --out PATH [--columns PATH]' \
    unless opts[:twb] && opts[:csql] && opts[:out]

  blocks = JSON.parse(File.read(opts[:csql])) rescue []
  blocks = [] unless blocks.is_a?(Array)
  cols_by_key = {}
  if opts[:cols] && File.exist?(opts[:cols])
    (JSON.parse(File.read(opts[:cols])) rescue {}).each { |k, v| cols_by_key[k.to_s.downcase] = v }
  end

  doc = REXML::Document.new(File.read(opts[:twb]))
  hydrated = HydrateCustomSql.hydrate!(
    doc, blocks: blocks, columns_by_key: cols_by_key,
    db: opts[:db], schema: opts[:schema], warehouse_class: opts[:wcls] || 'snowflake'
  )

  if hydrated.empty?
    warn 'hydrate-custom-sql: no sqlproxy datasource could be hydrated (none found, or no matching Custom SQL / columns). .twb copied unchanged.'
    File.write(opts[:out], File.read(opts[:twb]))
  else
    File.open(opts[:out], 'w') { |f| doc.write(f) }
    hydrated.each do |h|
      warn "  hydrated datasource #{h['caption'].inspect} (published DS #{h['published_ds'].inspect}) " \
           "→ Custom SQL element, #{h['columns']} cols from #{h['column_source']}"
    end
  end
  puts "wrote #{opts[:out]} (#{hydrated.size} datasource(s) hydrated)"
end
