# Visual QA (Alteryx)

N/A — Alteryx Designer workflows have no dashboard surface. This skill
never builds a Sigma workbook, so there is no `put-layout.rb` / `layout.xml`
and no last write of layout. Do not run `scripts/sigma-export-png.py` as a
completion gate. If the user later authors a workbook on the posted DM,
follow `sigma-workbooks` visual QA there.
