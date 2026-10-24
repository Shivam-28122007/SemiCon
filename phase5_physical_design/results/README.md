# Phase 5 results (empty until the Colab run)

Unzip `phase5_results.zip` from the Colab notebook here. Expected contents:

* `phase5_summary.md`, `phase5_summary.json` — metrics, signoff checklist, congestion, GDS checks, verdict
* `optimized_layout.png` (and `reference_layout.png` if the reference was run)
* `optimized/final/` — `gds/`, `klayout_gds/`, `lef/`, `nl/`, `pnl/`, `sdc/`, `metrics.json`, `metrics.csv`
* `optimized/run/` — every step's reports and logs (STA per corner, DRC, LVS, antenna, IR drop, routing)
* `optimized/flow_console.log` — full LibreLane console output
* `reference/…` — same layout for the Phase 2 reference, if it was run

Phase 5 is only complete when `phase5_summary.md` shows `optimized: PHASE 5 SIGNOFF: PASS` and the
validation table in `../PHASE5_PHYSICAL_DESIGN.md` has been checked.
