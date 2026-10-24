# SARCathon 2026 — Complete Project Bundle (Phases 1–5)

This is the merged project folder for the AXI4-to-abstract-PCIe-TLP bridge. It preserves the Stage 1 baseline, Phase 2 architecture/throughput work, Phase 3 regression evidence, Phase 4 synthesis/PPA reports, and the Phase 5 LibreLane RTL-to-GDSII notebook.

## Important truth about status

- Phases 1–4 have existing logs/reports in this bundle; see `PHASE_STATUS.md` and each phase's report.
- **Phase 5 is not yet complete. No final GDSII has been produced in the supplied run.** The last Colab logs show Yosys' `JsonHeader` helper failed because the embedded Python could not import `_opcode`.
- The Phase 5 notebook generator has been updated with a preflight workaround: after Nix setup it attempts to make the Nix CPython 3.13 `_opcode` extension available to the system Python extension directory, then imports it before running LibreLane. This is a targeted fix attempt, not proof that the entire physical-design flow will complete. A full Colab run must verify it.
- No one can honestly guarantee 100% success across changing Colab/Nix runtime conditions without running and checking the full flow in the target runtime.

## One-go workflow

### A. Windows: reproduce Phases 1–4

1. Extract this ZIP completely.
2. Open PowerShell in the extracted `final` folder.
3. Install/download the YosysHQ OSS CAD Suite if the tools are not already available.
4. Set the environment variable to its extracted folder, for example:
   ```powershell
   $env:OSS_CAD_SUITE = "C:\path\to\oss-cad-suite"
   ```
5. Run:
   ```powershell
   .\run_all.ps1
   ```
6. Confirm the script exits successfully and inspect the fresh phase logs. Existing generated binaries are included as historical evidence but are recreated by the script.

### B. Google Colab: run Phase 5

1. Open `phase5_physical_design/SARCathon_Phase5_LibreLane.ipynb` in Google Colab.
2. Choose **Runtime → Change runtime type → High-RAM** if available (CPU runtime is sufficient).
3. Choose **Runtime → Run all** and keep the session alive. Installation/PDK download and physical design can take a long time.
4. Confirm the preflight cell reports that `_opcode` is available. If it fails, stop and save the error output; do not label Phase 5 complete.
5. Let the optimized flow run. The reference flow is optional and can be disabled by setting `RUN_REFERENCE = False` in its cell.
6. Phase 5 passes only if the notebook explicitly prints **`optimized: PHASE 5 SIGNOFF: PASS`**, produces the expected GDSII and `metrics.json`, and the DRC/LVS/timing/power checks in `phase5_physical_design/PHASE5_PHYSICAL_DESIGN.md` are satisfied.
7. Download `phase5_results.zip` from the final notebook cell and extract its contents into `phase5_physical_design/results/`.

## Contents

- `rtl/`: current synthesizable bridge RTL.
- `phase1_baseline_audit/`: frozen Stage 1 source, testbench, audit and evidence.
- `phase2_architecture/`: architecture and throughput verification.
- `phase3_verification/`: constrained-random regression, seeds, assertions and logs.
- `phase4_synthesis/`: SKY130 HD synthesis, PPA reports, gate-level netlist and logs.
- `phase5_physical_design/`: LibreLane configs, pin plan, notebook, generator, signoff checklist and latest failed-run diagnostics.
- `run_all.ps1` / `run_all.sh`: Phases 1–4 reproduction scripts.

Do not claim PCIe 6.0 compliance or a completed tape-out: this design uses an abstract TLP interface and Phase 5 signoff is pending until a verified GDSII run exists.
