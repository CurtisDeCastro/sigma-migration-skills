# Handoff — `domo-to-sigma` gold status, as of 2026-08-10

**Written:** 2026-08-10 (cloud agent). **Supersedes forward-looking sections of**
`2026-08-06-domo-gold-status.md` for the gold-path blockers.

Do **not** revive PR #661. Main already has the release migration (#663/#676),
parity oracle (#679), and layout fail-closed guard. Start from current `main`.

---

## Gold bar (unchanged)

`assert-phase6-ran.rb` exit 0 on a live run. No `--skip-parity-gate`. No
`--allow-stale-warehouse` for a claimed green (diagnostic use only).

---

## What landed this session

| Item | Status |
|---|---|
| Shape-B filter `operand` preference | **On branch** `cursor/domo-filter-operand-gold-66eb` / PR #703 — `domo-to-sigma` **0.16.7** |
| Live confirm of operand fix | **Yes** — rediscover of page `59931332` yields 20 filters as `IN`×13 / `NOT_IN`×3 / `GREATER_THAN`×4 (no opaque `LEGACY` collapse) |
| Fresh `migrate-domo` through workbook + collectors | **Yes** — workbook `8d93aaa6-ca08-4790-85ec-7db9ab1d3c89` in `My Documents/Test/Domo Migrations` |
| Parity oracle join | **Blocked exit 9** — warehouse stale vs Domo (up to 7 days on 10 date-dimensioned tiles) |
| Diagnostic score with `--allow-stale-warehouse` | **36.2% (21/65)** — windowed KPIs sign-invert / shift exactly as the freshness guard predicts; **not** a converter verdict |

### Operand fix (the only code delta)

[`domo-discover.rb`](../../plugins/domo-to-sigma/skills/domo-to-sigma/scripts/domo-discover.rb) Shape B now matches Shape A:

```ruby
'operator' => f['operand'] || f['operator'] || f['filterType']
```

Regression in `test/test-discover.rb` when `operand=NOT_IN` and `filterType=LEGACY`.

---

## Remaining blocker — Snowflake JWT for re-land

Creds on the cloud VM:

| Store | State |
|---|---|
| `~/.sigma-migration/env` (0600) | Domo + Sigma present; Sigma live token mint OK |
| `~/rsa_key.p8` | From cloud `SNOWFLAKE_PRIVATE_KEY_RAW` (4096-bit). Fingerprint SHA256 `4EjXJClcDzh3iUOGpDnIFA+EMt+HmXOCwaYPjPRMKYg=` |
| `~/.snowflake/config.toml` conn `tj` | Account `ymb68310`; every user tried returns **JWT token is invalid** |

The injected private key is **not registered** on the Snowflake users tried against
`ymb68310`. Interactive Okta / Domo UI logins need passwords not available here.

Public key body for `ALTER USER … SET RSA_PUBLIC_KEY=` is on the VM at
`/tmp/rsa_public_for_snowflake.txt` (not committed).

### Unblock (pick one)

1. **Register that public key** on the JWT user that connection `tj` uses
   (Snowsight as SECURITYADMIN / ACCOUNTADMIN), **or**
2. **Drop** the laptop’s working `~/rsa_key.p8` + `~/.snowflake/config.toml`
   `[connections.tj]` onto the VM (mode 0600; never commit).

### Re-land once JWT works

Script ready: `~/domo-gold-run/reland.sh` (truncate →
`domo_import_to_snowflake.rb --sf-conn tj` → table-level Sigma sync).

Hazards still apply: truncate first; `_BATCH_LAST_RUN_` is per band;
`PDP_EXAMPLE_DATASET` has no batch column.

Then clear parity outputs and re-run `migrate-domo.rb` with
`--folder-id bf419cf4-ae3e-43b7-ad1c-0aee247b1697` (Domo Migrations).
Target: `assert-phase6-ran.rb` exit 0 → flip `AGENTS.md` maturity to `gold`.

---

## Run directory

`~/domo-gold-run` — discovery, DM/WB ids, layout flag, parity expected/actuals,
diagnostic `parity-score.json`.

Instance/page: Domo page `59931332`. Warehouse: `CSA.DOMO_SAMPLE.*` on Sigma
connection `cb2f5180-641f-47bd-8efa-da9d590d855a`.
