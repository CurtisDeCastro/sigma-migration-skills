# Domo → Snowflake type mapping

| Domo `schema.columns[].type` | Snowflake |
|---|---|
| `STRING` | `VARCHAR` |
| `LONG` | `NUMBER(38,0)` |
| `DECIMAL` | `FLOAT` |
| `DOUBLE` | `FLOAT` |
| `DATE` | `DATE` |
| `DATETIME` | `TIMESTAMP_NTZ` |

Source: `Domo.dataset(id)['schema']['columns']` — the same field
`domo-to-sigma`'s own `domo-discover.rb`/`build-dm.rb` already consume
(confirmed live there; this skill adds no new Domo API surface).

**Any Domo type not in this table lands as `VARCHAR`, never aborts the
batch.** `SnowflakeDDL.unknown_types` surfaces these on stderr per dataset so
they're visible, not silent — widen the table in
`scripts/lib/snowflake_ddl.rb` if a real DataSet hits one (Domo's public docs
mention a few more, e.g. `PERCENT`/`DURATION`, that hadn't appeared anywhere
in this plugin's schema handling as of this skill's first build).
