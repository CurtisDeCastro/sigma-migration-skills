# Solver → Sigma — Quickstart

## Offline, on the synthetic fixture (no credentials)

```bash
cd plugins/solver-to-sigma/skills/solver-to-sigma
python3 scripts/convert-solver.py --definition fixtures/pnl-smoke/pnl-template.xlsx \
    --source-map fixtures/pnl-smoke/source-map.json --name "Location P&L summary - Data" \
    --folder-id <folder-id> --out /tmp/solver/dm.json --plan-out /tmp/solver/plan.json
python3 scripts/evaluate-solver-local.py --plan /tmp/solver/plan.json \
    --facts GL_F_Trans=fixtures/pnl-smoke/gl.csv --out /tmp/solver/values.json
python3 scripts/compare-solver-parity.py --plan /tmp/solver/plan.json \
    --run fixtures/pnl-smoke/pnl-executed-run.xlsx --values /tmp/solver/values.json --out /tmp/solver/parity.json
# parity GREEN: 39 cells compared, 0 mismatches, 0 unmatched
python3 tests/test_solver.py
```

## Live

1. Sign in to Sigma (see the repo's `AGENTS.md` › Credentials; browser OAuth, the Sigma CLI or client credentials).
2. Write `source-map.json` for the customer's warehouse (`refs/source-map.md`), with the Sigma `connectionId`.
3. Run the pre-flight (SKILL.md Phase 1) and stop if the anchors do not match.
4. Convert, POST and read back, build, POST:
   ```bash
   python3 scripts/convert-solver.py --definition report.xlsx --source-map source-map.json \
       --name "<Report> - Data" --folder-id <folder-id> --out dm.json --plan-out plan.json
   python3 scripts/post-solver.py dm --spec dm.json --readback dm-readback.json
   python3 scripts/build-solver-workbook.py --plan plan.json --dm-readback dm-readback.json \
       --name "<Report>" --folder-id <folder-id> --out wb.json
   python3 scripts/post-solver.py workbook --spec wb.json --dry-run
   python3 scripts/post-solver.py workbook --spec wb.json --readback wb-readback.json
   ```
5. Export the report table with the run's parameter values and run `compare-solver-parity.py --sigma-export`.
