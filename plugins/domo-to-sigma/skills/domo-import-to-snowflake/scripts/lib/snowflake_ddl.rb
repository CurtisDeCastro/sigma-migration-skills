# frozen_string_literal: true

# Pure logic: Domo schema.columns[] -> Snowflake typed DDL. No network, no
# filesystem — matches column_preflight.rb's own pure/offline-testable style.
module SnowflakeDDL
  # Domo's dataset schema column `type` enum (confirmed live via
  # Domo.dataset(id)['schema']['columns'] — same field build-dm.rb already
  # consumes; its own test fixtures use STRING/LONG/DECIMAL/DATE) -> a
  # Snowflake column type. An unrecognized type falls back to VARCHAR rather
  # than raising — see unknown_types for the audit trail — so one odd column
  # never blocks landing a whole DataSet.
  DOMO_TO_SNOWFLAKE = {
    'STRING'   => 'VARCHAR',
    'LONG'     => 'NUMBER(38,0)',
    'DECIMAL'  => 'FLOAT',
    'DOUBLE'   => 'FLOAT',
    'DATE'     => 'DATE',
    'DATETIME' => 'TIMESTAMP_NTZ'
  }.freeze

  module_function

  def column_type(domo_type)
    DOMO_TO_SNOWFLAKE.fetch(domo_type.to_s.upcase, 'VARCHAR')
  end

  # Domo type strings not in DOMO_TO_SNOWFLAKE, deduped, for a caller to warn
  # on (never a hard failure — see column_type).
  def unknown_types(schema_cols)
    Array(schema_cols)
      .map { |c| c['type'].to_s.upcase }
      .reject { |t| DOMO_TO_SNOWFLAKE.key?(t) }
      .uniq
  end

  # Snowflake identifiers: unquoted names uppercase automatically and accept
  # only [A-Za-z_][A-Za-z0-9_]*; a raw Domo column name with spaces/symbols
  # is double-quoted verbatim instead of mangled, so column order stays 1:1
  # with what the COPY step (snowflake_load.rb) positionally relies on.
  def quote_identifier(name)
    s = name.to_s
    return s if s =~ /\A[A-Za-z_][A-Za-z0-9_]*\z/
    "\"#{s.gsub('"', '""')}\""
  end

  # database/schema/table: plain strings already chosen by the caller
  # (CLI --target-db/--target-schema, or a table name derived from the
  # DataSet) — this function only emits SQL, it doesn't decide naming.
  def create_table_sql(database, schema, table, schema_cols)
    cols = Array(schema_cols).map { |c|
      "  #{quote_identifier(c['name'])} #{column_type(c['type'])}"
    }.join(",\n")
    "CREATE TABLE IF NOT EXISTS #{database}.#{schema}.#{quote_identifier(table)} (\n#{cols}\n);"
  end
end
