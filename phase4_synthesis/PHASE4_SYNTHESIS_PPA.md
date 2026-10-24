# Phase 4 — Synthesis and PPA Analysis

Everything in this document is reproduced by `python phase4_synthesis/run_synth.py` (called from
`run_all.ps1` / `run_all.sh`). Generated reports are in `phase4_synthesis/reports/`.

## Setup (identical for every configuration)

| Item | Value |
|---|---|
| Synthesis tool | Yosys 0.69+260 with ABC (YosysHQ OSS CAD Suite 2026-10-08); also reproduced with YoWASP Yosys 0.70 (same area within 0.1 %) |
| Standard cells | SkyWater SKY130 `sky130_fd_sc_hd`, typical corner `tt_025C_1v80` |
| Liberty | `phase4_synthesis/lib/sky130_fd_sc_hd__tt_025C_1v80.lib`, SHA-256 `ec0e1067…d0d9`, pinned to OpenROAD-flow-scripts commit `b5dceb3` |
| Script | `synth -flatten` → `dfflibmap` → `abc -D 10000` → `setundef -zero` → `hilomap` → `opt_clean` |
| Excluded cells | `lpflow_*`, `probe_p_*`, `probec_p_*` (the PDK's don't-use set for synthesis) |
| Clock target | 10 ns (100 MHz) |
| Parameters | each design's defaults: `DATA_WIDTH=64, ADDR_WIDTH=32, ID=4`; enhanced: `MAX_BEATS=4, TAG_COUNT=4` |

## Results

| Configuration | Cell area (µm²) | vs Phase 2 | Cells | Seq. cells | Comb. cells | Leakage (nW, tt) | ABC delay unbuffered / sized (ps) |
|---|---:|---:|---:|---:|---:|---:|---:|
| Stage 1 baseline | 15 038 | −87.3 % | 1 347 | 356 | 991 | 6.5 | 6 517 / 3 002 |
| Phase 2 RTL (pre-optimization) | 118 121 | — | 9 275 | 3 088 | 6 187 | 46.6 | 38 062 / 2 732 |
| Phase 4 RTL, `W_FIFO_DEPTH=16` (same parameters as Phase 2) | 99 061 | **−16.1 %** | 5 649 | 2 655 | 2 994 | 32.7 | 12 084 / 3 094 |
| Phase 4 RTL, default `W_FIFO_DEPTH=8` | **78 995** | **−33.1 %** | 5 071 | 2 124 | 2 947 | 26.3 | 11 585 / 2 779 |

* *Cell area* is pre-placement standard-cell area from the unbuffered mapping (no tap/fill/CTS or
  resizer buffers); Phase 5 reports post-route area.
* *Leakage* is the sum of liberty `cell_leakage_power` over all instances at the typical corner.
  Dynamic power needs switching activity and is reported by OpenROAD in Phase 5.
* *ABC delay* is ABC's library-aware combinational estimate (`stime`), first unbuffered, then
  after ABC `buffer/upsize/dnsize`. It excludes clock-to-Q, setup, wire load and skew, so it is a
  relative indicator, not signoff timing (OpenSTA in Phase 5).
* The Stage 1 baseline is much smaller because it has no buffering, one outstanding transaction
  and a 64-bit TLP data bus. The enhanced design's area is dominated by intentional storage:
  4 tags × 256-bit completion buffers (1 024 flops), the W FIFO and the 256-bit write-collection
  register. The like-for-like comparison is Phase 2 vs Phase 4.

Sequential cells: Phase 2 = 1 916 `dfrtp` + 1 168 `edfxtp`; Phase 4 = 58 `dfrtp` + 258 `dfxtp`
+ 1 808 `edfxtp` (reset-free datapath registers merge the hold mux into enable flops).

## What was optimized and why

| # | Change (RTL) | Effect |
|---|---|---|
| 1 | `tx_tlp_data` driven from the write-collection register instead of a second 256-bit register; `tx_tlp_type`/tag derived from existing state; `wr_packet_addr/len/id` copies removed | −256+ flops; removes the 299-fanout TX-launch net that dominated the Phase 2 unbuffered path |
| 2 | W FIFO stores one "strobe all ones" bit instead of the full `WSTRB` | −7 bits per FIFO entry |
| 3 | Pure datapath registers (tag data/addr/len/status, response queue, TX address/len/tag, write collection) have no reset; every control/VALID flop keeps its async reset | smaller flops; X-safety proven by the X-on-VALID assertions in RTL **and** gate-level simulation |
| 4 | Locally rejected reads return zero data by masking `s_axi_rdata`, not by clearing 256-bit tag data | removes a 1 024-bit clear path |
| 5 | Default `W_FIFO_DEPTH` 16 → `2*MAX_BEATS` (=8): still buffers one complete burst ahead of the one being collected | −536 flops (row 3 vs row 4) |
| 6 | **Critical-path fix:** `w_final` (is this the last beat?) was a subtract-and-compare on `wr_total_beats` feeding `w_pop` → 256-bit write enables. It is now a registered flag and the subtractor is gone (`wr_last_beat = AWLEN`) | ABC sized path moved off the write collector (see below) |
| 7 | Write pipelining: next AW accepted after the TLP is accepted, not after the B handshake | +13 % write throughput (Phase 2 doc) |

All seven changes are functionally verified: Phase 3 regression on 8 seeds, Phase 2 directed
testbench (66/66), and gate-level simulation of the synthesized netlist (below).

## Critical paths

Reports: `phase4_synthesis/reports/<config>.timing_10000ps.critical_path.rpt`.

| Design | Unbuffered critical path | After ABC buffering/sizing |
|---|---|---|
| Phase 2 RTL | `tx_tlp_valid` → TX-slot-free (**fanout 299**) → 256-bit TX data launch mux: 38.1 ns | AR inputs → 4 KiB / length check → `tag_data` enable: 2.73 ns |
| Phase 4 before fix #6 (measured during development, not in the final report set) | `resp_rd_ptr` → head-tag mux (**fanout 266**) → R data mux: 12.2 ns | `wr_total_beats` → subtract/compare `w_final` → `w_pop` → `wr_packet_data` enables: 2.87 ns |
| Phase 4 final | `resp_rd_ptr` → head-tag select → tag state: 11.6 ns | `s_axi_arlen` → 4 KiB-crossing adder (ripple `maj3` chain) → `ar_bad` → `tag_done`: 2.78 ns |

Interpretation:
* After buffering, all designs are at ~2.7–3.1 ns of logic, i.e. far inside the 10 ns target; the
  remaining critical path is an **input-port-to-register** path through the AR/AW 4 KiB-crossing
  adder. If an SoC input-delay budget makes it critical, the fix is a one-cycle AR/AW register
  slice (adds one cycle of address latency and ~50 flops per channel); not needed at 100 MHz.
* The unbuffered numbers show high-fanout nets the placer/resizer must buffer: Phase 2's 299-load
  TX-launch net is gone in Phase 4; the 266-load R head-tag select remains (it selects among
  `TAG_COUNT` completion buffers) and is a candidate for a one-hot registered head pointer.

## Gate-level simulation (post-synthesis functional check)

The Phase 3 testbench is run against the **synthesized SKY130 netlist** of the bridge
(`DATA_WIDTH=32, MAX_BEATS=4, TAG_COUNT=4, W_FIFO_DEPTH=8`, the testbench configuration), with
cell functions taken from the liberty file (`read_liberty` + `flatten`), compiled with
`-DGATE_LEVEL` (only the two white-box FIFO-count probes are compiled out).

| Seed | Checks | Assertions (X-on-VALID / stall-stability) | Result |
|---|---|---|---|
| 13579bdf | 748/748 | 1 029 (617 / 412), 0 failures | PASS |
| 00000001 | 748/748 | 1 007 (606 / 401), 0 failures | PASS |
| deadbeef | 793/793 | 1 054 (634 / 420), 0 failures | PASS |

The gate-level runs finish at exactly the same simulation time as the RTL runs and produce the
same assertion counts, i.e. the netlist is cycle-identical to RTL on these workloads. This is
zero-delay functional simulation (no SDF back-annotation); timing is covered by STA in Phase 5.
Logs: `phase4_synthesis/logs/gls_seed_*.log`, `phase4_synthesis/logs/gls_summary.log`.

## Parameterization / synthesizability
`phase4_synthesis/reports/param_sweep.rpt`: 9 parameter sets elaborate and pass `check -assert`
(`DATA_WIDTH` 32/64/128, `MAX_BEATS`/`TAG_COUNT` 1…16 incl. non-power-of-two 3, `W_FIFO_DEPTH`
2…32 incl. 5, 64-bit address with 8-bit IDs). The same sets lint clean with Verilator `-Wall`.

## Limitations (stated plainly)
* Single typical corner; no slow/fast corner or wire-load model at this stage (Phase 5 STA runs
  the PDK's multi-corner set).
* ABC delay is not STA. Fmax claims are made only from Phase 5 OpenSTA results.
* No dynamic power here (needs activity; Phase 5 reports OpenROAD's power estimate with the
  flow's default activity, which is itself an estimate, not a measured-activity number).
* The Phase 2 reference RTL uses a signal before its declaration (accepted by Yosys and Icarus 12,
  rejected by Icarus 14/Verilator). It is kept byte-for-byte; `phase4_synthesis/ref_declfix.py` makes a
  separate simulation copy with only that declaration moved.
