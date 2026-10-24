#!/usr/bin/env bash
# SARCathon 2026 - reproduce every Phase 1-4 result (Phase 5 runs in Colab).
# Needs iverilog/vvp; uses verilator, yosys and python3 when present.
# With the YosysHQ OSS CAD Suite: export OSS_CAD_SUITE=/path/to/oss-cad-suite
# Layout: rtl/ (current design), phase1_baseline_audit/ ... phase5_physical_design/;
# each phase's logs are written into that phase's folder; build/ holds simulators.
# Usage: bash run_all.sh [--quick]
set -euo pipefail
cd "$(dirname "$0")"

RTL=rtl/sarcathon_axi_pcie_bridge.v
P1=phase1_baseline_audit
P2=phase2_architecture
P3=phase3_verification
P4=phase4_synthesis

if [[ -n "${OSS_CAD_SUITE:-}" ]]; then export PATH="$OSS_CAD_SUITE/bin:$PATH"; fi
have() { command -v "$1" >/dev/null 2>&1; }
section() { printf '\n=== %s ===\n' "$1"; }
require_pass() { grep -Eq "$2" "$1" || { echo "$3 failed; inspect $1" >&2; exit 1; }; }
have iverilog && have vvp || { echo "iverilog/vvp not found" >&2; exit 1; }
PY=${PYTHON:-python3}
YOSYS=${YOSYS:-yosys}
mkdir -p build "$P2/logs" "$P3/logs" "$P4/logs"
SEEDS=(13579bdf 00000001 deadbeef 2468ace0 0badf00d 12345678 cafef00d 7fffffff)
iverilog -V 2>&1 | head -n1 > tool_versions.log || true

section "PHASE 1: FROZEN STAGE 1 BASELINE"
iverilog -g2012 -Wall -s tb_axi4_to_pcie_bridge -o build/stage1_sim "$P1/stage1_baseline_axi4_to_pcie_bridge.v" "$P1/stage1_baseline_tb_axi4_to_pcie_bridge.v"
# Run inside the phase folder so the testbench's VCD (bridge_stage1.vcd) lands there.
(cd "$P1" && vvp -n ../build/stage1_sim > stage1_baseline.log)
tail -n 8 "$P1/stage1_baseline.log"
require_pass "$P1/stage1_baseline.log" 'RESULT[[:space:]]*:[[:space:]]*ALL TESTS PASSED' "Stage 1 baseline"
if grep -q 'FAIL:' "$P1/stage1_baseline.log"; then echo "Stage 1 baseline has FAIL entries" >&2; exit 1; fi

section "PHASE 3: REGRESSION (default seed)"
iverilog -g2012 -Wall -s tb_phase3_axi_pcie_bridge -o build/phase3_sim "$RTL" "$P3/tb_phase3_axi_pcie_bridge.v"
vvp -n build/phase3_sim > "$P3/phase3_regression.log"; tail -n 40 "$P3/phase3_regression.log"
require_pass "$P3/phase3_regression.log" 'RESULT: ALL PHASE 3 CHECKS PASSED' "Phase 3 regression"
if [[ "${1:-}" == "--quick" ]]; then echo "Quick run passed."; exit 0; fi

section "PHASE 3: MULTI-SEED REGRESSION"
: > "$P3/logs/phase3_seed_summary.log"
for s in "${SEEDS[@]}"; do
  log="$P3/logs/phase3_seed_$s.log"
  vvp -n build/phase3_sim "+seed=$s" > "$log"
  require_pass "$log" 'RESULT: ALL PHASE 3 CHECKS PASSED' "Phase 3 seed $s"
  echo "$s  $(grep 'REGRESSION SUMMARY' "$log")  $(grep '^Assertion checks' "$log")" | tee -a "$P3/logs/phase3_seed_summary.log"
done

section "PHASE 2: DIRECTED TESTBENCH ON CURRENT RTL"
iverilog -g2012 -s tb_sarcathon_axi_pcie_bridge -o build/phase2_sim "$RTL" "$P2/tb_phase2_directed_axi_pcie_bridge.v"
vvp -n build/phase2_sim > "$P2/logs/phase2_directed.log"
require_pass "$P2/logs/phase2_directed.log" 'RESULT: ALL TESTS PASSED' "Phase 2 directed testbench"
grep 'TEST SUMMARY' "$P2/logs/phase2_directed.log"

section "PHASE 2: THROUGHPUT (same workload on all designs)"
"$PY" "$P4/ref_declfix.py" build/ref_declfix.v
iverilog -g2012 -s tb_perf_baseline -o build/perf_base "$P1/stage1_baseline_axi4_to_pcie_bridge.v" "$P2/tb_perf_baseline.v"
iverilog -g2012 -s tb_perf_enhanced -o build/perf_ref build/ref_declfix.v "$P2/tb_perf_enhanced.v"
iverilog -g2012 -s tb_perf_enhanced -o build/perf_opt "$RTL" "$P2/tb_perf_enhanced.v"
PERF="$P2/logs/perf_throughput.log"
: > "$PERF"
for lat in 8 32; do
  for sim in perf_base perf_ref perf_opt; do
    vvp -n "build/$sim" "+lat=$lat" | grep -E 'scenario|errors|TIMEOUT' | sed "s/^/[$sim] /" >> "$PERF"
  done
done
for t in 1 2 4 8 16; do
  iverilog -g2012 "-DPERF_TAGS=$t" -s tb_perf_enhanced -o "build/perf_t$t" "$RTL" "$P2/tb_perf_enhanced.v"
  for lat in 8 32 64; do
    vvp -n "build/perf_t$t" "+lat=$lat" | grep -E 'scenario=read|errors|TIMEOUT' | sed "s/^/[tags=$t] /" >> "$PERF"
  done
done
head -n 18 "$PERF"
if grep -Eq 'TIMEOUT|data_errors=[1-9]' "$PERF"; then echo "throughput run reported errors" >&2; exit 1; fi

if have verilator; then
  section "LINT: Verilator -Wall over the parameter sweep"
  LINT="$P2/logs/lint_verilator.log"
  : > "$LINT"
  for g in "" "-GDATA_WIDTH=32" "-GDATA_WIDTH=128" "-GMAX_BEATS=1 -GTAG_COUNT=1 -GW_FIFO_DEPTH=2" \
           "-GMAX_BEATS=8 -GTAG_COUNT=8" "-GTAG_COUNT=3 -GW_FIFO_DEPTH=5" \
           "-GADDR_WIDTH=64 -GAXI_ID_WIDTH=8" "-GMAX_BEATS=16 -GTAG_COUNT=16 -GW_FIFO_DEPTH=32"; do
    # shellcheck disable=SC2086
    if verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-EOFNEWLINE --top-module sarcathon_axi_pcie_bridge $g "$RTL" >> "$LINT" 2>&1; then
      echo "${g:-(defaults)}  rc=0" | tee -a "$LINT"
    else
      echo "Verilator lint failed for '${g}'" >&2; exit 1
    fi
  done
else
  echo "Verilator not found: lint skipped."
fi

section "PHASE 4: SYNTHESIS / PPA (Yosys + SKY130 HD)"
"$PY" "$P4/run_synth.py" 2>&1 | tee "$P4/logs/phase4_synth.log"

if have "$YOSYS"; then
  section "PHASE 4: GATE-LEVEL SIMULATION OF THE SYNTHESIZED NETLIST"
  LIB=$P4/lib/sky130_fd_sc_hd__tt_025C_1v80.lib
  DU="-dont_use sky130_fd_sc_hd__lpflow_* -dont_use sky130_fd_sc_hd__probe_p_* -dont_use sky130_fd_sc_hd__probec_p_*"
  mkdir -p "$P4/gls"
  "$YOSYS" -q -l "$P4/gls/gls_synth.log" -p "read_liberty -lib $LIB; read_verilog -sv $RTL; chparam -set DATA_WIDTH 32 -set MAX_BEATS 4 -set TAG_COUNT 4 -set W_FIFO_DEPTH 8 sarcathon_axi_pcie_bridge; hierarchy -check -top sarcathon_axi_pcie_bridge; synth -top sarcathon_axi_pcie_bridge -flatten; dfflibmap -liberty $LIB $DU; abc -liberty $LIB -D 10000 $DU; setundef -zero; hilomap -hicell sky130_fd_sc_hd__conb_1 HI -locell sky130_fd_sc_hd__conb_1 LO; opt_clean -purge; check -assert; tee -q -o $P4/gls/netlist_dw32.stat.rpt stat -liberty $LIB; write_verilog -noattr $P4/gls/sarcathon_axi_pcie_bridge_dw32.netlist.v" > /dev/null
  "$YOSYS" -q -l "$P4/gls/gls_flatten.log" -p "read_liberty -ignore_miss_func -ignore_miss_dir -ignore_miss_data_latch $LIB; read_verilog $P4/gls/sarcathon_axi_pcie_bridge_dw32.netlist.v; hierarchy -check -top sarcathon_axi_pcie_bridge; flatten; opt_clean; write_verilog -noattr build/sarcathon_axi_pcie_bridge_dw32.flat_gl.v" > /dev/null
  iverilog -g2012 -DGATE_LEVEL -s tb_phase3_axi_pcie_bridge -o build/gls_sim build/sarcathon_axi_pcie_bridge_dw32.flat_gl.v "$P3/tb_phase3_axi_pcie_bridge.v"
  : > "$P4/logs/gls_summary.log"
  for s in "${SEEDS[@]:0:3}"; do
    log="$P4/logs/gls_seed_$s.log"
    vvp -n build/gls_sim "+seed=$s" > "$log"
    require_pass "$log" 'RESULT: ALL PHASE 3 CHECKS PASSED' "Gate-level simulation seed $s"
    echo "$s  $(grep 'REGRESSION SUMMARY' "$log")  $(grep '^Assertion checks' "$log")" | tee -a "$P4/logs/gls_summary.log"
  done
else
  echo "Yosys not found: gate-level simulation skipped."
fi

echo "All Phase 1-4 checks passed. Logs are in each phase folder. Phase 5: phase5_physical_design/SARCathon_Phase5_LibreLane.ipynb (Colab)."
