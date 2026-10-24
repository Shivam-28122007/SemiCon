# Phase 5 — Physical Design and Tape-Out Deliverables

## Status
**Ready to run; NOT executed. Phase 5 is not complete.** OpenROAD-based tools cannot run on the
Windows development machine, so the flow runs in Google Colab through
`phase5_physical_design/SARCathon_Phase5_LibreLane.ipynb`. No post-route timing, area, power,
DRC/LVS result or GDSII is claimed until the notebook has run, its cell 7 prints
`PHASE 5 SIGNOFF: PASS` for the optimized design, and the outputs have been checked with the
validation steps below.

## Flow
LibreLane **3.0.16** (successor of OpenLane 2), `Classic` flow, PDK `sky130A` (ciel version
`8afc8346a57fe1ab7934ba5a6056ea8b43078e71`, the hash pinned by LibreLane 3.0.16), standard cells
`sky130_fd_sc_hd`. Tools are installed by Nix exactly as in LibreLane's official Colab notebook.

| Stage | Tool / LibreLane step | Checked by |
|---|---|---|
| Lint | Verilator (`--Wall --Wno-fatal`) | lint error count (RTL is already `-Wall` clean) |
| Synthesis | Yosys (`read_verilog -defer -noautowire -sv`) + ABC, `SYNTH_STRATEGY = AREA 0` | unmapped cells, synthesis checks |
| Floorplan | OpenROAD, `FP_SIZING=relative`, `FP_CORE_UTIL=40`, aspect ratio 1 | — |
| I/O placement | custom pin order `phase5_physical_design/pin_order.cfg` | unmatched / doubly-matched pins abort the flow |
| Power grid | OpenROAD PDN (PDK defaults) | power-grid violations |
| Placement | global + detailed, resizer design repair | — |
| CTS | TritonCTS + post-CTS resizer timing repair | — |
| Routing | global (+ post-GRT resizer timing repair, enabled) + detailed routing | route DRC, antenna, congestion report |
| Parasitics / STA | OpenRCX + OpenSTA, all PDK corners | setup/hold WS/TNS per corner, violation counts, max slew/cap/fanout |
| Power | OpenROAD `report_power` (flow default activity) | reported, estimate only |
| Signoff | Magic + KLayout DRC, Magic/KLayout XOR, Netgen LVS, IR drop | DRC, XOR, LVS counts |
| Output | GDSII (Magic and KLayout stream-out), LEF, netlists, SDC | GDS top cell / size checked by the notebook |

Inputs:
* `config.json` — optimized RTL (`rtl/sarcathon_axi_pcie_bridge.v`), 10 ns clock on `clk`.
* `config_reference.json` — frozen Phase 2 RTL (`phase4_synthesis/rtl_reference/…_phase2.v`),
  identical constraints, `RUN_LINTER=false` (its use-before-declaration is rejected by Verilator;
  the file is kept byte-for-byte). Its Yosys front end was checked locally with LibreLane's exact
  flags (`-defer -noautowire -sv`) and elaborates cleanly.
* `pin_order.cfg` — **TX TLP north, RX completion south, AXI write channels west, AXI read
  channels + clock/reset east**; 835 signal pins at the default parameters.
* `build_notebook.py` — regenerates the notebook; it embeds the RTL, configs and pin order with
  SHA-256 hashes, and `check_sources.py` fails if the notebook is stale.

## Readiness review (2026-10-22, against the LibreLane 3.0.16 source)

Verified OK: CLI flags used by the notebook (`--pdk-root`, `--run-tag`, `--overwrite`); `PDK`
allowed in config files; PDK fetch via ciel to the same pinned version; run layout
`runs/<tag>/final/{gds,klayout_gds,…,metrics.json}`; `final/` is saved even when the flow ends with
deferred errors (DRC/LVS/timing), so results are always collectable; every config variable
exists in 3.0.16; every `dir::` path in both configs is embedded; pin regexes are anchored and
each of the 835 pins is matched exactly once (no unmatched pins, no unused regex) for both designs;
lint flags; metric names (`timing__setup__ws`, `timing__hold__ws`, per-corner keys,
`power__total/internal/switching/leakage`, `design__die__bbox`) are those written by LibreLane's
scripts; the notebook's cells 4/7/9 pass an offline mock run (PASS and FAIL verdict paths).

Fixed (Phase 5 preparation only):

| # | Issue found | Fix |
|---|---|---|
| 1 | Result export copied only `<step>/reports/`; OpenSTA writes setup/hold/power/skew reports to `<step>/<corner>/*.rpt` and `summary.rpt`/`irdrop.rpt` to the step folder, so **timing and power reports would have been missing from the zip** | Cell 9 now copies every report/log under the run directory (`.rpt .log .json .csv .xml …`, ≤ 50 MB each, no `.odb/.def/.spef`) plus both GDS stream-outs |
| 2 | Phase 5 asks for congestion; LibreLane exports no congestion metric | Cell 7 extracts OpenROAD's global-routing congestion report from the step logs |
| 3 | 307 TX-TLP pins were on the east edge (met3, 1.36 µm pin pitch): the I/O placer **aborts the flow** if pins exceed slots, which happens below ~64 k µm² of cells, and left only ~11 % headroom at the expected ~79 k µm² | TLP buses moved to north/south (met2, 0.46 µm pitch): ≥ 2.15× slot headroom even at 55 k µm²; AXI channels on east/west |
| 4 | Pin count stated as 836 | Corrected to 835 (counted from the elaborated port list) |
| 5 | Summary assumed a 10 ns clock; no GDS content check; no explicit pass/fail verdict | Clock read from `resolved.json`; KLayout checks each GDS (single top cell = design name, size vs die bbox); cell 7 prints `PHASE 5 SIGNOFF: PASS / NOT COMPLETE` with reasons |

Residual risks (cannot be removed without running the flow): Colab session limits on very long
runs; tool-version behaviour inside the Nix environment; the PDK's long-wire threshold, which can
raise a deferred (non-fatal) error on a pin-heavy macro; timing/DRC closure itself.

## How to run (exact steps)

1. **Before uploading**, from the project root: `python check_sources.py` → must print
   `STATIC SOURCE CHECKS: 66/66 passed` (this proves the notebook embeds the current RTL/configs).
2. Open https://colab.research.google.com → *File → Upload notebook* →
   `phase5_physical_design/SARCathon_Phase5_LibreLane.ipynb`.
3. *Runtime → Change runtime type*: CPU is sufficient (choose High-RAM if offered).
4. *Runtime → Run all.* Keep the tab open. Expected: cells 1–2 ≈ 10–20 min (Nix, LibreLane, PDK);
   cell 5 (optimized design) ≈ 20–60 min; cell 6 (Phase 2 reference, optional — untick
   `RUN_REFERENCE` before *Run all* to skip and halve the time) ≈ the same again.
5. **Cell 4 check**: the printed hashes must equal `SOURCE_MANIFEST.md`:
   `rtl/sarcathon_axi_pcie_bridge.v` → `9c91b9df…d875b`;
   `phase5_physical_design/pin_order.cfg` → `a0286649…e3c3`;
   `phase5_physical_design/config.json` → `96daece8…60b8`.
6. **Cell 5**: note the `librelane exit code`. 0 = clean. Non-zero = the flow raised errors; if
   `final/metrics.json` still exists they were deferred (DRC/LVS/timing) and cell 7 lists them.
   If the flow stopped early, the tail of `flow_console.log` is printed — send it to me.
7. **Cell 7**: read the `## Verdict` section. Phase 5 can only be marked complete on
   `optimized: PHASE 5 SIGNOFF: PASS`.
8. **Cell 9** downloads `phase5_results.zip` (tick `SAVE_TO_DRIVE` first if the browser download
   is unreliable). Unzip it into `phase5_physical_design/results/`.

## How to validate the outputs (after unzipping into `results/`)

| Deliverable | Where | Pass criterion |
|---|---|---|
| GDSII | `results/optimized/final/gds/sarcathon_axi_pcie_bridge.gds` and `…/final/klayout_gds/…gds`; picture: `results/optimized_layout.png` | both exist; `phase5_summary.md` shows top cell `['sarcathon_axi_pcie_bridge'] (OK)` and "GDS size vs die bbox: match"; `design__xor_difference__count` = 0 (Magic and KLayout GDS agree) |
| DRC | `phase5_summary.md` signoff table; reports under `results/optimized/run/*magic-drc*/`, `*klayout-drc*/` | `route__drc_errors`, `magic__drc_error__count`, `klayout__drc_error__count` all 0 |
| LVS | `results/optimized/run/*netgen-lvs*/` (log) | `design__lvs_error__count` = 0; the Netgen log reports that the circuits match |
| Timing | `results/optimized/run/*openroad-stapostpnr*/summary.rpt`; per corner `…/<corner>/max.rpt` (setup) and `min.rpt` (hold) | `timing__setup__ws` ≥ 0 and `timing__hold__ws` ≥ 0 (worst over all corners); setup/hold violation counts 0; max slew/cap/fanout counts 0. Fmax estimate = 1000/(10 − setup WS) MHz |
| Area | `phase5_summary.md` metrics; `results/optimized/final/metrics.json` | die/core bbox and area, `design__instance__area`, utilization reported. Cross-check: std-cell area should be of the order of the Phase 4 estimate (79 k µm² pre-placement; post-route adds buffers, taps and fill) |
| Power | `…/*openroad-stapostpnr*/<corner>/power.rpt`; `power__*` metrics | total, internal, switching and leakage reported. Label as an estimate (default switching activity), not measured power |
| Congestion | "Global-routing congestion" block in `phase5_summary.md`; global-routing step log | report present; total overflow 0 |
| Antenna / IR | `klayout__antenna_error__count`; `…/*irdropreport*/irdrop.rpt` | antenna 0 if reported; IR-drop values recorded |

Then send me the unzipped `results/` folder (or `phase5_summary.md` + `phase5_summary.json`), and
I will fill the table below from those files only.

## Results (fill from `results/phase5_summary.md` — do not edit by hand)

| Item | Optimized | Phase 2 reference |
|---|---|---|
| Signoff verdict (cell 7) | pending | pending |
| Flow completed (LibreLane exit code 0) | pending | pending |
| Die / core bbox and area | pending | pending |
| Instance count / std-cell area / utilization | pending | pending |
| Setup WS / TNS (worst corner) | pending | pending |
| Hold WS / TNS (worst corner) | pending | pending |
| Fmax estimate (from setup slack) | pending | pending |
| Total power (internal / switching / leakage) | pending | pending |
| Routed wirelength / congestion overflow | pending | pending |
| Detailed-route DRC / Magic DRC / KLayout DRC | pending | pending |
| LVS / XOR | pending | pending |
| Antenna, max slew / cap / fanout violations | pending | pending |
| GDSII produced and checked | pending | pending |

## What will and will not have been done
* Done by the flow: floorplanning, placement, CTS, routing, multi-corner STA with extracted
  parasitics, DRC (two checkers), LVS, XOR, GDSII stream-out of a **hardened macro**.
* Not done: pad frame / chip-level integration, an MPW shuttle (e.g. Caravel) wrapper — 835 pins
  do not fit a 38-GPIO harness without a different top-level interface — SDF-annotated
  gate-level simulation, and any physical PCIe PHY. The bridge's TLP side remains an abstract
  interface (no PCIe 6.0 compliance claim).
