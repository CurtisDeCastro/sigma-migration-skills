#!/usr/bin/env ruby
# Unit tests for lib/snowflake_load.rb's pure command-building + the
# run_sql! runner-injection seam. No real `snow` CLI invoked.
#   ruby test/test-snowflake-load.rb

require_relative '../scripts/lib/snowflake_load'

$failures = 0
def eq(a, b, m) if a == b then puts "  ok: #{m}" else $failures += 1; puts "  FAIL: #{m}\n    exp #{b.inspect}\n    got #{a.inspect}" end end
def ok(c, m) if c then puts "  ok: #{m}" else $failures += 1; puts "  FAIL: #{m}" end end

puts "== rows_to_csv =="
csv = SnowflakeLoad.rows_to_csv([['a', 'b'], ['x,y', 'z"w']])
eq(csv, "a,b\n\"x,y\",\"z\"\"w\"\n", 'quotes fields containing commas/embedded quotes per RFC4180')

puts "== load_sql =="
sql = SnowflakeLoad.load_sql('CREATE TABLE DB.SCH.T (...);', 'DB', 'SCH', 'T', 'file:///tmp/x.csv')
ok(sql.include?('CREATE TABLE DB.SCH.T'), 'includes the caller-supplied CREATE TABLE statement verbatim')
ok(sql.include?("PUT 'file:///tmp/x.csv' @DB.SCH.%T"), 'PUTs to the fully-qualified table stage')
ok(sql.include?('COPY INTO DB.SCH.T'), 'COPYs into the target table')
ok(sql.include?('ON_ERROR = ABORT_STATEMENT'), 'aborts the whole COPY on any bad row, never a silent partial load')

# Regression test: table names requiring quoting (spaces, etc) must be quoted in PUT stage ref
sql_quoted = SnowflakeLoad.load_sql('CREATE TABLE DB.SCH."My Table" (...);', 'DB', 'SCH', 'My Table', 'file:///tmp/x.csv')
ok(sql_quoted.include?('@DB.SCH.%"My Table"'), 'PUT stage reference is fully qualified with database.schema.%table')

puts "== grant_sql =="
eq(SnowflakeLoad.grant_sql('DB', 'SCH', 'T', 'PUBLIC'), 'GRANT SELECT ON DB.SCH.T TO ROLE PUBLIC;', 'grants SELECT to the given role')

puts "== run_sql!: success path =="
ok_runner = ->(cmd) { ok(cmd.include?('--connection'), 'passes --connection through to the snow CLI'); ['all good', true] }
out = SnowflakeLoad.run_sql!('SELECT 1;', connection: 'myconn', runner: ok_runner)
eq(out, 'all good', "returns the runner's captured output on success")

puts "== run_sql!: failure path raises, never returns a status silently =="
fail_runner = ->(_cmd) { ['boom: syntax error', false] }
begin
  SnowflakeLoad.run_sql!('BAD SQL', connection: 'myconn', runner: fail_runner)
  ok(false, 'should have raised CommandFailed')
rescue SnowflakeLoad::CommandFailed => e
  ok(e.message.include?('boom: syntax error'), "raises with the subprocess output embedded, got: #{e.message}")
end

puts
if $failures.zero? then puts "ALL PASS"; exit 0 else puts "#{$failures} FAILURE(S)"; exit 1 end
