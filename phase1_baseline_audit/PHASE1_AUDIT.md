# Phase 1 — Audit and Stabilize Stage 1 RTL

## Frozen baseline
The Stage 1 RTL and testbench are preserved byte-for-byte as `phase1_baseline_audit/stage1_baseline_*`; SHA-256 hashes
are in `phase1_baseline_audit/BASELINE_MANIFEST.md` (unchanged). All development happens in
`rtl/sarcathon_axi_pcie_bridge.v`.

## Reproduced result
`phase1_baseline_audit/stage1_baseline.log` (re-run 2026-10-22 by `run_all.ps1`, Icarus Verilog 14.0-devel from the
YosysHQ OSS CAD Suite 2026-10-08): **69 checks passed, 0 failed — ALL TESTS PASSED**, matching
the Stage 1 report (which used Icarus 12.0). Same 9 directed scenarios: reset, single write,
independent AW/W timing, 3-beat INCR write, partial WSTRB, read + CplD with TX backpressure,
two-beat read, completion error → SLVERR, wrong completion tag rejection.

## Audit findings on the Stage 1 design (motivating Phases 2–4)
| Area | Finding |
|---|---|
| Throughput | One outstanding transaction; one TLP per AXI beat; a read burst waits for each beat's completion before issuing the next request (measured: 0.089 read beats/cycle at 8-cycle latency, Phase 2 doc). |
| Address checks | No alignment or 4 KiB-crossing checks; FIXED bursts accepted. |
| Write protocol | WLAST mismatch is detected per beat, but a malformed burst is not drained as a unit. |
| Completion matching | Completion tag compared against the AXI ID (`rd_id`); only one read in flight. |

## Audit checklist
- [x] Preserve original RTL, testbench, report and hashes.
- [x] Re-run baseline and confirm the log reports all tests passed and the expected check count (69/69).
- [x] Baseline testbench covers reset, AW/W independence, burst progression, partial WSTRB, read
      completion, TX backpressure, completion error and wrong tag.
- [x] Reset while W is partially collected, with a read outstanding, while TX/B/R are stalled —
      covered on the enhanced bridge in Phase 3 (the frozen baseline testbench is not modified).
- [x] BVALID/BRESP/BID stability under BREADY=0 and RVALID/RDATA/RRESP/RLAST/RID stability under
      RREADY=0 — per-cycle assertions in the Phase 3 testbench.
- [x] Early-WLAST, unsupported burst/size, alignment and 4 KiB crossing — Phase 3.
- [x] Late/missing-WLAST policy — Phase 3 (rejected with SLVERR, no stale beat left behind).
- [ ] Extra W beats beyond AWLEN+1 — documented as unsupported (non-compliant master); not recovered.
- [x] Address arithmetic: the 4 KiB check uses explicitly sized 16-bit arithmetic on the low 12
      address bits (no overflow at any supported `ADDR_WIDTH`), lint-clean for 32- and 64-bit addresses.
- [x] Record tool versions, warnings and exit codes — `tool_versions.log`; `run_all.ps1`
      stops on any non-zero exit code or missing PASS summary.
