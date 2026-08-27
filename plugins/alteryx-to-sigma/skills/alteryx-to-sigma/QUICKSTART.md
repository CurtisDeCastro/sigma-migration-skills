# Alteryx → Sigma — Quickstart

Data-model only. Local converter. No MCP.

```bash
cd plugins/alteryx-to-sigma/skills/alteryx-to-sigma
eval "$(scripts/get-token.sh)"

# Convert a workflow (offline — no Sigma token needed for this step)
node converter/cli.mjs fixtures/orders-join.yxmd \
  --connection PLACEHOLDER-CONNECTION-ID \
  --out /tmp/alteryx-dm.json --gaps-out /tmp/alteryx-gaps.json

# If stats.dbtOfframps > 0, read /tmp/alteryx-gaps.json and refs/dbt-offramp.md
# BEFORE posting. ETL belongs in dbt; Sigma reads the materialized table.

# End-to-end (convert + reuse-check + POST + column-type gate)
ruby scripts/migrate-alteryx.rb \
  --yxmd fixtures/orders-join.yxmd \
  --connection-id "$SIGMA_CONNECTION_ID" \
  [--database CSA --schema TJ] \
  [--folder "$SIGMA_FOLDER_ID"] \
  --workdir /tmp/alteryx-run
```

Auth: `SIGMA_BASE_URL` / `SIGMA_CLIENT_ID` / `SIGMA_CLIENT_SECRET` in
`~/.sigma-migration/env`. Rebuild the converter after a `.ts` edit:
`cd converter && npm install && npm run bundle`.
