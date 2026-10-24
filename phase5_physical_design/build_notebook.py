#!/usr/bin/env python3
"""Build the self-contained Phase 5 Google Colab notebook.

The notebook embeds the exact RTL, LibreLane configs and pin-order file from
this package (with SHA-256 hashes), installs LibreLane 3.0.16 + the pinned
sky130 PDK via Nix (the method used by LibreLane's official Colab notebook),
runs the full Classic RTL-to-GDSII flow for the optimized design and,
optionally, for the frozen Phase 2 reference, then collects signoff metrics
and packages the results for download.

Run from the project root:   python phase5_physical_design/build_notebook.py
Output: phase5_physical_design/SARCathon_Phase5_LibreLane.ipynb
"""
import base64
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "phase5_physical_design" / "SARCathon_Phase5_LibreLane.ipynb"
LIBRELANE_VERSION = "3.0.16"

EMBED = {
    "optimized/config.json": "phase5_physical_design/config.json",
    "optimized/pin_order.cfg": "phase5_physical_design/pin_order.cfg",
    "optimized/src/sarcathon_axi_pcie_bridge.v": "rtl/sarcathon_axi_pcie_bridge.v",
    "reference/config.json": "phase5_physical_design/config_reference.json",
    "reference/pin_order.cfg": "phase5_physical_design/pin_order.cfg",
    "reference/src/sarcathon_axi_pcie_bridge_phase2.v":
        "phase4_synthesis/rtl_reference/sarcathon_axi_pcie_bridge_phase2.v",
}
# Where each embedded file lives in the submission package (printed by the
# notebook so the hashes can be compared with SOURCE_MANIFEST.md).
PACKAGE_PATH = dict(EMBED)


def md(text):
    return {"cell_type": "markdown", "metadata": {}, "source": text.strip("\n").splitlines(True)}


def code(text, title=None):
    meta = {"cellView": "form"} if title else {}
    return {"cell_type": "code", "metadata": meta, "execution_count": None,
            "outputs": [], "source": text.strip("\n").splitlines(True)}


def main():
    files = {}
    hashes = {}
    for dest, src in EMBED.items():
        data = (ROOT / src).read_bytes()
        files[dest] = base64.b64encode(data).decode("ascii")
        hashes[dest] = hashlib.sha256(data).hexdigest()

    cells = []
    cells.append(md(f"""
# SARCathon 2026 — Phase 5: RTL-to-GDSII (LibreLane {LIBRELANE_VERSION}, SkyWater SKY130)

This notebook hardens the AXI4-to-PCIe-TLP bridge into a **GDSII macro** with the open-source
LibreLane Classic flow (Yosys → OpenROAD floorplan / placement / CTS / routing → OpenSTA →
Magic + KLayout DRC → Netgen LVS → GDSII), using the `sky130A` PDK and the `sky130_fd_sc_hd`
standard-cell library.

**How to run:** `Runtime → Run all`. Installing the tools takes ~10–20 min; each flow run takes
roughly 20–60 min on a free Colab runtime. Keep this browser tab open while it runs. The last
cell downloads `phase5_results.zip` — unzip it into the project's
`phase5_physical_design/results/` folder.

The RTL, configs and pin order are **embedded** below with SHA-256 hashes, so this notebook runs
exactly the files from the submission package (cell 4 prints the hashes; they must match
`SOURCE_MANIFEST.md`).

Cell 7 prints `PHASE 5 SIGNOFF: PASS` only if the flow exits cleanly, every reported DRC/LVS/
timing/antenna count is zero, timing/area/power metrics are present and the GDS checks pass.

Scope: this produces a hardened *macro* (die with 835 signal pins), not a pad-framed chip or an
MPW shuttle submission. The bridge uses an abstract TLP interface, not a PCIe PHY.
"""))

    # --- Cell: Nix (follows LibreLane's official notebook) ---
    cells.append(code(r'''
# @title 1. Set up Nix (from LibreLane's official Colab notebook) {display-mode: "form"}
import os
from pathlib import Path
import subprocess
import sys
import shutil
import tempfile

os.environ["LOCALE_ARCHIVE"] = "/usr/lib/locale/locale-archive"

if "google.colab" in sys.modules:
    if shutil.which("nix-env") is None:
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            installer_path = d / "nix"
            !curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix > {installer_path}
            with subprocess.Popen(
                [
                    "bash",
                    installer_path,
                    "install",
                    "--prefer-upstream-nix",
                    "--no-confirm",
                    "--extra-conf",
                    "extra-substituters = https://nix-cache.fossi-foundation.org\nextra-trusted-public-keys = nix-cache.fossi-foundation.org:3+K59iFwXqKsL7BNu6Guy0v+uTlwsxYQxjspXzqLYQs=\n",
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                encoding="utf8",
            ) as p:
                for line in p.stdout:
                    print(line, end="")
else:
    if shutil.which("nix-env") is None:
        raise RuntimeError("Nix is not installed!")

os.environ["PATH"] = f"/nix/var/nix/profiles/default/bin/:{os.getenv('PATH')}"
''', title=True))

    # --- Cell: LibreLane + PDK (official notebook, version pinned) ---
    cells.append(code(rf'''
# @title 2. Install LibreLane {LIBRELANE_VERSION}, its tools and the pinned sky130 PDK {{display-mode: "form"}}
import os
import sys
import yaml
import subprocess
import IPython

librelane_version = "{LIBRELANE_VERSION}"  # pinned for reproducibility
pdk_root = os.path.expanduser("~/.ciel")
pdk = "sky130"
librelane_ipynb_path = os.path.join(os.getcwd(), "librelane_ipynb")

display(IPython.display.HTML("<h3>Downloading LibreLane…</h3>"))
!rm -rf {{librelane_ipynb_path}}
!mkdir -p {{librelane_ipynb_path}}
!curl -L "https://github.com/librelane/librelane/tarball/{{librelane_version}}" | tar -xzC {{librelane_ipynb_path}} --strip-components 1

try:
    import tkinter
except ImportError:
    if "google.colab" in sys.modules:
        !sudo apt-get install python-tk
import tkinter

display(IPython.display.HTML("<h3>Downloading LibreLane's dependencies (Nix)…</h3>"))
with subprocess.Popen(
    ["nix", "profile", "install", ".#colab-env"],
    cwd=librelane_ipynb_path,
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
    encoding="utf8",
) as p:
    for line in p.stdout:
        print(line, end="")
if p.returncode != 0:
    raise RuntimeError("nix profile install failed")

# Colab's system Python 3.13.16 may lack _opcode in lib-dynload, while the
# Yosys build used by LibreLane invokes an embedded CPython that imports the
# system stdlib. The Nix Python 3.13.9 extension has the same CPython 3.13 ABI.
# Make that extension visible in the system interpreter's standard extension
# directory, then verify it imports before launching the physical-design flow.
import glob, sysconfig
nix_opcode_candidates = glob.glob(
    "/nix/store/*-python3-3.13.9/lib/python3.13/lib-dynload/_opcode.cpython-313-*.so"
)
if nix_opcode_candidates:
    opcode_source = Path(nix_opcode_candidates[0])
    extension_dir = Path(sysconfig.get_config_var("DESTSHARED") or "/usr/lib/python3.13/lib-dynload")
    extension_dir.mkdir(parents=True, exist_ok=True)
    opcode_target = extension_dir / opcode_source.name
    if not opcode_target.exists():
        try:
            shutil.copy2(opcode_source, opcode_target)
        except PermissionError:
            subprocess.check_call(["sudo", "cp", str(opcode_source), str(opcode_target)])
    import _opcode
    print("Python _opcode extension available:", opcode_target)
else:
    print("WARNING: Nix _opcode extension not found; Yosys JsonHeader may fail.")

display(IPython.display.HTML("<h3>Installing LibreLane (pip)…</h3>"))
subprocess.check_call(["pip3", "install", "."], cwd=librelane_ipynb_path)

display(IPython.display.HTML("<h3>Downloading PDK…</h3>"))
import ciel
from ciel.source import StaticWebDataSource

with open(os.path.join(librelane_ipynb_path, "librelane", "pdk_hashes.yaml"), "r") as file:
    pdk_hashes = yaml.safe_load(file)
print("sky130 PDK version:", pdk_hashes[pdk])
ciel.enable(
    ciel.get_ciel_home(pdk_root),
    pdk,
    pdk_hashes[pdk],
    data_source=StaticWebDataSource("https://fossi-foundation.github.io/ciel-releases"),
)
sys.path.insert(0, librelane_ipynb_path)

import logging
logging.getLogger().handlers.clear()
display(IPython.display.HTML("<h3>⭕ Done.</h3>"))
''', title=True))

    cells.append(code(r'''
# @title 3. Record tool versions {display-mode: "form"}
import subprocess, librelane
TOOL_VERSIONS = {"librelane": librelane.__version__, "sky130_pdk": pdk_hashes[pdk]}
for name, cmd in [("yosys", ["yosys", "-V"]), ("openroad", ["openroad", "-version"]),
                  ("magic", ["magic", "--version"]), ("klayout", ["klayout", "-v"])]:
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=120,
                             stdin=subprocess.DEVNULL)
        TOOL_VERSIONS[name] = (out.stdout or out.stderr).strip().splitlines()[0]
    except Exception as e:  # keep going; versions are informational
        TOOL_VERSIONS[name] = f"unavailable ({e})"
for k, v in TOOL_VERSIONS.items():
    print(f"{k:10s} {v}")
''', title=True))

    files_literal = json.dumps(files, indent=0)
    hashes_literal = json.dumps(hashes, indent=1)
    package_literal = json.dumps(PACKAGE_PATH, indent=1)
    cells.append(code(f'''
# @title 4. Write the embedded design files (RTL, configs, pin order) and verify hashes {{display-mode: "form"}}
import base64, hashlib, json, pathlib
WORK = pathlib.Path("/content/sarcathon_phase5")
FILES = json.loads(r"""{files_literal}""")
EXPECTED_SHA256 = json.loads(r"""{hashes_literal}""")
PACKAGE_PATH = json.loads(r"""{package_literal}""")
for rel, b64 in FILES.items():
    path = WORK / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    data = base64.b64decode(b64)
    path.write_bytes(data)
    digest = hashlib.sha256(data).hexdigest()
    assert digest == EXPECTED_SHA256[rel], f"hash mismatch for {{rel}}"
    print(f"{{digest}}  {{rel:55s}} <- {{PACKAGE_PATH[rel]}}")
print("All embedded files verified. Compare these hashes with SOURCE_MANIFEST.md in the package.")
''', title=True))

    cells.append(code(r'''
# @title 5. Run the full Classic flow: optimized design {display-mode: "form"}
import re, subprocess, time

RUN_TAG = "phase5"
SHOW = re.compile(r"(Starting|Finished|Running|step|Step|ERROR|Error|error|WARNING|Deferred|Flow|Checker|complete|failed)")

def run_flow(name):
    design_dir = WORK / name
    cmd = ["librelane", "--pdk-root", pdk_root, "--run-tag", RUN_TAG, "--overwrite", "config.json"]
    print("$", " ".join(cmd), f"(cwd={design_dir})", flush=True)
    t0 = time.time()
    tail = []
    with open(design_dir / "flow_console.log", "w") as log, subprocess.Popen(
        cmd, cwd=design_dir, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True
    ) as p:
        for line in p.stdout:
            log.write(line)
            tail = (tail + [line])[-60:]
            if SHOW.search(line):
                print(line, end="", flush=True)
    rc = p.returncode
    print("".join(tail))
    print(f"\n{name}: librelane exit code {rc} after {(time.time() - t0) / 60:.1f} min")
    return rc

FLOW_RC = {}
FLOW_RC["optimized"] = run_flow("optimized")
''', title=True))

    cells.append(code(r'''
# @title 6. (Optional) Same flow and constraints on the frozen Phase 2 reference RTL {display-mode: "form"}
# The Phase 2 reference is run with RUN_LINTER=false because it uses a signal before its
# declaration (accepted by Yosys, rejected by Verilator); the RTL is kept byte-for-byte.
RUN_REFERENCE = True  # @param {type:"boolean"}
if RUN_REFERENCE:
    FLOW_RC["reference"] = run_flow("reference")
''', title=True))

    cells.append(code(r'''
# @title 7. Collect metrics, congestion and GDS checks; build the Phase 5 checklist {display-mode: "form"}
import json, re, pathlib, subprocess

HEADLINE = [
    ("Instances", "design__instance__count"),
    ("Std-cell area (um^2)", "design__instance__area"),
    ("Core area (um^2)", "design__core__area"),
    ("Die area (um^2)", "design__die__area"),
    ("Die bbox (um)", "design__die__bbox"),
    ("Core bbox (um)", "design__core__bbox"),
    ("Utilization", "design__instance__utilization"),
    ("Setup worst slack, all corners (ns)", "timing__setup__ws"),
    ("Setup TNS (ns)", "timing__setup__tns"),
    ("Hold worst slack, all corners (ns)", "timing__hold__ws"),
    ("Hold TNS (ns)", "timing__hold__tns"),
    ("Setup violations", "timing__setup_vio__count"),
    ("Hold violations", "timing__hold_vio__count"),
    ("Total power (W)", "power__total"),
    ("Internal power (W)", "power__internal__total"),
    ("Switching power (W)", "power__switching__total"),
    ("Leakage power (W)", "power__leakage__total"),
    ("Routed wirelength (um)", "route__wirelength"),
]
# Metrics that must exist for the run to count as verified.
REQUIRED = ["timing__setup__ws", "timing__hold__ws", "power__total", "design__die__bbox"]
# Count metrics that must be zero for signoff (only those present are judged).
ZERO_CHECKS = [
    ("Detailed-route DRC", "route__drc_errors"),
    ("Magic DRC", "magic__drc_error__count"),
    ("KLayout DRC", "klayout__drc_error__count"),
    ("LVS", "design__lvs_error__count"),
    ("Magic/KLayout XOR", "design__xor_difference__count"),
    ("Illegal overlaps", "magic__illegal_overlap__count"),
    ("Setup violations (all corners)", "timing__setup_vio__count"),
    ("Hold violations (all corners)", "timing__hold_vio__count"),
    ("Max slew violations", "design__max_slew_violation__count"),
    ("Max cap violations", "design__max_cap_violation__count"),
    ("Max fanout violations", "design__max_fanout_violation__count"),
    ("Disconnected pins", "design__critical_disconnected_pin__count"),
    ("Power-grid violations", "design__power_grid_violation__count"),
    ("Antenna (KLayout)", "klayout__antenna_error__count"),
    ("Lint errors", "design__lint_error__count"),
    ("Unmapped cells", "design__instance_unmapped__count"),
]
GROUPS = r"(timing__|power__|design__|route__|magic__|klayout__|antenna|ir__|clock__|global_route__|detailedroute__)"
RELATED = re.compile(r"(area|util|power__|wirelength|antenna|ir__drop|clock__skew|overflow|congestion)")

GDS_CHECK = WORK / "gds_check.py"
GDS_CHECK.write_text("""
import json, pya
ly = pya.Layout()
ly.read(gds)
tops = ly.top_cells()
bb = tops[0].dbbox() if tops else pya.DBox()
info = {"file": gds, "top_cells": [c.name for c in tops], "bbox_um": [bb.left, bb.bottom, bb.right, bb.top],
        "width_um": bb.width(), "height_um": bb.height(), "layers": ly.layers(), "cells": ly.cells()}
open(out, "w").write(json.dumps(info))
""")

def gds_info(name, gds):
    out = WORK / f"{name}_{gds.parent.name}_{gds.stem}.gds_check.json"
    try:
        r = subprocess.run(["klayout", "-b", "-r", str(GDS_CHECK), "-rd", f"gds={gds}", "-rd", f"out={out}"],
                           capture_output=True, text=True, timeout=1800)
    except Exception as e:  # missing tool / timeout: report, do not abort the summary
        return {"file": str(gds), "error": f"{type(e).__name__}: {e}"}
    if out.exists():
        return json.loads(out.read_text())
    return {"file": str(gds), "error": (r.stderr or r.stdout)[-600:]}

def congestion(run):
    """OpenROAD prints its congestion table in the global-routing step log."""
    blocks = []
    for d in sorted(run.glob("*globalrouting*")):
        for log in sorted(d.glob("*.log")):
            text = log.read_text(errors="replace")
            i = text.rfind("congestion report")
            if i < 0:
                continue
            block = []
            for ln in text[text.rfind("\n", 0, i) + 1:].splitlines():
                block.append(ln)
                if ln.strip().startswith("Total") or len(block) > 40:
                    break
            blocks.append((f"{d.name}/{log.name}", block))
    return blocks

def load(name):
    run = WORK / name / "runs" / RUN_TAG
    mpath = run / "final" / "metrics.json"
    m = json.loads(mpath.read_text()) if mpath.exists() else None
    rpath = run / "resolved.json"
    resolved = json.loads(rpath.read_text()) if rpath.exists() else {}
    return run, m, resolved

SUMMARY = {"tool_versions": TOOL_VERSIONS, "designs": {}}
lines = ["# Phase 5 implementation summary (generated in Colab)", "",
         "Tools: " + ", ".join(f"{k} {v}" for k, v in TOOL_VERSIONS.items()), ""]
VERDICTS = {}
for name in FLOW_RC:
    run, m, resolved = load(name)
    reasons = []
    period = float(resolved.get("CLOCK_PERIOD", 10.0))
    design_name = resolved.get("DESIGN_NAME", "sarcathon_axi_pcie_bridge")
    d = {"flow_exit_code": FLOW_RC[name], "run_dir": str(run), "clock_period_ns": period}
    lines.append(f"## {name}")
    lines.append(f"* LibreLane exit code: {FLOW_RC[name]} ({'flow completed' if FLOW_RC[name] == 0 else 'flow reported errors - see flow_console.log'})")
    if FLOW_RC[name] != 0:
        reasons.append(f"LibreLane exit code {FLOW_RC[name]}")
    lines.append(f"* Clock period: {period} ns")

    # GDS checks: both stream-outs, one top cell named after the design, size = die.
    gds_files = []
    for sub in ("gds", "klayout_gds"):
        gds_files += sorted((run / "final" / sub).glob("*.gds")) if run.exists() else []
    d["gds"] = [gds_info(name, g) for g in gds_files]
    if not gds_files:
        reasons.append("no GDS in final/gds or final/klayout_gds")
        lines.append("* Final GDS: NOT PRODUCED")
    for g in d["gds"]:
        if "error" in g:
            reasons.append(f"GDS unreadable: {g['file']}")
            lines.append(f"* GDS `{g['file']}`: could not be read ({g['error'][-200:]})")
            continue
        ok_top = g["top_cells"] == [design_name]
        if not ok_top:
            reasons.append(f"unexpected top cell(s) {g['top_cells']} in {pathlib.Path(g['file']).name}")
        lines.append(f"* GDS `{pathlib.Path(g['file']).parent.name}/{pathlib.Path(g['file']).name}`: "
                     f"top cell {g['top_cells']} ({'OK' if ok_top else 'UNEXPECTED'}), "
                     f"{g['width_um']:.2f} x {g['height_um']:.2f} um, {g['layers']} layers, {g['cells']} cells")

    if m is None:
        lines.append("* metrics.json not found (the flow stopped before saving final views)")
        reasons.append("metrics.json missing")
        SUMMARY["designs"][name] = d
        VERDICTS[name] = reasons
        lines.append("")
        continue
    d["metrics"] = {k: v for k, v in m.items() if re.match(GROUPS, k)}
    for key in REQUIRED:
        if key not in m:
            reasons.append(f"required metric {key} missing")
    die_bbox = m.get("design__die__bbox")
    nums = [float(v) for v in re.findall(r"-?\d+(?:\.\d+)?", str(die_bbox))] if die_bbox else []
    if len(nums) == 4 and d["gds"] and "width_um" in d["gds"][0]:
        x0, y0, x1, y1 = nums
        dw, dh = d["gds"][0]["width_um"] - (x1 - x0), d["gds"][0]["height_um"] - (y1 - y0)
        ok_size = abs(dw) < 1.0 and abs(dh) < 1.0
        # Informational: DRC/LVS/XOR are the authoritative layout checks.
        lines.append(f"* GDS size vs die bbox ({x1 - x0:.2f} x {y1 - y0:.2f} um): "
                     f"{'match' if ok_size else f'WARNING: differs by ({dw:+.2f}, {dh:+.2f}) um - inspect the layout'}")

    lines += ["", "| Metric | Key | Value |", "|---|---|---:|"]
    for label, key in HEADLINE:
        lines.append(f"| {label} | `{key}` | {m.get(key, 'n/a')} |")
    ws = m.get("timing__setup__ws")
    if isinstance(ws, (int, float)):
        fmax = 1000.0 / (period - ws)
        d["fmax_estimate_mhz"] = fmax
        lines.append(f"| Fmax estimate from worst setup slack | 1000/(T - WS) | {fmax:.1f} MHz |")

    lines += ["", "| Signoff check | Key | Value | Result |", "|---|---|---:|---|"]
    checks = []
    for label, key in ZERO_CHECKS:
        if key in m:
            ok = (m[key] == 0)
            checks.append((label, key, m[key], ok))
            lines.append(f"| {label} | `{key}` | {m[key]} | {'PASS' if ok else 'FAIL'} |")
            if not ok:
                reasons.append(f"{label} = {m[key]}")
        else:
            lines.append(f"| {label} | `{key}` | n/a | not reported |")
    d["checks"] = [{"check": c[0], "key": c[1], "value": c[2], "pass": c[3]} for c in checks]

    corner_keys = sorted(k for k in m if re.match(r"timing__(setup|hold)__(ws|tns)__corner:", k))
    if corner_keys:
        lines += ["", "Per-corner timing (ns):", ""]
        lines += [f"* `{k}` = {m[k]}" for k in corner_keys]
    related = sorted(k for k in m if RELATED.search(k) and "__corner:" not in k)
    if related:
        lines += ["", "All area / power / routing / IR / skew metrics:", ""]
        lines += [f"* `{k}` = {m[k]}" for k in related]
    cong = congestion(run)
    d["congestion"] = [{"log": src, "report": blk} for src, blk in cong]
    lines += ["", "Global-routing congestion (OpenROAD report, last occurrence per log):", ""]
    if cong:
        for src, blk in cong:
            lines += [f"`{src}`", "```", *blk, "```"]
    else:
        lines.append("* no congestion report found in the global-routing logs")
    lines.append("")
    SUMMARY["designs"][name] = d
    VERDICTS[name] = reasons

if "optimized" in SUMMARY["designs"] and "reference" in SUMMARY["designs"]:
    mo = SUMMARY["designs"]["optimized"].get("metrics", {})
    mr = SUMMARY["designs"]["reference"].get("metrics", {})
    lines += ["## Phase 2 reference vs optimized (same flow, same constraints)", "",
              "| Metric | Reference | Optimized | Change |", "|---|---:|---:|---:|"]
    for label, key in HEADLINE:
        a, b = mr.get(key), mo.get(key)
        if isinstance(a, (int, float)) and isinstance(b, (int, float)) and a not in (0, 0.0):
            lines.append(f"| {label} | {a} | {b} | {(b / a - 1) * 100:+.1f}% |")
        else:
            lines.append(f"| {label} | {a} | {b} | |")
    lines.append("")

lines.append("## Verdict")
for name, reasons in VERDICTS.items():
    if reasons:
        lines.append(f"* **{name}: PHASE 5 SIGNOFF: NOT COMPLETE** - " + "; ".join(reasons))
    else:
        lines.append(f"* **{name}: PHASE 5 SIGNOFF: PASS** (exit 0, GDS checks OK, required metrics present, all reported violation counts 0)")
SUMMARY["verdict"] = {n: ("PASS" if not r else "NOT COMPLETE") for n, r in VERDICTS.items()}
SUMMARY["verdict_reasons"] = VERDICTS

REPORT = "\n".join(lines)
(WORK / "phase5_summary.md").write_text(REPORT)
(WORK / "phase5_summary.json").write_text(json.dumps(SUMMARY, indent=2, default=str))
print(REPORT)
''', title=True))

    cells.append(code(r'''
# @title 8. Render the final GDS to PNG (KLayout) {display-mode: "form"}
import subprocess
from IPython.display import Image, display
RENDER = WORK / "render_gds.py"
RENDER.write_text("""
import pya
lv = pya.LayoutView()
lv.load_layout(gds, True)
lv.max_hier()
lv.zoom_fit()
lv.save_image(png, 1600, 1600)
""")
for name in FLOW_RC:
    for gds in (WORK / name / "runs" / RUN_TAG / "final" / "gds").glob("*.gds"):
        png = WORK / f"{name}_layout.png"
        r = subprocess.run(["klayout", "-b", "-r", str(RENDER), "-rd", f"gds={gds}", "-rd", f"png={png}"],
                           capture_output=True, text=True, timeout=900)
        if png.exists():
            print(name, gds.name)
            display(Image(filename=str(png), width=700))
        else:
            print(f"render failed for {name} (informational only): {r.stderr[-800:]}")
''', title=True))

    cells.append(code(r'''
# @title 9. Package results (summary, all reports and logs, final GDS/LEF/netlists) and download {display-mode: "form"}
import shutil, sys
SAVE_TO_DRIVE = False  # @param {type:"boolean"}
# Every text report/log of every step is kept (per-corner STA max/min/power/skew reports live in
# <step>/<corner>/, DRC/LVS/antenna reports in <step>/reports/ or the step folder itself).
KEEP_SUFFIX = {".rpt", ".log", ".json", ".csv", ".xml", ".txt", ".yaml", ".yml", ".tcl", ".sdc",
               ".cfg", ".lyrdb", ".md"}
MAX_BYTES = 50_000_000
STAGE = pathlib.Path("/content/phase5_results")
shutil.rmtree(STAGE, ignore_errors=True)
STAGE.mkdir()
for f in WORK.glob("*"):
    if f.is_file() and (f.suffix in {".md", ".json", ".png"}):
        shutil.copy(f, STAGE / f.name)
for name in FLOW_RC:
    run = WORK / name / "runs" / RUN_TAG
    dst = STAGE / name
    dst.mkdir()
    if (WORK / name / "flow_console.log").exists():
        shutil.copy(WORK / name / "flow_console.log", dst / "flow_console.log")
    skipped = []
    if run.exists():
        for f in run.rglob("*"):
            if not f.is_file():
                continue
            rel = f.relative_to(run)
            if rel.parts[0] == "final" or f.suffix.lower() not in KEEP_SUFFIX:
                continue
            if f.stat().st_size > MAX_BYTES:
                skipped.append(str(rel))
                continue
            (dst / "run" / rel).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(f, dst / "run" / rel)
        for sub in ["gds", "klayout_gds", "lef", "nl", "pnl", "sdc", "metrics.json", "metrics.csv"]:
            src = run / "final" / sub
            if src.is_dir():
                shutil.copytree(src, dst / "final" / sub)
            elif src.exists():
                (dst / "final").mkdir(parents=True, exist_ok=True)
                shutil.copy(src, dst / "final" / sub)
    if skipped:
        (dst / "skipped_large_files.txt").write_text("\n".join(skipped))
    sta = sorted(p.relative_to(dst).as_posix() for p in dst.rglob("max.rpt"))
    pwr = sorted(p.relative_to(dst).as_posix() for p in dst.rglob("power.rpt"))
    print(f"{name}: {sum(1 for _ in dst.rglob('*') if _.is_file())} files; "
          f"{len(sta)} setup (max.rpt) and {len(pwr)} power reports; GDS: "
          f"{[p.name for p in (dst / 'final').rglob('*.gds')] if (dst / 'final').exists() else []}")
archive = shutil.make_archive("/content/phase5_results", "zip", STAGE)
print(archive, round(pathlib.Path(archive).stat().st_size / 1e6, 1), "MB")
if "google.colab" in sys.modules:
    if SAVE_TO_DRIVE:
        from google.colab import drive
        drive.mount("/content/drive")
        shutil.copy(archive, "/content/drive/MyDrive/phase5_results.zip")
        print("Copied to Google Drive: MyDrive/phase5_results.zip")
    from google.colab import files
    files.download(archive)
''', title=True))

    nb = {
        "nbformat": 4,
        "nbformat_minor": 0,
        "metadata": {
            "colab": {"provenance": [], "name": OUT.name},
            "kernelspec": {"name": "python3", "display_name": "Python 3"},
            "language_info": {"name": "python"},
        },
        "cells": cells,
    }
    OUT.write_text(json.dumps(nb, indent=1))
    print(f"wrote {OUT.relative_to(ROOT)}")
    for dest, h in hashes.items():
        print(f"  {h}  {dest}")


if __name__ == "__main__":
    main()
