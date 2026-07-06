#!/usr/bin/env ruby
# Offline unit test for hydrate-custom-sql.rb — the published-datasource (sqlproxy)
# Custom SQL splice. Deterministic, no network / creds.
#
# Usage:  ruby scripts/test-hydrate-custom-sql.rb

require 'rexml/document'
require_relative 'hydrate-custom-sql'

fails = []
def check(cond, msg, fails) fails << msg unless cond; puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}" end

H = HydrateCustomSql

puts 'Part A — alias_for / quote_ref / wrap_sql (pure)'
check(H.alias_for('SFDC Oppty ID') == 'SFDC_OPPTY_ID', 'alias_for spaces→upper-snake', fails)
check(H.alias_for('Amount USD') == 'AMOUNT_USD', 'alias_for another spaced name', fails)
check(H.alias_for('STAGE_NAME') == 'STAGE_NAME', 'alias_for already-upper is identity', fails)
check(H.alias_for('Sub-Category') == 'SUB_CATEGORY', 'alias_for dash→underscore', fails)
check(H.quote_ref('Sales Region') == '"Sales Region"', 'quote_ref quotes mixed-case', fails)
check(H.quote_ref('STAGE_NAME') == 'STAGE_NAME', 'quote_ref leaves upper bare', fails)
wrapped = H.wrap_sql('SELECT a FROM t', ['SFDC Oppty ID', 'STAGE_NAME'])
check(wrapped.include?('"SFDC Oppty ID" AS SFDC_OPPTY_ID'), 'wrap_sql quotes+aliases mixed-case col', fails)
check(wrapped.include?('STAGE_NAME AS STAGE_NAME'), 'wrap_sql keeps upper col bare (aliased)', fails)
check(wrapped.include?('FROM (') && wrapped.include?(') t'), 'wrap_sql wraps original SQL in a subquery', fails)
begin
  H.wrap_sql('SELECT 1', [])
  check(false, 'wrap_sql raises on empty columns', fails)
rescue ArgumentError
  check(true, 'wrap_sql raises on empty columns', fails)
end

puts 'Part B — connection classification'
sqlproxy_twb = <<~XML
  <workbook><datasources>
    <datasource caption='Dormant Accounts' name='federated.d'>
      <connection class='sqlproxy' dbname='DormantAccounts'>
        <relation name='DormantAccounts' table='[sqlproxy]' type='table' />
        <metadata-records>
          <metadata-record class='column'><remote-name>SFDC Oppty ID</remote-name><caption>SFDC Oppty ID</caption></metadata-record>
          <metadata-record class='column'><remote-name>Sales Region</remote-name><caption>Sales Region</caption></metadata-record>
          <metadata-record class='measure'><remote-name>Amount USD</remote-name><caption>Amount USD</caption></metadata-record>
        </metadata-records>
      </connection>
    </datasource>
    <datasource caption='Live' name='federated.live'>
      <connection class='snowflake' dbname='CSA' schema='TJ'>
        <relation name='ORDERS' table='[CSA].[TJ].[ORDERS]' type='table' />
      </connection>
    </datasource>
  </datasources></workbook>
XML
doc = REXML::Document.new(sqlproxy_twb)
proxy_conn = doc.elements["/workbook/datasources/datasource[@caption='Dormant Accounts']/connection"]
live_conn  = doc.elements["/workbook/datasources/datasource[@caption='Live']/connection"]
check(H.sqlproxy_connection?(proxy_conn), 'detects sqlproxy connection', fails)
check(!H.sqlproxy_connection?(live_conn), 'live snowflake connection is not sqlproxy', fails)
check(!H.has_real_relation?(proxy_conn), 'sqlproxy placeholder is not a real relation', fails)
check(H.has_real_relation?(live_conn), 'live table relation is a real relation', fails)
check(H.cached_columns(proxy_conn) == ['SFDC Oppty ID', 'Sales Region', 'Amount USD'], 'cached_columns reads remote-names', fails)
check(H.published_ds_name(proxy_conn) == 'DormantAccounts', 'published_ds_name reads dbname', fails)
require 'tempfile'
Tempfile.create(['sqlproxy', '.twb']) do |f|
  f.write(sqlproxy_twb); f.flush
  check(H.twb_has_sqlproxy?(f.path), 'twb_has_sqlproxy? true for a sqlproxy workbook', fails)
end
Tempfile.create(['live', '.twb']) do |f|
  f.write("<workbook><datasources><datasource caption='L'><connection class='snowflake'><relation name='O' table='[A].[B].[O]' type='table'/></connection></datasource></datasources></workbook>")
  f.flush
  check(!H.twb_has_sqlproxy?(f.path), 'twb_has_sqlproxy? false for a live-table-only workbook', fails)
end

puts 'Part C — query_for matching'
blocks = [
  { 'name' => 'Dormant SQL', 'query' => 'SELECT 1 FROM x',
    'downstreamDatasources' => [{ 'name' => 'DormantAccounts' }] },
  { 'name' => 'Other SQL', 'query' => 'SELECT 2 FROM y', 'downstreamDatasources' => [{ 'name' => 'Other' }] }
]
q, _ = H.query_for(proxy_conn, 'Dormant Accounts', blocks)
check(q == 'SELECT 1 FROM x', 'query_for matches by downstream datasource name', fails)
q1, _ = H.query_for(proxy_conn, 'Dormant Accounts', [{ 'name' => 'x', 'query' => 'SELECT 9', 'downstreamDatasources' => [] }])
check(q1 == 'SELECT 9', 'query_for falls back to the lone block', fails)
qn, _ = H.query_for(proxy_conn, 'Dormant Accounts', [])
check(qn.nil?, 'query_for returns nil when nothing matches', fails)

puts 'Part D — hydrate! end-to-end (XML mutation)'
doc2 = REXML::Document.new(sqlproxy_twb)
hydrated = H.hydrate!(doc2, blocks: blocks, db: 'CSA', schema: 'TJ')
check(hydrated.size == 1, 'exactly one datasource hydrated (the sqlproxy one)', fails)
check(hydrated.first['column_source'] == 'cached-metadata', 'columns sourced from cached metadata when no probe', fails)
new_proxy = doc2.elements["/workbook/datasources/datasource[@caption='Dormant Accounts']/connection"]
check(new_proxy.attributes['class'] == 'snowflake', 'connection class rewritten to warehouse', fails)
check(new_proxy.attributes['dbname'] == 'CSA' && new_proxy.attributes['schema'] == 'TJ', 'db/schema set on connection', fails)
text_rel = nil
new_proxy.each_element('.//relation') { |r| text_rel = r if (r.attributes['type'] == 'text') }
check(!text_rel.nil?, 'a <relation type=text> was spliced in', fails)
check(new_proxy.get_elements('.//relation').size == 1, 'the sqlproxy placeholder relation was removed', fails)
sql = text_rel&.text.to_s
check(sql.include?('"SFDC Oppty ID" AS SFDC_OPPTY_ID'), 'spliced SQL quotes+aliases mixed-case output col', fails)
check(sql.include?('"Sales Region" AS SALES_REGION'), 'spliced SQL aliases Sales Region', fails)
check(sql.include?('SELECT 1 FROM x'), 'original Custom SQL preserved verbatim inside the wrap', fails)
remotes = []
new_proxy.each_element('.//metadata-records/metadata-record') { |m| remotes << m.get_text('remote-name').value }
check(remotes == %w[SFDC_OPPTY_ID SALES_REGION AMOUNT_USD], 'metadata remote-names rewritten to upper-snake aliases', fails)
# The live datasource must be untouched.
live2 = doc2.elements["/workbook/datasources/datasource[@caption='Live']/connection"]
check(live2.attributes['class'] == 'snowflake' && live2.get_elements('.//relation').first.attributes['type'] == 'table',
      'non-sqlproxy datasource left unchanged', fails)

puts 'Part E — probe columns override cached metadata'
doc3 = REXML::Document.new(sqlproxy_twb)
H.hydrate!(doc3, blocks: blocks, columns_by_key: { 'dormantaccounts' => ['Only One Col'] }, db: 'CSA', schema: 'TJ')
c3 = doc3.elements["/workbook/datasources/datasource[@caption='Dormant Accounts']/connection"]
rel3 = nil; c3.each_element('.//relation') { |r| rel3 = r if r.attributes['type'] == 'text' }
check(rel3.text.to_s.include?('"Only One Col" AS ONLY_ONE_COL'), 'probe columns override cached metadata', fails)

puts
if fails.empty?
  puts "ALL PASS (#{`grep -c 'check(' #{__FILE__}`.to_i - 1} assertions)"
  exit 0
else
  puts "#{fails.size} FAILED:"
  fails.each { |m| puts "  - #{m}" }
  exit 1
end
