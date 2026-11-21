HOW TO TEST THE ANALYTICS ENGINE
================================

Three testbenches, one per verification level:

  tb_math.sv             BLOCK level: each block on its own (microprice, square
                         root, quote, EMA), driven directly. Deep tests: 6,000+
                         microprice cases, exact square roots + their 34-cycle
                         latency, quote edge cases.
  tb_math_chain.sv       SYSTEM level: the whole engine (analytics_core), END TO END.
                         Predicts every quote from the ticks alone and checks it
                         within 1 tick -- no probes inside the DUT. Constrained-
                         random ticks, functional coverage, an SVA assertion for
                         the 7-cycle latency, and that no quote is lost.
                         Needs a LICENSED Questa (randomize + covergroups).
  tb_axis.sv             INTERFACE level: the AXI4-Stream wrapper. Back-pressure
                         (slow receiver), ordering, nothing dropped.

  VERIFICATION_PLAN.md   what is checked, how, and why
  TB_WALKTHROUGH.md      what tb_analytics_core does, step by step


A. RUN FROM A TERMINAL (fastest)
--------------------------------
  Easiest -- run.do compiles everything for you:
    cd "D:\Major projects\FPGA-based market-analytics engine\tb"
    vsim -c -do "do run.do"              both: tb_math, then tb_math_chain
    vsim -c -do "do run.do math"         tb_math only
    vsim -c -do "do run.do chain"        tb_math_chain only
    vsim -c -do "do run.do chain 7"      tb_math_chain with seed 7
    vsim -c -l run.log -do "do run.do"   same, and save the output
  tb_math_chain's coverage report lands in cov/coverage.txt

  Or by hand, one testbench at a time:
    vlib work

  tb_math:
    vlog -sv ../microprice.sv ../ema.sv ../sigma_sqrt.sv ../quote.sv tb_math.sv
    vsim -c tb_math -do "run -all; quit -f"
    -> last line: ALL PASS

  tb_math_chain:
    vlog -sv ../microprice.sv ../ema.sv ../return_sq.sv ../sigma_sqrt.sv ../quote.sv ../bar_trigger.sv ../timestamp.sv ../analytics_core.sv tb_math_chain.sv
    vsim -c tb_math_chain -do "run -all; quit -f"
    -> last line: RESULT: PASS

  tb_axis:
    vlog -sv ../microprice.sv ../ema.sv ../return_sq.sv ../sigma_sqrt.sv ../quote.sv ../bar_trigger.sv ../timestamp.sv ../analytics_core.sv ../analytics_core_axis.sv tb_axis.sv
    vsim -c tb_axis -do "run -all; quit -f"
    -> last line: quotes produced 40, received 40, mismatches 0, dropped 0 -> PASS


B. RUN FROM QUARTUS
-------------------
One-time setup:

 1. Add the design files (NOT the files in tb\):
      Project > Add/Remove Files in Project > add
        microprice.sv  ema.sv  return_sq.sv  sigma_sqrt.sv  quote.sv
        bar_trigger.sv  timestamp.sv  analytics_core.sv  analytics_core_axis.sv

 2. Make analytics_core (or analytics_core_axis) the top level until Engine_top exists:
      Assignments > Settings > General > Top-level entity

 3. Tell Quartus about a testbench:
      Assignments > Settings > EDA Tool Settings > Simulation
        Tool name:  Questa Altera FPGA
        NativeLink settings: (o) Compile test bench > Test Benches... > New...
            Test bench name / Top level module: tb_math_chain   (or tb_math, tb_axis)
            End simulation at: Run simulation until all vector stimuli are used
            Test bench files: add  tb\tb_math_chain.sv
        OK > OK > OK

Every run:

 4. Processing > Start > Start Analysis & Elaboration
      (do NOT run a full compile with analytics_core as the top: it has
       ~400 ports and the chip only has ~153 pins)

 5. Tools > Run Simulation Tool > RTL Simulation
      Read the last lines of the Questa Transcript window.
