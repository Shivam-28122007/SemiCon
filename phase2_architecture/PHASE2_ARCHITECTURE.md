# Phase 2 — Architecture and RTL Performance

RTL: `rtl/sarcathon_axi_pcie_bridge.v` (current, Phase 4 PPA revision).
Frozen Phase 2 version (the one behind the earlier 269/269 log): `phase4_synthesis/rtl_reference/sarcathon_axi_pcie_bridge_phase2.v`
(SHA-256 `cb71c2a9…0875`, identical to the earlier `SOURCE_MANIFEST.md` entry).

## Architecture

```
            AXI4 slave                                    abstract TLP interface
 AW ──► [AW check: size/burst/len/align/4 KiB] ──┐
 W  ──► [W FIFO, W_FIFO_DEPTH x (data, strb_ok, last)] ──► [burst collector] ──► wr_packet_data ─┐
 B  ◄── [single B slot] ◄──────── TX accept (OK) / local SLVERR ◄───────────────────────────────┤
 AR ──► [AR check] ──► [tag allocator: TAG_COUNT tags] ──► [read-pending pick] ─┐               │
                         │                                                      ▼               ▼
                         └─► [response-order queue (AR order)]           [TX arbiter: writes first] ─► tx_tlp_*
 R  ◄── [R beat mux: head tag, r_beat] ◄── tag_data[tag] ◄── rx_cpl_* (any order, matched by tag)
```

| Feature | Implementation |
|---|---|
| Buffering | W-data FIFO (`W_FIFO_DEPTH`, default `2*MAX_BEATS`) decouples W beats from AW and downstream acceptance; W may run ahead of AW. |
| Burst coalescing | One MemWr TLP per AXI write burst and one MemRd TLP per read burst (`tx_tlp_len` in beats, payload up to `MAX_BEATS` beats). |
| Multiple outstanding reads | `TAG_COUNT` tags; completion matched by tag; completions accepted only for sent, not-yet-completed tags. |
| Ordering | AXI R returned in AR acceptance order even when completions arrive out of order (response-order queue). |
| Write pipelining (Phase 4) | Next AW accepted as soon as the previous write TLP is accepted downstream, without waiting for the AXI B handshake; the single B slot gates only the final beat / TLP launch. |
| Protocol checks | Full-width size, INCR only, `len+1 <= MAX_BEATS`, natural alignment, 4 KiB crossing; partial WSTRB and wrong WLAST position. Bad reads → one SLVERR beat; bad writes → drained, SLVERR, no TLP. |
| Parameters | `DATA_WIDTH` (≥16), `ADDR_WIDTH` (≥12), `AXI_ID_WIDTH`, `MAX_BEATS`, `TAG_COUNT`, `W_FIFO_DEPTH`. Elaborates and lints clean (Verilator `-Wall`) across 9 parameter sets (`phase2_architecture/logs/lint_verilator.log`, `phase4_synthesis/reports/param_sweep.rpt`). |

## Measured throughput (same workload on every design)

`phase2_architecture/tb_perf_baseline.v` / `tb_perf_enhanced.v`: 16 bursts × 4 beats, 64-bit data, AXI master and
endpoint always ready, read completions returned `lat` cycles after the MemRd TLP is accepted.
Read data is checked beat by beat (0 data errors in every run). Log: `phase2_architecture/logs/perf_throughput.log`.

| Scenario | Stage 1 baseline | Phase 2 RTL | Phase 4 RTL | Phase 4 vs Stage 1 |
|---|---:|---:|---:|---:|
| 64-beat write, cycles | 209 | 129 | **114** | 1.83× faster |
| Write beats/cycle | 0.306 | 0.496 | **0.561** | |
| 64-beat read, latency 8, cycles | 721 | 77 | **77** | 9.4× faster |
| 64-beat read, latency 32, cycles | 2257 | 173 | **173** | 13.0× faster |
| TLPs for 64 beats | 64 | 16 | 16 | 4× fewer |

The Phase 2 → Phase 4 write gain (129 → 114 cycles, +13 %) comes from accepting the next AW while
the previous B response is still pending (exercised 24× per regression run, see Phase 3).

### Read latency hiding vs `TAG_COUNT` (Phase 4 RTL, read beats/cycle)

| TAG_COUNT | lat 8 | lat 32 | lat 64 |
|---:|---:|---:|---:|
| 1 | 0.249 | 0.100 | 0.056 |
| 2 | 0.481 | 0.197 | 0.110 |
| 4 (default) | 0.831 | 0.370 | 0.213 |
| 8 | 0.831 | 0.587 | 0.370 |
| 16 | 0.831 | 0.634 | 0.481 |

Read throughput saturates at ~0.83 beats/cycle once `TAG_COUNT × beats_per_burst` covers the
round-trip latency. Sizing rule: `TAG_COUNT ≳ (completion latency + burst length) / burst length`.
Each extra tag costs `DATA_WIDTH*MAX_BEATS` storage flops (256 flops at the defaults), so
`TAG_COUNT` is the main area-vs-latency-tolerance knob.

## Coalescing evaluation: can consecutive AXI beats become larger PCIe requests?

* **Within a burst — implemented.** One TLP per AXI burst. For 64-bit beats and 4-beat bursts
  that is 32 B of payload per TLP instead of 8 B. Approximate link efficiency with ~24 B of
  per-TLP overhead (16 B 4DW header + sequence number, LCRC and framing in non-FLIT mode):
  8/(8+24) ≈ 25 % → 32/(32+24) ≈ 57 %; `MAX_BEATS=16` (128 B) → ≈ 84 %. These are
  back-of-envelope estimates, not measurements; PCIe 6.0 FLIT-mode overheads differ.
* **Limits.** Payload must not exceed the link's Max_Payload_Size (128 B minimum ⇒
  `MAX_BEATS*DATA_WIDTH/8 ≤ 128` for guaranteed interoperability) and read requests must not
  exceed Max_Read_Request_Size; requests must not cross 4 KiB (enforced).
* **Across AXI bursts — evaluated, not implemented.** Merging two address-contiguous bursts into
  one TLP would save headers, but each AXI burst still needs its own B/R response (and its own
  ID ordering), errors would have to be split back per burst, and it adds a timeout/hold
  decision on the write path. The gain is bounded by raising `MAX_BEATS` instead, so it was not
  worth the verification risk in this stage.

## Known throughput limits and trade-offs

* **Write path ≈ 7 cycles per 4-beat burst** (ideal 4). The collection register also sources
  `tx_tlp_data` (saves 256 flops — see Phase 4), so the next burst cannot start collecting until
  the current write TLP is accepted. A ping-pong collection buffer would approach 1 beat/cycle
  for writes at a cost of ~256 flops (~+6–8 % area). Not implemented; documented as the next step.
* Writes have strict priority over reads at the TX arbiter (reads can be delayed by a write
  stream, not starved indefinitely, because writes are serialized by the collector).
* One write burst is collected at a time; the single B slot is shared.

## Phase 2 checklist

- [x] Compile with Icarus and inspect every warning — only "@* is sensitive to all words in
      array" notes from Icarus; Verilator `-Wall` lint is clean.
- [x] FIFO empty/full/wraparound and simultaneous push/pop — FIFO-full directed test, white-box
      occupancy assertion every cycle, W-before-AW traffic (Phase 3).
- [x] Tag exhaustion, reuse, duplicate/stale/unknown completions, reset while tags allocated (Phase 3).
- [x] Parameter sweep elaboration — 9 sets, synthesis elaboration + Verilator lint.
- [x] Measured latency/throughput against the frozen Stage 1 baseline (table above).
- [x] Synthesis before any area/timing claim — Phase 4.

## Scope boundary
The TLP signals are abstract packet-level signals. They are not a complete PCIe 6.0 link, FLIT,
CRC/FEC, or PHY implementation.
