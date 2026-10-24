#!/usr/bin/env python3
"""Write a simulation copy of the frozen Phase 2 RTL with one declaration moved.

The frozen Phase 2 RTL uses `wr_collecting` (line 119) before declaring it
(line 144). Icarus 12 and Yosys accept this; Icarus 14 and Verilator reject
it. The frozen file is never modified: this script writes a copy with the
`reg wr_busy, wr_collecting, wr_packet_pending;` line moved above its first
use, and nothing else changed, so the reference can be simulated for the
throughput comparison.

Usage: python phase4_synthesis/ref_declfix.py <output.v>
"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "phase4_synthesis" / "rtl_reference" / "sarcathon_axi_pcie_bridge_phase2.v"
DECL = "    reg wr_busy, wr_collecting, wr_packet_pending;\n"
ANCHOR = "    wire w_push = s_axi_wvalid && s_axi_wready;\n"


def main():
    text = SRC.read_text().replace("\r\n", "\n")
    assert text.count(DECL) == 1 and text.count(ANCHOR) == 1, "unexpected reference RTL"
    text = text.replace(DECL, "").replace(ANCHOR, DECL + ANCHOR)
    out = Path(sys.argv[1])
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(text)
    print(f"wrote {out} (declaration of wr_busy/wr_collecting/wr_packet_pending moved before use)")


if __name__ == "__main__":
    main()
