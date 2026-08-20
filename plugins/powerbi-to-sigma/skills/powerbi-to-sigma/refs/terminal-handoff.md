# Power BI terminal handoff

Run the plugin-local terminal wrapper after strict parity:

```bash
ruby scripts/assert-powerbi-terminal.rb \
  --workdir <WORK> --workbook-id <WORKBOOK_ID>
```

The wrapper delegates all common gates to the shared, byte-identical
`assert-phase6-ran.rb`, preserving its exit codes and
`--accept-waiver-budget-exceeded REASON` option. After shared gates pass, it
refreshes Power BI's source census, degradation ledger, and migration report,
normalizes the success marker to the canonical `TerminalOutcome` verdict, and
runs `verify-complete.rb`.

Terminal rules:

- The one-shot mechanical builder writes `parity-pending.json` and exits 10.
  Resolution-only output is usable but is not GREEN or YELLOW.
- Every emitted/in-scope chart must have strict PASS parity. An emitted
  time-intelligence route without PASS evidence is nonterminal.
- A `needs-review` or `skipped` time-intelligence route can complete as YELLOW
  only when it is terminal-accounted, non-emitted, and claims no parity proof.
- Proven divergence is RED/nonzero.
- Terminal GREEN/YELLOW requires `completion_status: complete` and fresh
  `MIGRATION_REPORT.md`, `source-object-census.json`, and
  `degradation-ledger.json`.
- Unaccepted waiver-budget overflow remains exit 19. Named acceptance is
  considered only after other gates pass and yields YELLOW exit 0.

On any Power BI-specific finalization or verification failure, the wrapper
removes `phase6-success.json`, writes a routing marker, and exits nonzero.
