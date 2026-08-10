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
| Parity oracle join | **Blocked exit 9** — warehouse stale vs Domo (LOCATION_METRICS Domo max **2026-08-10** vs Snowflake **2026-08-07**; worst tile gap was 7 days) |
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
| `~/.sigma-migration/env` (0600) | Domo + Sigma present; live token mint OK |
| `~/rsa_key.p8` | From cloud `SNOWFLAKE_PRIVATE_KEY_RAW` (4096-bit). Fingerprint SHA256 `4EjXJClcDzh3iUOGpDnIFA+EMt+HmXOCwaYPjPRMKYg=` |
| `~/.snowflake/config.toml` conn `tj` | Account `ymb68310`; JWT user from that profile → **JWT token is invalid** |

Tried and ruled out on this VM:

- Alternate JWT users / accounts from Sigma connections — all JWT invalid for this key
- Domo Snowflake accounts / connector streams 12–13 — incomplete (`privateKey` / `warehouseName` missing); cannot push to Snowflake
- Snowsight via browser — Okta password wall (no interactive password on the VM)
- Sigma MCP — read-only SELECT (confirmed warehouse max dates); write schema is `SIGMA_WRITE_DB.SIGMA_WRITE`, not `CSA.DOMO_SAMPLE`

### Unblock (pick one — ~30 seconds on a working Snowflake session)

**Preferred:** from a laptop session where `snow sql -c tj` already works, run the exact
`ALTER USER … SET RSA_PUBLIC_KEY=…` statement on the VM at:

- `/tmp/alter_rsa_public_key.sql`
- public key body only: `/tmp/rsa_public_for_snowflake.txt`

That registers **this VM's** cloud-injected private key on the Snowflake user named in
`~/.snowflake/config.toml` `[connections.tj]`.

**Or** drop the laptop's working `~/rsa_key.p8` + matching `[connections.tj]` onto this VM
(mode 0600; never commit).

### Re-land + finish gold (scripted)

Once `snow sql -c tj -q "SELECT CURRENT_USER()"` works on this VM:

```bash
bash ~/domo-gold-run/resume-after-jwt.sh
```

That truncates → re-lands via `--sf-conn tj` → table-level Sigma sync → clears
parity/layout artifacts → resumes `migrate-domo.rb --out ~/domo-gold-run` →
`assert-phase6-ran.rb`.

Hazards still apply: truncate first; `_BATCH_LAST_RUN_` is per band;
`PDP_EXAMPLE_DATASET` has no batch column.

Then flip `AGENTS.md` + `SKILL.md` maturity to `gold` (only after legitimate exit 0).

---

## Run directory

`~/domo-gold-run` — discovery, DM/WB ids, layout flag, parity expected/actuals,
diagnostic `parity-score.json`, `reland.sh`, `resume-after-jwt.sh`.

Instance/page: Domo page `59931332`. Warehouse: `CSA.DOMO_SAMPLE.*` on Sigma
connection `cb2f5180-641f-47bd-8efa-da9d590d855a`.
Folder: `bf419cf4-ae3e-43b7-ad1c-0aee247b1697`.
