# looker / skilltest-course-performance

Synthetic field twin of the complex dashboard-7405 patterns from the customer
postmortem. It is intentionally credentials-free and contains no customer data.
The fixture covers finite-enum LookML parameters, a null-presence tile filter,
two pre-aggregated derived views connected by a relationship, a broadcast rate,
and an unsorted rolling calculation.

## Converter

Run the vendored `converter/lookml.mjs` locally with the model and both view
files, `exploreName=enrollment_metrics`, and `joinStrategy=relationships`.
Then parse `course_performance.dashboard.lookml` and run `build_workbook.py`
with the converter's `dynamicParameters` sidecar. `checks.sh` performs that
entire pipeline and verifies the expected hazard gate and SQLite value oracle.

## Expectations

```json
{
  "artifacts": [
    {"path": "../../../plugins/looker-to-sigma/skills/looker-to-sigma/fixtures/skilltest-course-performance/course_performance.model.lkml", "format": "text"},
    {"path": "../../../plugins/looker-to-sigma/skills/looker-to-sigma/fixtures/skilltest-course-performance/views/enrollment_metrics.view.lkml", "format": "text"},
    {"path": "../../../plugins/looker-to-sigma/skills/looker-to-sigma/fixtures/skilltest-course-performance/views/period_bridge.view.lkml", "format": "text"},
    {"path": "../../../plugins/looker-to-sigma/skills/looker-to-sigma/fixtures/skilltest-course-performance/course_performance.dashboard.lookml", "format": "text"},
    {"path": "../../../plugins/looker-to-sigma/skills/looker-to-sigma/fixtures/skilltest-course-performance/warehouse_rows.json", "format": "json"},
    {"path": "../../../plugins/looker-to-sigma/skills/looker-to-sigma/fixtures/skilltest-course-performance/oracle_expected.json", "format": "json"},
    {"path": "checks.sh", "format": "text"}
  ],
  "goldens": {}
}
```
