# SARCathon 2026 Round 2 — Phase 1–5 Status and Evidence

Status as of 2026-10-22. "Done" means reproduced by `run_all.ps1` with the log named in the
evidence column. Final submission deadline: 31 Oct 2026.

## Folder layout
| Folder | Contents |
|---|---|
| `rtl/` | Current design `sarcathon_axi_pcie_bridge.v` (used by Phases 2–5) |
| `phase1_baseline_audit/` | Frozen Stage 1 RTL/testbench/report, baseline manifest, audit, Stage 1 log |
| `phase2_architecture/` | Architecture doc, directed and throughput testbenches, throughput/lint logs |
| `phase3_verification/` | Verification doc, Phase 3 testbench, regression logs (8 seeds) |
| `phase4_synthesis/` | Synthesis/PPA doc, scripts, liberty, reports, frozen Phase 2 reference RTL, gate-level netlist and logs |
| `phase5_physical_design/` | Physical-design doc, LibreLane configs, pin order, Colab notebook + generator, `results/` |

The files were moved into this layout on 2026-10-22 with contents unchanged (verified by
SHA-256 before and after); the Phase 1–4 logs and reports were not regenerated. Generated
reports record the paths in use when they were produced.

| Phase | Requirement | Status | Evidence |
|---|---|---|---|
| 1 | Freeze Stage 1 RTL/testbench | Done | `phase1_baseline_audit/BASELINE_MANIFEST.md` hashes unchanged |
| 1 | Reproduce Stage 1 checks | Done — 69/69 | `phase1_baseline_audit/stage1_baseline.log` |
| 1 | Reset / handshake / burst / error / address audit | Done (one documented exclusion: extra W beats) | `phase1_baseline_audit/PHASE1_AUDIT.md` |
| 2 | Buffering / FIFOs | Done | W FIFO; FIFO-full test + per-cycle occupancy assertion |
| 2 | Reduce stalls / improve throughput | Done, measured | 1.83× writes, 9.4–13× reads vs Stage 1; +13 % writes vs Phase 2 RTL (`phase2_architecture/logs/perf_throughput.log`) |
| 2 | Multiple outstanding requests, tracking | Done | `TAG_COUNT` tags, out-of-order completions, AR-ordered R; tag-count sweep |
| 2 | Coalesce beats into larger requests | Done (within burst) + evaluated (across bursts) | `phase2_architecture/PHASE2_ARCHITECTURE.md` |
| 2 | Synthesizable, parameterized | Done | 9-set elaboration + Verilator `-Wall` sweep (`phase2_architecture/logs/lint_verilator.log`) |
| 3 | Constrained-random tests | Done | 8 seeds × concurrent mixed traffic, 6 154/6 154 checks |
| 3 | Handshake-stability and ordering assertions | Done | 13 719 assertion evaluations, 0 failures |
| 3 | Backpressure, reset mid-transaction, malformed bursts, completion errors | Done | `phase3_verification/PHASE3_VERIFICATION.md` |
| 3 | Functional coverage + regression results | Done (scenario counters; no code coverage) | `phase3_verification/logs/phase3_seed_summary.log` |
| 3 | Packet-processing / ML traffic | Done (synthetic profiles) | `phase3_verification/phase3_regression.log` |
| 4 | Synthesize with a standard-cell library and constraints | Done | Yosys + SKY130 HD, 10 ns (`phase4_synthesis/reports/`) |
| 4 | Area, timing, power | Done for area, leakage, ABC delay; dynamic power and STA timing come from Phase 5 | `phase4_synthesis/reports/ppa_summary.md` |
| 4 | Critical paths identified and optimized | Done | `phase4_synthesis/PHASE4_SYNTHESIS_PPA.md` (write-collector path fixed; TX-launch fanout removed) |
| 4 | Baseline vs optimized, same constraints | Done | −16.1 % area at equal parameters, −33.1 % at new defaults |
| 4 | Post-synthesis functional check | Done (extra) | gate-level simulation, 3 seeds, cycle-identical to RTL (`phase4_synthesis/logs/gls_summary.log`) |
| 5 | Floorplan, placement, CTS, routing | **Ready to run — not executed** | `phase5_physical_design/SARCathon_Phase5_LibreLane.ipynb` (Colab) |
| 5 | Setup/hold, congestion, DRC/LVS | **Ready to run — not executed** | signoff checklist + verdict printed by notebook cell 7 |
| 5 | GDSII + implementation reports | **Ready to run — not executed** | `phase5_results.zip` → `phase5_physical_design/results/` |
| 5 | Document what was completed and passed | Template + validation steps ready | `phase5_physical_design/PHASE5_PHYSICAL_DESIGN.md` |

Phase 5 readiness review (2026-10-22): the notebook, configs and pin plan were checked against
the LibreLane 3.0.16 source and an offline mock run; three preparation issues were fixed (missing
timing/power reports in the export, no congestion report, an I/O pin plan that could abort the
flow). Details in `phase5_physical_design/PHASE5_PHYSICAL_DESIGN.md`.

## Remaining action
Run the Phase 5 notebook in Google Colab as described in
`phase5_physical_design/PHASE5_PHYSICAL_DESIGN.md`, unzip `phase5_results.zip` into
`phase5_physical_design/results/`, and validate the outputs with the checklist there. **Phase 5
is not complete until cell 7 reports `optimized: PHASE 5 SIGNOFF: PASS` and the GDSII, timing,
area and power reports have been checked.**

## Known scope limits
- Abstract packet-level TLP interface; no PCIe FLIT framing, CRC/FEC, PIPE/PHY, credits or replay;
  no PCIe 6.0 compliance claim.
- Full-width, aligned INCR bursts up to `MAX_BEATS`, all-ones write strobes; one write burst
  collected at a time; extra W beats from a non-compliant master are not recovered.
- One abstract completion per burst (no completion splitting / byte-count semantics).
- Verification is simulation-based (no formal), coverage is scenario counters (no code coverage).
- Phase 5 targets a hardened macro, not a pad-framed chip or MPW submission.

## Latest Phase 5 failure and remediation attempt (2026-10-22)

The most recent Colab snapshot stopped at `Yosys.JsonHeader` before synthesis. Its log reports `ModuleNotFoundError: No module named '_opcode'`; no `final/metrics.json` or GDSII was produced. Archived logs are under `phase5_physical_design/diagnostics/last_failed_colab_run/`. The notebook generator now attempts to expose the Nix CPython 3.13 `_opcode` extension to the system Python extension directory and verify its import before running the flow. This workaround is not yet validated by a complete Colab run. Phase 5 remains **NOT COMPLETE** until a fresh run achieves the explicit signoff criteria.

## Latest Phase 5 update (2026-10-23)
The latest supplied console log is saved under `phase5_physical_design/diagnostics/latest_colab_run/`. It ends during antenna repair and does not establish successful completion or signoff. See `phase5_physical_design/diagnostics/LATEST_STATUS.md`. The reported `librelane exit code -11` remains unresolved; this bundle must not be described as a verified completed GDSII/signoff result.
