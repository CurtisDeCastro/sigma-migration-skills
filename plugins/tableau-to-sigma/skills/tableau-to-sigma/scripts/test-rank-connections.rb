#!/usr/bin/env ruby
# Offline unit test for rank-connections.rb (pure scoring + .twb fingerprint).
require_relative 'rank-connections'

$fail = 0
def check(desc)
  ok = yield
  puts "#{ok ? '  ok  ' : ' FAIL '} #{desc}"
  $fail += 1 unless ok
end

# Realistic org: 26-connection ASK reduced here to the relevant mix (multiple Snowflakes).
CANDS = [
  { 'connection_id' => 'c-prod', 'name' => 'Snowflake Prod', 'type' => 'snowflake', 'host' => 'draftkings.us-east-1.snowflakecomputing.com', 'account' => 'draftkings' },
  { 'connection_id' => 'c-ask',  'name' => 'ASK Data - Snowflake', 'type' => 'snowflake', 'host' => 'askdata.snowflakecomputing.com', 'account' => 'askdata' },
  { 'connection_id' => 'c-bq',   'name' => 'BigQuery- Wells', 'type' => 'bigQuery', 'host' => nil, 'account' => nil },
  { 'connection_id' => 'c-dbx',  'name' => 'Databricks data-science-dev', 'type' => 'databricks', 'host' => 'adb-123.azuredatabricks.net' },
  { 'connection_id' => 'c-rs',   'name' => 'Redshift Analytics', 'type' => 'redshift', 'host' => 'rs.abc.us-east-1.redshift.amazonaws.com' },
]

# 1) Confident auto-pick: type + host token both point at Snowflake Prod.
fp1 = { 'type' => 'snowflake', 'host' => 'draftkings.us-east-1.snowflakecomputing.com', 'database' => 'DWSPORTSBOOK' }
r1 = RankConnections.rank(fp1, CANDS)
check('recommends Snowflake Prod on type+host match') { r1['confident'] && r1['recommended']['connection_id'] == 'c-prod' }
check('Snowflake Prod outscores the other Snowflake') { r1['ranked'][0]['match_score'] > r1['ranked'][1]['match_score'] }
check('wrong-warehouse connections score 0') { r1['ranked'].select { |c| %w[c-bq c-dbx c-rs].include?(c['connection_id']) }.all? { |c| c['match_score'].zero? } }

# 2) Ambiguous: two Snowflakes, neither host matches the source → not confident.
fp2 = { 'type' => 'snowflake', 'host' => 'unknownco.snowflakecomputing.com' }
r2 = RankConnections.rank(fp2, CANDS)
check('two same-type, no host match → NOT confident (still asks)') { !r2['confident'] && r2['type_match_count'] == 2 }

# 3) Type normalization across Tableau/Sigma spellings.
check('bigquery <-> bigQuery normalize equal') { RankConnections.canon_type('bigquery') == RankConnections.canon_type('bigQuery') }
check('sqlserver <-> mssql normalize equal')    { RankConnections.canon_type('sqlserver') == RankConnections.canon_type('mssql') }
check('databricks <-> sparksql normalize equal'){ RankConnections.canon_type('databricks') == RankConnections.canon_type('sparksql') }

# 4) .twb fingerprint: picks the real warehouse connection, skips extract/federated/categorical.
TWB = <<~XML
  <workbook>
   <datasources>
    <datasource caption='HRB'>
     <connection class='federated'>
      <named-connections>
       <named-connection caption='SF'><connection class='snowflake' server='draftkings.us-east-1.snowflakecomputing.com' dbname='DWSPORTSBOOK' schema='DBO'/></named-connection>
      </named-connections>
      <relation type='text'>SELECT 1</relation>
     </connection>
    </datasource>
    <datasource><connection class='categorical'/></datasource>
   </datasources>
  </workbook>
XML
fp_twb = RankConnections.fingerprint_from_twb(TWB)
check('.twb fingerprint type = snowflake') { RankConnections.canon_type(fp_twb['type']) == 'snowflake' }
check('.twb fingerprint host = draftkings host') { fp_twb['host'] == 'draftkings.us-east-1.snowflakecomputing.com' }
check('.twb fingerprint database = DWSPORTSBOOK') { fp_twb['database'] == 'DWSPORTSBOOK' }

# 5) A .twb fingerprint feeds ranking to the same confident pick.
r5 = RankConnections.rank(RankConnections.merge_fp(fp_twb, {}), CANDS)
check('.twb-derived fingerprint recommends Snowflake Prod') { r5['confident'] && r5['recommended']['connection_id'] == 'c-prod' }

puts($fail.zero? ? "\nALL PASS" : "\n#{$fail} FAILED")
exit($fail.zero? ? 0 : 1)
