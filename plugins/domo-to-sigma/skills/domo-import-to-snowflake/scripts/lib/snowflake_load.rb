# frozen_string_literal: true

require 'open3'
require 'csv'
require 'tmpdir'
require_relative 'snowflake_ddl'

# Typed DDL + snow CLI PUT/COPY INTO, mirroring
# powerbi-import-to-snowflake's load step (same subprocess-CLI pattern, Ruby
# instead of Python). Command-building is pure and unit-tested; actually
# running the command against real Snowflake is the thin, untested-offline
# half — proven by live validation (this plan's Task 7), not a unit test.
module SnowflakeLoad
  class CommandFailed < StandardError; end

  module_function

  # rows: array of arrays (DomoExtract's shape). Quotes every field per
  # RFC4180 (Ruby's CSV library) so a raw value containing a comma/quote/
  # newline can't corrupt the column count COPY INTO relies on.
  def rows_to_csv(rows)
    CSV.generate { |csv| rows.each { |row| csv << row } }
  end

  # The `snow sql` invocation that creates the table, PUTs a local CSV file
  # to Snowflake's table stage, and COPYs it in — one statement per
  # semicolon so `snow sql -f` runs them as a single multi-statement session.
  def load_sql(create_table_sql, database, schema, table, file_uri)
    quoted = SnowflakeDDL.quote_identifier(table)
    <<~SQL
      #{create_table_sql}
      PUT '#{file_uri}' @%#{table} AUTO_COMPRESS=TRUE OVERWRITE=TRUE;
      COPY INTO #{database}.#{schema}.#{quoted}
        FILE_FORMAT = (TYPE = CSV FIELD_OPTIONALLY_ENCLOSED_BY = '"' SKIP_HEADER = 0)
        ON_ERROR = ABORT_STATEMENT;
    SQL
  end

  def grant_sql(database, schema, table, role)
    "GRANT SELECT ON #{database}.#{schema}.#{SnowflakeDDL.quote_identifier(table)} TO ROLE #{role};"
  end

  # Thin runner: writes `sql` to a temp file and runs it via the named `snow`
  # CLI connection. Raises CommandFailed (stdout+stderr embedded, same
  # error-text-embedding convention as sigma_rest.rb's Error) on any non-zero
  # exit rather than returning a status the caller might not check.
  def run_sql!(sql, connection:, runner: method(:system_run))
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'load.sql')
      File.write(path, sql)
      out, success = runner.call(['snow', 'sql', '--connection', connection, '-f', path])
      raise CommandFailed, "snow sql (connection #{connection}) failed:\n#{out}" unless success
      out
    end
  end

  # Real subprocess call — the untested-offline half. Returns [combined_output, success_boolean].
  def system_run(cmd)
    out, status = Open3.capture2e(*cmd)
    [out, status.success?]
  end
end
