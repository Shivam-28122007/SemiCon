# SARCathon 2026 — AXI4 → PCIe TLP Bridge (Phases 1–5)

An AXI4 slave to abstract PCIe TLP bridge in SkyWater SKY130: Stage 1 baseline, enhanced
architecture (buffering, burst coalescing, multiple outstanding reads), constrained-random
verification, synthesis/PPA, and a ready-to-run RTL-to-GDSII flow.

Start with **`PHASE_STATUS.md`** (requirement-by-requirement status and evidence).

## Headline results (Phases 1–4, reproduced by `run_all.ps1`)
| | Result |
|---|---|
| Stage 1 baseline | 69/69 checks |
| Phase 3 regression | 6 154/6 154 checks, 13 719 assertion evaluations, 0 failures, 8 seeds |
| Gate-level simulation of the synthesized netlist | 3 seeds pass, cycle-identical to RTL |
| Throughput vs Stage 1 | writes 1.83×, reads 9.4× (latency 8) / 13× (latency 32), 4× fewer TLPs |
| Area vs Phase 2 RTL (SKY130 HD) | −16.1 % at equal parameters, −33.1 % at new defaults (79 k µm²) |
| Lint | Verilator `-Wall` clean over 8 parameter sets |
| Phase 5 (GDSII) | ready to run in Google Colab; **not yet executed** |

## Layout
```
rtl/                         current design: sarcathon_axi_pcie_bridge.v (Phases 2-5)
phase1_baseline_audit/       frozen Stage 1 RTL + testbench + report, BASELINE_MANIFEST.md,
                             PHASE1_AUDIT.md, stage1_baseline.log
phase2_architecture/         PHASE2_ARCHITECTURE.md, directed + throughput testbenches,
                             logs/ (throughput, directed test, lint)
phase3_verification/         PHASE3_VERIFICATION.md, tb_phase3_axi_pcie_bridge.v,
                             phase3_regression.log, logs/ (8 seeds + summary)
phase4_synthesis/            PHASE4_SYNTHESIS_PPA.md, run_synth.py, ref_declfix.py, lib/,
                             reports/, rtl_reference/ (frozen Phase 2 RTL), gls/, logs/
phase5_physical_design/      PHASE5_PHYSICAL_DESIGN.md, config*.json, pin_order.cfg,
                             SARCathon_Phase5_LibreLane.ipynb, build_notebook.py, results/
PHASE_STATUS.md  README.md  SOURCE_MANIFEST.md  run_all.ps1  run_all.sh
check_sources.py  static_source_check.log  tool_versions.log
build/                       generated simulators (safe to delete; recreated by run_all)
```

## Reproduce Phases 1–4
Needs Icarus Verilog; Verilator, Yosys and Python 3 are used when present. Easiest: unpack the
YosysHQ OSS CAD Suite (https://github.com/YosysHQ/oss-cad-suite-build/releases, Windows build
`oss-cad-suite-windows-x64-20261008.tgz` used here) and point `OSS_CAD_SUITE` at it.

```powershell
$env:OSS_CAD_SUITE = "C:\path\to\oss-cad-suite"
.\run_all.ps1            # everything (~5-10 min); logs go into each phase folder
.\run_all.ps1 -Quick     # Stage 1 + Phase 3 default seed only
```
```bash
export OSS_CAD_SUITE=/path/to/oss-cad-suite   # or have iverilog/verilator/yosys on PATH
bash run_all.sh
```
Synthesis alone: `python phase4_synthesis/run_synth.py` (falls back to `pip install yowasp-yosys`
if no native Yosys). Static package check (includes "notebook embeds the current RTL/configs"):
`python check_sources.py`.

## Run Phase 5 (RTL → GDSII)
Follow `phase5_physical_design/PHASE5_PHYSICAL_DESIGN.md` → "How to run" and "How to validate".
In short: upload `phase5_physical_design/SARCathon_Phase5_LibreLane.ipynb` to Google Colab,
*Runtime → Run all*, check the cell 7 verdict, unzip `phase5_results.zip` into
`phase5_physical_design/results/`.

## Engineering boundary
Simulation-verified RTL and synthesis results with an abstract TLP interface — not PCIe 6.0
compliance (no FLIT, CRC/FEC, PHY) and not a taped-out chip. Do not delete or weaken a failing
test to make a summary pass.
