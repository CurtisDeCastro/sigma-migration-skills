# frozen_string_literal: true

# Domo DataSet -> {columns, rows} extraction, with explicit LIMIT/OFFSET
# pagination and a measured (not assumed) row-count parity check —
# powerbi-import-to-snowflake's /executeQueries had a silent ~48k-row
# truncation on a single unpaginated call (its refs/pagination.md); assume
# the same risk class here until measured otherwise on a live Domo instance.
#
# `query` is the network seam: (dataset_id, sql) -> Domo's query_dataset
# response Hash. Production callers (Task 5) pass Domo.method(:query_dataset);
# tests inject a stub — no live credentials needed to test pagination/parity.
#
# OPEN RISK (flagged in the design doc, confirm on the FIRST live run): Domo's
# documented /v1/datasets/query/execute/{id} response shape is
# {"columns" => [...], "rows" => [[...], ...], "numRows" => N} and `table` is
# the literal FROM-target keyword for this endpoint — domo_rest.rb's
# query_dataset has zero other call sites in this repo to confirm the exact
# dialect against before now. If a live call returns a different shape, fix
# row_count/extract_rows's parsing here, not by working around it in Task 5.
module DomoExtract
  class RowCountMismatch < StandardError; end

  module_function

  def row_count(dataset_id, query:)
    result = query.call(dataset_id, 'SELECT COUNT(*) FROM table')
    unless result.is_a?(Hash) && result['rows'].is_a?(Array) && !result['rows'].empty?
      raise "dataset #{dataset_id}: malformed COUNT(*) response (expected a non-empty 'rows' array): #{result.inspect}"
    end
    result['rows'].dig(0, 0).to_i
  end

  # Pulls every row via explicit LIMIT/OFFSET pages of `band_size`, so no
  # single call can silently truncate without this loop knowing (a page
  # shorter than band_size ends the loop; a full-length final page would
  # otherwise look identical to "more data exists"). Also captures type
  # metadata from the first page's response and builds schema_cols, the
  # authoritative column-name + type pairs for DDL, eliminating an unreliable
  # separate Domo.dataset(id)['schema'] lookup (which is empty for most real datasets).
  #
  # metadata is only required/validated on the FIRST page — that's the only
  # page whose metadata is ever consumed (types is captured once via `||=`
  # below), so requiring it on every later page would be over-strict. Without
  # this guard, a live response with 'columns' present but 'metadata' absent
  # or short would silently type every affected column nil -> VARCHAR with no
  # error and no skip, exactly the silent-schema-loss failure class this
  # metadata-derivation approach was meant to eliminate.
  def extract_rows(dataset_id, query:, band_size: 20_000)
    rows = []
    columns = nil
    types = nil
    offset = 0
    loop do
      page = query.call(dataset_id, "SELECT * FROM table LIMIT #{band_size} OFFSET #{offset}")
      unless page.is_a?(Hash) && page['rows'].is_a?(Array) && page['columns'].is_a?(Array)
        raise "dataset #{dataset_id}: malformed page response at offset #{offset} (expected 'rows'/'columns' arrays): #{page.inspect}"
      end
      if columns.nil?
        unless page['metadata'].is_a?(Array) && page['metadata'].size == page['columns'].size
          raise "dataset #{dataset_id}: malformed page response at offset #{offset} " \
                "(expected 'metadata' to be an Array the same size as 'columns' " \
                "(#{page['columns'].size}), got: #{page['metadata'].inspect})"
        end
        columns = page['columns']
        types = page['metadata'].map { |m| m.is_a?(Hash) ? m['type'] : nil }
      end
      page_rows = page['rows']
      rows.concat(page_rows)
      break if page_rows.size < band_size
      offset += band_size
    end
    columns = columns || []
    schema_cols = columns.each_with_index.map { |name, i| { 'name' => name, 'type' => (types || [])[i] } }
    { 'columns' => columns, 'schema_cols' => schema_cols, 'rows' => rows }
  end

  # Extracts + asserts the extracted row count matches a fresh COUNT(*) —
  # parity MEASURED, not assumed, same bar as powerbi-import-to-snowflake's
  # 923,371-row validation. Raises (never returns a value the caller might
  # not check) on any mismatch.
  def extract_with_parity(dataset_id, query:, band_size: 20_000)
    expected = row_count(dataset_id, query: query)
    extracted = extract_rows(dataset_id, query: query, band_size: band_size)
    actual = extracted['rows'].size
    if actual != expected
      raise RowCountMismatch, "dataset #{dataset_id}: expected #{expected} rows (COUNT(*)), got #{actual} extracted"
    end
    extracted
  end
end
