from pathlib import Path
import hashlib, json, re, sys
root=Path(__file__).resolve().parent
rtl=(root/'rtl'/'sarcathon_axi_pcie_bridge.v').read_text()
tb=(root/'phase3_verification'/'tb_phase3_axi_pcie_bridge.v').read_text()
checks=[]
def ck(name, cond):
    checks.append((name,bool(cond)))

def strip_comments(s):
    s=re.sub(r'/\*.*?\*/',' ',s,flags=re.S)
    s=re.sub(r'//[^\n]*',' ',s)
    s=re.sub(r'"(?:\\.|[^"\\])*"','""',s)
    return s
for label, src in [('RTL',rtl),('TB',tb)]:
    clean=strip_comments(src)
    for a,b in [('begin','end'),('case','endcase'),('module','endmodule'),('task','endtask')]:
        ca=len(re.findall(r'\b'+a+r'\b',clean)); cb=len(re.findall(r'\b'+b+r'\b',clean))
        ck(f'{label} token balance {a}/{b}: {ca}/{cb}',ca==cb)
ck('RTL top module exists','module sarcathon_axi_pcie_bridge' in rtl and rtl.count('endmodule')==1)
ck('TB top module exists','module tb_phase3_axi_pcie_bridge' in tb and tb.count('endmodule')==1)
ck('write FIFO present','w_fifo_data' in rtl and 'w_count' in rtl)
ck('multiple read tags present','tag_valid' in rtl and 'tag_pending_tx' in rtl and 'resp_q' in rtl)
ck('address alignment checks present','aw_misaligned' in rtl and 'ar_misaligned' in rtl)
ck('4-KiB crossing checks present','aw_crosses_4k' in rtl and 'ar_crosses_4k' in rtl)
for phrase in ['ARREADY backpressures when all completion tags are allocated','early WLAST burst rejected without TLP','4-KiB-crossing write rejected without TLP','misaligned read rejected without TLP','4-KiB-crossing read rejected without TLP','duplicate/stale completion rejected after retirement','late completion after reset rejected','reset clears partial write collection','fresh write succeeds after partial-write reset',
               'missing/late WLAST burst rejected without TLP','W FIFO full deasserts WREADY','AW accepted while previous B is pending','reset clears stalled B response','reset clears stalled R response','mixed: MemWr in AW order with correct addr/len/data','mixed: MemRd matches an issued AR (addr/len)','TX VALID with X/Z payload']:
    ck('testbench contains: '+phrase,phrase in tb)
ck('testbench accepts +seed= plusarg','$value$plusargs("seed=%h"' in tb)
ck('testbench supports gate-level mode','`ifndef GATE_LEVEL' in tb)
for rel in ['rtl/sarcathon_axi_pcie_bridge.v',
            'phase1_baseline_audit/stage1_baseline_axi4_to_pcie_bridge.v','phase1_baseline_audit/stage1_baseline_tb_axi4_to_pcie_bridge.v',
            'phase1_baseline_audit/BASELINE_MANIFEST.md','phase1_baseline_audit/PHASE1_AUDIT.md',
            'phase2_architecture/PHASE2_ARCHITECTURE.md','phase2_architecture/tb_phase2_directed_axi_pcie_bridge.v',
            'phase2_architecture/tb_perf_enhanced.v','phase2_architecture/tb_perf_baseline.v',
            'phase3_verification/PHASE3_VERIFICATION.md','phase3_verification/tb_phase3_axi_pcie_bridge.v',
            'phase4_synthesis/PHASE4_SYNTHESIS_PPA.md','phase4_synthesis/run_synth.py','phase4_synthesis/ref_declfix.py',
            'phase4_synthesis/rtl_reference/sarcathon_axi_pcie_bridge_phase2.v','phase4_synthesis/reports/ppa_summary.md',
            'phase4_synthesis/lib/sky130_fd_sc_hd__tt_025C_1v80.lib',
            'phase5_physical_design/PHASE5_PHYSICAL_DESIGN.md','phase5_physical_design/build_notebook.py',
            'phase5_physical_design/config.json','phase5_physical_design/config_reference.json',
            'phase5_physical_design/pin_order.cfg','phase5_physical_design/SARCathon_Phase5_LibreLane.ipynb']:
    ck('package file present: '+rel,(root/rel).exists())

# Phase 5: the notebook must embed exactly the current package files (catches a stale notebook).
nb=json.loads((root/'phase5_physical_design'/'SARCathon_Phase5_LibreLane.ipynb').read_text(encoding='utf8'))
cell=next(''.join(c['source']) for c in nb['cells'] if 'EXPECTED_SHA256 = json.loads' in ''.join(c['source']))
expected=json.loads(re.search(r'EXPECTED_SHA256 = json\.loads\(r"""(.*?)"""\)',cell,re.S).group(1))
package=json.loads(re.search(r'PACKAGE_PATH = json\.loads\(r"""(.*?)"""\)',cell,re.S).group(1))
for dest,src in package.items():
    p=root/src
    ck(f'notebook embeds current {src}',p.exists() and hashlib.sha256(p.read_bytes()).hexdigest()==expected[dest])
for cfg_name in ['config.json','config_reference.json']:
    cfg=json.loads((root/'phase5_physical_design'/cfg_name).read_text())
    files=[f.replace('dir::','') for f in cfg['VERILOG_FILES']]+[cfg['IO_PIN_ORDER_CFG'].replace('dir::','')]
    side='optimized' if cfg_name=='config.json' else 'reference'
    ck(f'{cfg_name}: every dir:: path is embedded in the notebook',all(f'{side}/{f}' in package for f in files))
ck('PASS/FAIL summary present','REGRESSION SUMMARY:' in tb and 'RESULT: ALL PHASE 3 CHECKS PASSED' in tb and 'RESULT: PHASE 3 REGRESSION FAILED' in tb)
ck('timeout watchdog present','GLOBAL SIMULATION TIMEOUT' in tb)
for name,ok in checks: print(('PASS' if ok else 'FAIL')+' | '+name)
print(f'STATIC SOURCE CHECKS: {sum(ok for _,ok in checks)}/{len(checks)} passed')
sys.exit(0 if all(ok for _,ok in checks) else 1)
