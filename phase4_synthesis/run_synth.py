#!/usr/bin/env python3
"""Phase 4 synthesis / PPA driver (Yosys + ABC, SkyWater SKY130 HD).

Runs the same synthesis script and the same constraints on every design
configuration, then writes per-design reports and a summary table:

  phase4_synthesis/reports/<cfg>.yosys.log      full Yosys log
  phase4_synthesis/reports/<cfg>.stat.rpt       cell/area report (stat -liberty)
  phase4_synthesis/reports/<cfg>.netlist.v      mapped gate-level netlist
  phase4_synthesis/reports/param_sweep.rpt      elaboration sweep of RTL parameters
  phase4_synthesis/reports/ppa_summary.md/.json comparison table

Run from the project root:   python phase4_synthesis/run_synth.py
Yosys binary: $YOSYS, else `yosys` on PATH, else `yowasp-yosys` (pip).
All paths passed to Yosys are relative to the project root because the
YoWASP (WebAssembly) build can only see the current directory tree.

What this measures and what it does not:
* Cell area and cell counts are exact for the mapped netlist (pre-placement,
  no fill/tap/CTS buffers).
* Leakage is the sum of liberty cell_leakage_power over instances
  (typical corner). Dynamic power needs switching activity and is reported
  by the Phase 5 OpenROAD flow, not here.
* "ABC delay" is ABC's library-aware combinational path estimate for the
  clock target. It excludes clock-to-Q, setup, wire load and clock skew.
  Signoff timing comes from OpenSTA in the Phase 5 LibreLane flow.
"""
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
os.chdir(ROOT)

LIB_REL = "phase4_synthesis/lib/sky130_fd_sc_hd__tt_025C_1v80.lib"
# Pinned to an OpenROAD-flow-scripts commit so the library is reproducible.
LIB_URL = ("https://raw.githubusercontent.com/The-OpenROAD-Project/"
           "OpenROAD-flow-scripts/{rev}/flow/platforms/sky130hd/lib/"
           "sky130_fd_sc_hd__tt_025C_1v80.lib")
LIB_REV = os.environ.get("SKY130_LIB_REV", "b5dceb3c08fd30c9a1c5c0587bc6a57e0392080a")

CLOCK_PERIOD_NS = float(os.environ.get("CLOCK_PERIOD_NS", "10.0"))
REPORTS = Path("phase4_synthesis/reports")
# Cells the sky130A PDK/LibreLane keep out of synthesis (power-management,
# keep-alive and probe cells). Excluded identically for every configuration.
DONT_USE = ["sky130_fd_sc_hd__lpflow_*", "sky130_fd_sc_hd__probe_p_*",
            "sky130_fd_sc_hd__probec_p_*"]
DONT_USE_ARGS = " ".join(f"-dont_use {c}" for c in DONT_USE)
# ABC timing script: map, report, then buffer/size for the delay target and
# report again. `stime -p` prints the critical path cell by cell.
ABC_TIMING_SCRIPT = """strash
&get -n
&fraig -x
&put
scorr
dc2
dretime
strash
&get -n
&dch -f
&nf -D {p}
&put
topo
stime -p
buffer -p
upsize -D {p}
dnsize -D {p}
stime -p
"""

CONFIGS = [
    # name, files, top, parameter overrides
    ("stage1_baseline",
     ["phase1_baseline_audit/stage1_baseline_axi4_to_pcie_bridge.v"], "axi4_to_pcie_bridge", {}),
    ("phase2_reference",
     ["phase4_synthesis/rtl_reference/sarcathon_axi_pcie_bridge_phase2.v"],
     "sarcathon_axi_pcie_bridge", {}),
    ("phase4_opt_fifo16",
     ["rtl/sarcathon_axi_pcie_bridge.v"], "sarcathon_axi_pcie_bridge",
     {"W_FIFO_DEPTH": 16}),
    ("phase4_optimized",
     ["rtl/sarcathon_axi_pcie_bridge.v"], "sarcathon_axi_pcie_bridge", {}),
]

SWEEP = [
    {"DATA_WIDTH": 32, "MAX_BEATS": 4, "TAG_COUNT": 4, "W_FIFO_DEPTH": 8},
    {"DATA_WIDTH": 64, "MAX_BEATS": 4, "TAG_COUNT": 4, "W_FIFO_DEPTH": 8},
    {"DATA_WIDTH": 128, "MAX_BEATS": 4, "TAG_COUNT": 4, "W_FIFO_DEPTH": 8},
    {"DATA_WIDTH": 64, "MAX_BEATS": 1, "TAG_COUNT": 1, "W_FIFO_DEPTH": 2},
    {"DATA_WIDTH": 64, "MAX_BEATS": 2, "TAG_COUNT": 2, "W_FIFO_DEPTH": 4},
    {"DATA_WIDTH": 64, "MAX_BEATS": 8, "TAG_COUNT": 8, "W_FIFO_DEPTH": 16},
    {"DATA_WIDTH": 64, "MAX_BEATS": 16, "TAG_COUNT": 16, "W_FIFO_DEPTH": 32},
    {"DATA_WIDTH": 64, "MAX_BEATS": 4, "TAG_COUNT": 3, "W_FIFO_DEPTH": 5},
    {"DATA_WIDTH": 64, "ADDR_WIDTH": 64, "AXI_ID_WIDTH": 8,
     "MAX_BEATS": 4, "TAG_COUNT": 4, "W_FIFO_DEPTH": 8},
]


def find_yosys():
    exe = os.environ.get("YOSYS")
    if exe:
        return [exe]
    for name in ("yosys", "yowasp-yosys"):
        path = shutil.which(name)
        if path:
            return [path]
    user_scripts = Path(os.environ.get("APPDATA", "")) / "Python" / \
        f"Python{sys.version_info.major}{sys.version_info.minor}" / "Scripts" / "yowasp-yosys.exe"
    if user_scripts.exists():
        return [str(user_scripts)]
    sys.exit("No Yosys found: set $YOSYS, install Yosys, or `pip install yowasp-yosys`.")


def ensure_lib():
    lib = Path(LIB_REL)
    if not lib.exists():
        lib.parent.mkdir(parents=True, exist_ok=True)
        url = LIB_URL.format(rev=LIB_REV)
        print(f"Downloading {url}")
        urllib.request.urlretrieve(url, lib)
    digest = hashlib.sha256(lib.read_bytes()).hexdigest()
    return lib, digest


def parse_leakage(lib_text):
    """Map cell name -> cell_leakage_power (library units, nW for sky130)."""
    leak = {}
    starts = list(re.finditer(r'\bcell\s*\(\s*"?([A-Za-z0-9_]+)"?\s*\)\s*\{', lib_text))
    for idx, m in enumerate(starts):
        end = starts[idx + 1].start() if idx + 1 < len(starts) else len(lib_text)
        lm = re.search(r"cell_leakage_power\s*:\s*([0-9.eE+-]+)", lib_text[m.end():end])
        if lm:
            leak[m.group(1)] = float(lm.group(1))
    unit = re.search(r'leakage_power_unit\s*:\s*"?([0-9]*[a-zA-Z]+)"?', lib_text)
    unit_str = unit.group(1) if unit else "?"
    return leak, (unit_str[1:] if unit_str.startswith("1") else unit_str)


def run_yosys(yosys, script, log):
    proc = subprocess.run(yosys + ["-q", "-l", log, "-p", script],
                          capture_output=True, text=True)
    return proc.returncode, proc.stdout + proc.stderr


def front_end(files, top, params, lib):
    chparams = "".join(f"chparam -set {k} {v} {top}; " for k, v in params.items())
    return (
        f"read_liberty -lib {lib}; "
        f"read_verilog -sv {' '.join(files)}; {chparams}"
        f"hierarchy -check -top {top}; "
        f"synth -top {top} -flatten; "
        f"dfflibmap -liberty {lib} {DONT_USE_ARGS}; "
    )


def timing(yosys, name, files, top, params, lib, period_ns):
    """ABC library-aware delay estimate + critical path for one clock target."""
    period_ps = int(period_ns * 1000)
    tag = f"{name}.timing_{period_ps}ps"
    abc_script = REPORTS / f"abc_timing_{period_ps}.script"
    abc_script.write_text(ABC_TIMING_SCRIPT.format(p=period_ps))
    log = f"{REPORTS.as_posix()}/{tag}.log"
    script = front_end(files, top, params, lib) + (
        f"abc -liberty {lib} -D {period_ps} {DONT_USE_ARGS} "
        f"-script {abc_script.as_posix()}; "
        f"opt_clean -purge; tee -q -o {REPORTS.as_posix()}/{tag}.stat.rpt stat -liberty {lib}"
    )
    rc, out = run_yosys(yosys, script, log)
    if rc != 0:
        raise RuntimeError(f"{tag}: Yosys failed (rc={rc})\n{out[-3000:]}")
    text = Path(log).read_text(errors="replace")
    delays = [float(d) for d in re.findall(r"Delay\s*=\s*([0-9.]+)\s*ps", text)]
    endpoints = re.findall(r"Start-point = (.*?)\.\s+End-point = (.*?)\.\s*$", text, re.M)
    # Keep the cell-by-cell path of the last (post-sizing) stime report.
    blocks = re.findall(r"((?:ABC: Path\s+\d+ --.*\n)+ABC: Start-point.*)", text)
    path = []
    if blocks:
        for line in blocks[-1].splitlines():
            m = re.search(r"Path\s+(\d+) --\s+\d+ :\s*(\d+)\s+(\d+)\s+(\S+).*?Df =\s*([0-9.]+)", line)
            if m:
                path.append({"stage": int(m.group(1)), "fanin": int(m.group(2)),
                             "fanout": int(m.group(3)),
                             "cell": m.group(4).replace("sky130_fd_sc_hd__", ""),
                             "arrival_ps": float(m.group(5))})
    rpt = [f"# {name}: ABC timing at {period_ns} ns target (typical corner, no wire load)",
           f"unbuffered delay : {delays[0]:.0f} ps" if delays else "unbuffered delay : n/a",
           f"after buffer/size: {delays[-1]:.0f} ps" if len(delays) > 1 else "",
           ""]
    for (start, end), label in zip(endpoints, ["unbuffered", "after buffer/size"]):
        rpt.append(f"{label}: start={start} end={end}")
    rpt.append("")
    rpt += [f"  {p['stage']:>2}  {p['cell']:<22} fanout={p['fanout']:<4} arrival={p['arrival_ps']:.0f} ps"
            for p in path]
    (REPORTS / f"{tag}.critical_path.rpt").write_text("\n".join(rpt) + "\n")
    return {
        "unbuffered_ps": delays[0] if delays else None,
        "sized_ps": delays[-1] if len(delays) > 1 else None,
        "endpoints": [{"start": s, "end": e} for s, e in endpoints],
        "critical_path": path,
    }


def synth(yosys, name, files, top, params, lib):
    period_ps = int(CLOCK_PERIOD_NS * 1000)
    stat_rpt = f"{REPORTS.as_posix()}/{name}.stat.rpt"
    netlist = f"{REPORTS.as_posix()}/{name}.netlist.v"
    log = f"{REPORTS.as_posix()}/{name}.yosys.log"
    script = (
        front_end(files, top, params, lib) +
        f"abc -liberty {lib} -D {period_ps} {DONT_USE_ARGS}; "
        f"setundef -zero; "
        f"hilomap -hicell sky130_fd_sc_hd__conb_1 HI -locell sky130_fd_sc_hd__conb_1 LO; "
        f"opt_clean -purge; "
        f"check -assert; "
        f"tee -q -o {stat_rpt} stat -liberty {lib}; "
        f"write_verilog -noattr {netlist}"
    )
    rc, out = run_yosys(yosys, script, log)
    if rc != 0:
        raise RuntimeError(f"{name}: Yosys failed (rc={rc})\n{out[-3000:]}")
    return Path(stat_rpt), Path(log)


def parse_stat(stat_path, leak):
    text = stat_path.read_text()
    area = float(re.search(r"Chip area for module .*?:\s*([0-9.]+)", text).group(1))
    cells = {}
    for m in re.finditer(r"^\s*(\d+)\s+(?:[0-9.Ee+-]+\s+)?(sky130_fd_sc_hd__\w+)\s*$", text, re.M):
        cells[m.group(2)] = cells.get(m.group(2), 0) + int(m.group(1))
    n_cells = sum(cells.values())
    seq = {c: n for c, n in cells.items() if re.search(r"__(e?df|dl|sdf)", c)}
    n_seq = sum(seq.values())
    leakage = sum(n * leak.get(c, 0.0) for c, n in cells.items())
    return {"area_um2": area, "cells": n_cells, "seq_cells": n_seq,
            "comb_cells": n_cells - n_seq, "leakage": leakage,
            "seq_breakdown": seq, "cell_breakdown": cells}


TIMING_TARGETS_NS = [float(t) for t in os.environ.get("TIMING_TARGETS_NS", "10").split(",")]


def param_sweep(yosys):
    lines = ["# Parameter elaboration sweep: hierarchy -check; proc; check -assert",
             f"# RTL: rtl/sarcathon_axi_pcie_bridge.v", ""]
    ok_all = True
    for i, params in enumerate(SWEEP):
        chparams = "".join(f"chparam -set {k} {v} sarcathon_axi_pcie_bridge; "
                           for k, v in params.items())
        log = f"{REPORTS.as_posix()}/sweep_{i}.log"
        script = (f"read_verilog -sv rtl/sarcathon_axi_pcie_bridge.v; {chparams}"
                  f"hierarchy -check -top sarcathon_axi_pcie_bridge; proc; opt -fast; check -assert")
        rc, _ = run_yosys(yosys, script, log)
        status = "PASS" if rc == 0 else "FAIL"
        ok_all &= rc == 0
        lines.append(f"{status}  " + ", ".join(f"{k}={v}" for k, v in params.items()))
        if rc == 0:
            Path(log).unlink(missing_ok=True)
    Path(REPORTS / "param_sweep.rpt").write_text("\n".join(lines) + "\n")
    return ok_all, lines


def main():
    REPORTS.mkdir(parents=True, exist_ok=True)
    yosys = find_yosys()
    lib, lib_sha = ensure_lib()
    leak, leak_unit = parse_leakage(lib.read_text(errors="replace"))
    ver = subprocess.run(yosys + ["-V"], capture_output=True, text=True).stdout.strip()
    print(f"Yosys: {ver}\nLiberty: {lib} sha256={lib_sha}\nClock target: {CLOCK_PERIOD_NS} ns")

    results = {}
    for name, files, top, params in CONFIGS:
        print(f"Synthesizing {name} ...", flush=True)
        stat, log = synth(yosys, name, files, top, params, lib.as_posix())
        r = parse_stat(stat, leak)
        r["params"] = params
        r["timing"] = {}
        for t in TIMING_TARGETS_NS:
            r["timing"][str(t)] = timing(yosys, name, files, top, params, lib.as_posix(), t)
        results[name] = r
        t0 = r["timing"][str(TIMING_TARGETS_NS[0])]
        print(f"  area={r['area_um2']:.1f} um2 cells={r['cells']} seq={r['seq_cells']} "
              f"leak={r['leakage']:.1f} {leak_unit} delay@{TIMING_TARGETS_NS[0]}ns: "
              f"unbuffered={t0['unbuffered_ps']} sized={t0['sized_ps']} ps")
        for t, tr in r["timing"].items():
            ends = tr["endpoints"][-1] if tr["endpoints"] else {}
            print(f"    @{t}ns sized critical path: {ends.get('start')} -> {ends.get('end')}")

    print("Parameter sweep ...", flush=True)
    sweep_ok, sweep_lines = param_sweep(yosys)
    print("\n".join(sweep_lines))

    base = results["phase2_reference"]["area_um2"]
    tcols = "".join(f" Delay @{t:g} ns unbuf / sized (ps) |" for t in TIMING_TARGETS_NS)
    rows = ["| Configuration | Cell area (um2) | vs Phase 2 | Cells | Sequential | "
            f"Combinational | Leakage ({leak_unit}) |" + tcols,
            "|---|---:|---:|---:|---:|---:|---:|" + "---:|" * len(TIMING_TARGETS_NS)]
    for name, r in results.items():
        delta = (r["area_um2"] / base - 1.0) * 100.0
        tvals = ""
        for t in TIMING_TARGETS_NS:
            tr = r["timing"][str(t)]
            u = f"{tr['unbuffered_ps']:.0f}" if tr["unbuffered_ps"] else "n/a"
            s = f"{tr['sized_ps']:.0f}" if tr["sized_ps"] else "n/a"
            tvals += f" {u} / {s} |"
        rows.append(f"| {name} | {r['area_um2']:.1f} | {delta:+.1f}% | {r['cells']} | "
                    f"{r['seq_cells']} | {r['comb_cells']} | {r['leakage']:.1f} |" + tvals)
    md = [
        "# Phase 4 synthesis summary (generated by phase4_synthesis/run_synth.py)",
        "",
        f"* Tool: {ver}",
        f"* Library: SkyWater SKY130 `sky130_fd_sc_hd`, typical corner tt_025C_1v80 "
        f"(sha256 `{lib_sha}`)",
        f"* Script: synth -flatten; dfflibmap; abc -D {int(CLOCK_PERIOD_NS*1000)}; "
        "identical for every row",
        f"* Clock target: {CLOCK_PERIOD_NS} ns ({1000/CLOCK_PERIOD_NS:.0f} MHz)",
        f"* Excluded cells (all rows): {', '.join(DONT_USE)}",
        "* Area is pre-placement standard-cell area from the unbuffered mapping "
        "(no tap/fill/CTS/resizer buffering).",
        "* Delay columns: ABC `stime` combinational path estimate, first without "
        "buffering, then after ABC buffer/upsize/dnsize. Excludes clock-to-Q, setup, "
        "wire load and skew. Signoff timing is OpenSTA in Phase 5.",
        "* Critical paths: `<cfg>.timing_<ps>ps.critical_path.rpt`.",
        "",
        *rows,
        "",
        f"Parameter elaboration sweep: {'ALL PASS' if sweep_ok else 'FAILURES - see param_sweep.rpt'} "
        f"({len(SWEEP)} configurations)",
        "",
        "## Sequential cell breakdown",
        "",
    ]
    for name, r in results.items():
        md.append(f"* **{name}**: " + ", ".join(f"{c.replace('sky130_fd_sc_hd__','')}={n}"
                                               for c, n in sorted(r["seq_breakdown"].items())))
    (REPORTS / "ppa_summary.md").write_text("\n".join(md) + "\n")
    (REPORTS / "ppa_summary.json").write_text(json.dumps(
        {"yosys": ver, "liberty": str(lib), "liberty_sha256": lib_sha,
         "clock_period_ns": CLOCK_PERIOD_NS, "leakage_unit": leak_unit,
         "param_sweep_pass": sweep_ok, "results": results}, indent=2))
    print("\n".join(rows))
    return 0 if sweep_ok else 1


if __name__ == "__main__":
    sys.exit(main())
