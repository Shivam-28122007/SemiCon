# SARCathon 2026 - reproduce every Phase 1-4 result (Phase 5 runs in Colab).
#
# Needs Icarus Verilog (iverilog/vvp). Optional but used when present:
# Verilator (lint), Yosys (synthesis + gate-level netlist), Python 3.
# With the YosysHQ OSS CAD Suite unpacked somewhere, point $env:OSS_CAD_SUITE
# at its folder (the one containing bin\) and everything is found from there.
#
# Layout: rtl\ (current design), phase1_baseline_audit\ ... phase5_physical_design\.
# Each phase's logs are written into that phase's folder; build\ holds simulators.
#
# Usage:  .\run_all.ps1            (full run)
#         .\run_all.ps1 -Quick     (Stage 1 + Phase 3 default seed only)
param([switch]$Quick)
# Native tools print warnings on stderr; PowerShell 5.1 would turn those into
# terminating errors under "Stop", so every native step is checked explicitly.
$ErrorActionPreference = "Continue"
Set-Location $PSScriptRoot

$RTL = "rtl\sarcathon_axi_pcie_bridge.v"
$P1 = "phase1_baseline_audit"
$P2 = "phase2_architecture"
$P3 = "phase3_verification"
$P4 = "phase4_synthesis"

if ($env:OSS_CAD_SUITE) {
    $env:PATH = "$env:OSS_CAD_SUITE\bin;$env:OSS_CAD_SUITE\lib;$env:PATH"
    if (-not $env:VERILATOR_ROOT) { $env:VERILATOR_ROOT = "$env:OSS_CAD_SUITE\share\verilator" }
    if (-not $env:YOSYS) { $env:YOSYS = "$env:OSS_CAD_SUITE\bin\yosys.exe" }
}
function Have($cmd) { [bool](Get-Command $cmd -ErrorAction SilentlyContinue) }
function Find-Python {
    if ($env:PYTHON) { return $env:PYTHON }
    foreach ($c in @("py", "python", "python3")) {
        if (Have $c) {
            try { $v = & $c --version 2>&1; if ("$v" -match "Python 3") { return $c } } catch {}
        }
    }
    $local = "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe"
    if (Test-Path $local) { return $local }
    return $null
}
function Check($what) { if ($LASTEXITCODE -ne 0) { throw "$what failed (exit $LASTEXITCODE)." } }
function Section($t) { Write-Host "`n=== $t ===" -ForegroundColor Cyan }
function Require-Pass($log, $pattern, $what) {
    if (!(Select-String -Path $log -Pattern $pattern)) { throw "$what failed; inspect $log" }
}
if (!(Have "iverilog") -or !(Have "vvp")) { throw "iverilog/vvp not found. Install Icarus Verilog or set OSS_CAD_SUITE." }
New-Item -ItemType Directory -Force build, "$P2\logs", "$P3\logs", "$P4\logs" | Out-Null
$SEEDS = @("13579bdf", "00000001", "deadbeef", "2468ace0", "0badf00d", "12345678", "cafef00d", "7fffffff")
$py = Find-Python
(& iverilog -V 2>&1 | Select-Object -First 1) | Out-File -Encoding utf8 tool_versions.log

Section "PHASE 1: FROZEN STAGE 1 BASELINE"
iverilog -g2012 -Wall -s tb_axi4_to_pcie_bridge -o build\stage1_sim "$P1\stage1_baseline_axi4_to_pcie_bridge.v" "$P1\stage1_baseline_tb_axi4_to_pcie_bridge.v"
if ($LASTEXITCODE -ne 0) { throw "Stage 1 baseline compilation failed." }
# Run inside the phase folder so the testbench's VCD (bridge_stage1.vcd) lands there.
Push-Location $P1
vvp -n ..\build\stage1_sim | Out-File -Encoding utf8 stage1_baseline.log
Pop-Location
Get-Content "$P1\stage1_baseline.log" | Select-Object -Last 8
Require-Pass "$P1\stage1_baseline.log" 'RESULT\s*:\s*ALL TESTS PASSED' "Stage 1 baseline"
if (Select-String -Path "$P1\stage1_baseline.log" -Pattern 'FAIL:') { throw "Stage 1 baseline contains FAIL entries." }

Section "PHASE 3: REGRESSION (default seed)"
iverilog -g2012 -Wall -s tb_phase3_axi_pcie_bridge -o build\phase3_sim $RTL "$P3\tb_phase3_axi_pcie_bridge.v"
if ($LASTEXITCODE -ne 0) { throw "Phase 3 compilation failed." }
vvp -n build\phase3_sim | Out-File -Encoding utf8 "$P3\phase3_regression.log"; Get-Content "$P3\phase3_regression.log" | Select-Object -Last 40
Require-Pass "$P3\phase3_regression.log" 'RESULT: ALL PHASE 3 CHECKS PASSED' "Phase 3 regression"
if ($Quick) { Write-Host "`nQuick run passed." -ForegroundColor Green; exit 0 }

Section "PHASE 3: MULTI-SEED REGRESSION"
$summary = @()
foreach ($s in $SEEDS) {
    $log = "$P3\logs\phase3_seed_$s.log"
    vvp -n build\phase3_sim "+seed=$s" | Out-File -Encoding utf8 $log
    Require-Pass $log 'RESULT: ALL PHASE 3 CHECKS PASSED' "Phase 3 seed $s"
    $line = "{0}  {1}  {2}" -f $s, (Select-String -Path $log -Pattern "REGRESSION SUMMARY").Line,
        (Select-String -Path $log -Pattern "^Assertion checks").Line
    $summary += $line; Write-Host $line
}
$summary | Out-File -Encoding utf8 "$P3\logs\phase3_seed_summary.log"

Section "PHASE 2: DIRECTED TESTBENCH ON CURRENT RTL"
iverilog -g2012 -s tb_sarcathon_axi_pcie_bridge -o build\phase2_sim $RTL "$P2\tb_phase2_directed_axi_pcie_bridge.v"; Check "Phase 2 directed compile"
vvp -n build\phase2_sim | Out-File -Encoding utf8 "$P2\logs\phase2_directed.log"
Require-Pass "$P2\logs\phase2_directed.log" 'RESULT: ALL TESTS PASSED' "Phase 2 directed testbench"
(Select-String -Path "$P2\logs\phase2_directed.log" -Pattern "TEST SUMMARY").Line

Section "PHASE 2: THROUGHPUT (same workload on all designs)"
if (!$py) { throw "Python 3 is needed to prepare the Phase 2 reference simulation copy." }
& $py "$P4\ref_declfix.py" build\ref_declfix.v; Check "Reference simulation copy"
iverilog -g2012 -s tb_perf_baseline -o build\perf_base "$P1\stage1_baseline_axi4_to_pcie_bridge.v" "$P2\tb_perf_baseline.v"; Check "perf_base compile"
iverilog -g2012 -s tb_perf_enhanced -o build\perf_ref build\ref_declfix.v "$P2\tb_perf_enhanced.v"; Check "perf_ref compile"
iverilog -g2012 -s tb_perf_enhanced -o build\perf_opt $RTL "$P2\tb_perf_enhanced.v"; Check "perf_opt compile"
$perf = @()
foreach ($lat in 8, 32) {
    foreach ($sim in "perf_base", "perf_ref", "perf_opt") {
        $perf += vvp -n "build\$sim" "+lat=$lat" | Where-Object { $_ -match 'scenario|errors|TIMEOUT' } | ForEach-Object { "[$sim] $_" }
    }
}
foreach ($t in 1, 2, 4, 8, 16) {
    iverilog -g2012 "-DPERF_TAGS=$t" -s tb_perf_enhanced -o "build\perf_t$t" $RTL "$P2\tb_perf_enhanced.v"; Check "perf_t$t compile"
    foreach ($lat in 8, 32, 64) {
        $perf += vvp -n "build\perf_t$t" "+lat=$lat" | Where-Object { $_ -match 'scenario=read|errors|TIMEOUT' } | ForEach-Object { "[tags=$t] $_" }
    }
}
$perf | Out-File -Encoding utf8 "$P2\logs\perf_throughput.log"
$perf | Select-Object -First 18
if ($perf -match 'TIMEOUT' -or ($perf -match 'data_errors=[1-9]')) { throw "Throughput run reported errors; inspect $P2\logs\perf_throughput.log" }

if (Have "verilator_bin") {
    Section "LINT: Verilator -Wall over the parameter sweep"
    $lint = @()
    foreach ($g in @("", "-GDATA_WIDTH=32", "-GDATA_WIDTH=128", "-GMAX_BEATS=1 -GTAG_COUNT=1 -GW_FIFO_DEPTH=2",
                     "-GMAX_BEATS=8 -GTAG_COUNT=8", "-GTAG_COUNT=3 -GW_FIFO_DEPTH=5",
                     "-GADDR_WIDTH=64 -GAXI_ID_WIDTH=8", "-GMAX_BEATS=16 -GTAG_COUNT=16 -GW_FIFO_DEPTH=32")) {
        $a = @(); if ($g) { $a = $g -split ' ' }
        $out = & verilator_bin --lint-only -Wall -Wno-DECLFILENAME -Wno-EOFNEWLINE --top-module sarcathon_axi_pcie_bridge @a $RTL 2>&1 | ForEach-Object { "$_" }
        $rc = $LASTEXITCODE
        $lint += "{0,-50} rc={1} messages={2}" -f $(if ($g) { $g } else { "(defaults)" }), $rc, @($out | Where-Object { $_ -match '^%' }).Count
        $lint += $out | Where-Object { $_ -match '^%' }
        if ($rc -ne 0) { $lint | Out-File -Encoding utf8 "$P2\logs\lint_verilator.log"; throw "Verilator lint failed for '$g'" }
    }
    $lint | Out-File -Encoding utf8 "$P2\logs\lint_verilator.log"; $lint
} else { Write-Host "Verilator not found: lint skipped." -ForegroundColor Yellow }

Section "PHASE 4: SYNTHESIS / PPA (Yosys + SKY130 HD)"
& $py "$P4\run_synth.py" 2>&1 | ForEach-Object { "$_" } | Where-Object { $_ -notmatch 'cannot access the file' } | Tee-Object -Variable synthOut; $synthRc = $LASTEXITCODE; $synthOut | Out-File -Encoding utf8 "$P4\logs\phase4_synth.log"
if ($synthRc -ne 0) { throw "Phase 4 synthesis failed; inspect $P4\logs\phase4_synth.log" }

$yosys = if ($env:YOSYS) { $env:YOSYS } elseif (Have "yosys") { "yosys" } else { $null }
if ($yosys) {
    Section "PHASE 4: GATE-LEVEL SIMULATION OF THE SYNTHESIZED NETLIST"
    $lib = "$P4/lib/sky130_fd_sc_hd__tt_025C_1v80.lib"
    $du = "-dont_use sky130_fd_sc_hd__lpflow_* -dont_use sky130_fd_sc_hd__probe_p_* -dont_use sky130_fd_sc_hd__probec_p_*"
    New-Item -ItemType Directory -Force "$P4\gls" | Out-Null
    & $yosys -q -l "$P4/gls/gls_synth.log" -p "read_liberty -lib $lib; read_verilog -sv rtl/sarcathon_axi_pcie_bridge.v; chparam -set DATA_WIDTH 32 -set MAX_BEATS 4 -set TAG_COUNT 4 -set W_FIFO_DEPTH 8 sarcathon_axi_pcie_bridge; hierarchy -check -top sarcathon_axi_pcie_bridge; synth -top sarcathon_axi_pcie_bridge -flatten; dfflibmap -liberty $lib $du; abc -liberty $lib -D 10000 $du; setundef -zero; hilomap -hicell sky130_fd_sc_hd__conb_1 HI -locell sky130_fd_sc_hd__conb_1 LO; opt_clean -purge; check -assert; tee -q -o $P4/gls/netlist_dw32.stat.rpt stat -liberty $lib; write_verilog -noattr $P4/gls/sarcathon_axi_pcie_bridge_dw32.netlist.v" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Gate-level netlist synthesis failed; inspect $P4\gls\gls_synth.log" }
    & $yosys -q -l "$P4/gls/gls_flatten.log" -p "read_liberty -ignore_miss_func -ignore_miss_dir -ignore_miss_data_latch $lib; read_verilog $P4/gls/sarcathon_axi_pcie_bridge_dw32.netlist.v; hierarchy -check -top sarcathon_axi_pcie_bridge; flatten; opt_clean; write_verilog -noattr build/sarcathon_axi_pcie_bridge_dw32.flat_gl.v" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Gate-level netlist flattening failed; inspect $P4\gls\gls_flatten.log" }
    iverilog -g2012 -DGATE_LEVEL -s tb_phase3_axi_pcie_bridge -o build\gls_sim build\sarcathon_axi_pcie_bridge_dw32.flat_gl.v "$P3\tb_phase3_axi_pcie_bridge.v"
    if ($LASTEXITCODE -ne 0) { throw "Gate-level testbench compilation failed." }
    $gls = @()
    foreach ($s in $SEEDS[0..2]) {
        $log = "$P4\logs\gls_seed_$s.log"
        vvp -n build\gls_sim "+seed=$s" | Out-File -Encoding utf8 $log
        Require-Pass $log 'RESULT: ALL PHASE 3 CHECKS PASSED' "Gate-level simulation seed $s"
        $gls += "{0}  {1}  {2}" -f $s, (Select-String -Path $log -Pattern "REGRESSION SUMMARY").Line,
            (Select-String -Path $log -Pattern "^Assertion checks").Line
    }
    $gls | Out-File -Encoding utf8 "$P4\logs\gls_summary.log"; $gls
} else { Write-Host "Yosys not found: gate-level simulation skipped." -ForegroundColor Yellow }

Write-Host "`nAll Phase 1-4 checks passed. Logs are in each phase folder. Phase 5: phase5_physical_design\SARCathon_Phase5_LibreLane.ipynb (Colab)." -ForegroundColor Green
