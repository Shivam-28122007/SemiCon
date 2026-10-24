# Phase 3 — Functional Verification

Testbench: `phase3_verification/tb_phase3_axi_pcie_bridge.v` (self-checking, Icarus-compatible procedural
assertions). DUT parameters in the testbench: `DATA_WIDTH=32, MAX_BEATS=4, TAG_COUNT=4,
W_FIFO_DEPTH=8`. Run: `run_all.ps1` / `run_all.sh`; seed with `vvp phase3_sim +seed=<hex>`.

## Regression results (current RTL, Icarus Verilog 14.0-devel, 2026-10-22)

| Seed | Checks | Assertions (X-on-VALID / W-FIFO / stall-stability) | Result |
|---|---:|---|---|
| 13579bdf (default) | 748/748 | 1 704 (617 / 675 / 412) | PASS |
| 00000001 | 748/748 | 1 722 (606 / 715 / 401) | PASS |
| deadbeef | 793/793 | 1 725 (634 / 671 / 420) | PASS |
| 2468ace0 | 758/758 | 1 734 (616 / 709 / 409) | PASS |
| 0badf00d | 823/823 | 1 743 (629 / 705 / 409) | PASS |
| 12345678 | 763/763 | 1 703 (615 / 681 / 407) | PASS |
| cafef00d | 783/783 | 1 733 (633 / 679 / 421) | PASS |
| 7fffffff | 738/738 | 1 655 (576 / 706 / 373) | PASS |
| **Total** | **6 154/6 154** | **13 719, 0 failures** | **PASS** |

Check counts differ per seed because randomized burst lengths change the number of beat checks.
Also passing: the earlier Phase 2 directed testbench on the current RTL (66/66) and the same
regression on the **synthesized gate-level netlist** (3 seeds, see Phase 4).
Logs: `phase3_verification/phase3_regression.log`, `phase3_verification/logs/phase3_seed_*.log`,
`phase3_verification/logs/phase3_seed_summary.log`.

The previously reported 257/257 and 269/269 results belong to earlier testbench/RTL versions; the
numbers above replace them for the current package.

## What is verified

**Constrained-random traffic.** Seeded (`+seed=`) randomization of burst lengths (1–4), payloads,
AW-vs-W ordering (W may arrive entirely before AW), TX/R/B backpressure (0–3 cycle stalls),
completion latency (0–11 cycles) and completion order. A **concurrent mixed-traffic** phase runs six
independent threads (AW/W producer, AR producer, TX endpoint, completion endpoint, R consumer,
B consumer) for 24 writes + 24 reads with scoreboards:
* MemWr TLPs in AW order with exact address, length and payload;
* every MemRd TLP matches an issued AR (address/length);
* R data/ID/RLAST in AR order regardless of completion order; B IDs in AW order;
* bridge returns to idle with all ready signals high.

**Assertions (checked every clock):**
* TX, AXI R and AXI B payload/control stable while VALID is high and READY is low (stall-stability).
* No X/Z on any TX/R/B payload while its VALID is high (X-on-VALID) — required because the Phase 4
  RTL leaves pure datapath registers unreset.
* W FIFO occupancy never exceeds depth and `WREADY == !full` (white-box; compiled out for gate level).
* Ordering is checked by the scoreboards above (R in AR order, B in AW order, MemWr in AW order).

**Directed corner cases:** reset values; partial WSTRB; early WLAST; **missing/late WLAST** followed
by a clean write (no stale beat left behind); FIXED burst; unsupported size; oversized burst;
misaligned address; 4 KiB-crossing read and write; tag exhaustion (ARREADY low); unknown,
duplicate/stale and post-reset completions; completion status error → SLVERR; **W FIFO full**
(WREADY low, then drain); **AW accepted while the previous B is pending** (write pipelining);
reset while TX is stalled, with a read outstanding, during partial write collection, **while B is
stalled, and mid-burst while R is stalled**, each followed by a recovery transaction.

**Workload profiles (synthetic):** packet-processing (many small sequential writes) and
ML-inference (batches of 4-beat feature/weight reads with all tags outstanding and reverse-order
completions).

## Functional coverage (default seed)

| Bin | Hits | | Bin | Hits |
|---|---:|---|---|---:|
| Read burst length 1/2/3/4 | 6/11/7/4 | | Write burst length 1/2/3/4 | 9/9/8/7 |
| W-before-AW bursts | 16 | | W FIFO full cycles | 4 |
| AW accepted while B pending | 24 | | Late-WLAST rejects | 1 |
| Mixed concurrent bursts | 48 | | Tag-reuse read bursts | 20 |
| Out-of-order completions | 7 | | Tag-exhaustion tests | 1 |
| TX / R / B stall cycles | 175 / 162 / 78 | | Reset-during-activity | 5 |
| Malformed-request tests | 9 | | Stale-completion tests | 2 |

Every bin is hit on every seed (out-of-order completions range 4–11 across seeds). These are
scenario counters, not a tool-computed coverage percentage, and there is no code coverage.

## Cross-check against the Phase 2 RTL
Running this testbench on the frozen Phase 2 RTL (simulation copy with the declaration-order fix)
gives 741/747: all six failures come from the single new test that expects the next AW to be
accepted while a B response is pending — the behaviour Phase 4 intentionally added. Every other
test, including concurrent traffic and X-on-VALID checks, passes on the old RTL too.

## Bug found during this phase
The first concurrent run deadlocked: the testbench's TX-endpoint and completion threads shared a
temporary (`cap_tag`), so a recorded read tag could be overwritten while the TX thread waited in
`accept_tx`. Fixed by giving the completion thread its own variable (`cpl_tag`). It was a
testbench bug, not an RTL bug; noted here because it is exactly the kind of issue constrained
concurrency is meant to expose.

## Remaining limits
* Simulation only — no formal proof, no SVA (Icarus-compatible procedural assertions).
* Extra W beats beyond AWLEN+1 (an AXI protocol violation by the master) are not recovered from:
  they would be attributed to the next burst. The supported contract assumes a compliant master.
* Traffic profiles are synthetic, not replayed production or accelerator traces.
* The completion interface is abstract (one completion per burst; no PCIe completion splitting).
