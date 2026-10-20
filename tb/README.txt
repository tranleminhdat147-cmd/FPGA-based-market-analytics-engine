HOW TO TEST THE ANALYTICS ENGINE
================================

Three testbenches, one per verification level:

  tb_math.sv             BLOCK level: each block on its own (microprice, square
                         root, quote, EMA), driven directly. Deep tests: 6,000+
                         microprice cases, exact square roots + their 34-cycle
                         latency, quote edge cases.
  tb_analytics_core.sv   SYSTEM level: the whole engine (analytics_core). Checks
                         every microprice, fair value, sigma and quote whenever its
                         valid signal appears, an SVA assertion for the 7-cycle
                         latency, and that no result is lost.
  tb_axis.sv             INTERFACE level: the AXI4-Stream wrapper. Back-pressure
                         (slow receiver), ordering, nothing dropped.

  VERIFICATION_PLAN.md   what is checked, how, and why
  TB_WALKTHROUGH.md      what tb_analytics_core does, step by step


A. RUN FROM A TERMINAL (fastest)
--------------------------------
    cd "D:\FPGA-based market-analytics engine\tb"
    vlib work

  tb_math:
    vlog -sv ../microprice.sv ../ema.sv ../sigma_sqrt.sv ../quote.sv tb_math.sv
    vsim -c tb_math -do "run -all; quit -f"
    -> last line: ALL PASS

  tb_analytics_core:
    vlog -sv ../microprice.sv ../ema.sv ../return_sq.sv ../sigma_sqrt.sv ../quote.sv ../bar_trigger.sv ../timestamp.sv ../analytics_core.sv tb_analytics_core.sv
    vsim -c tb_analytics_core -do "run -all; quit -f"
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
            Test bench name / Top level module: tb_analytics_core   (or tb_math, tb_axis)
            End simulation at: Run simulation until all vector stimuli are used
            Test bench files: add  tb\tb_analytics_core.sv
        OK > OK > OK

Every run:

 4. Processing > Start > Start Analysis & Elaboration
      (do NOT run a full compile with analytics_core as the top: it has
       ~400 ports and the chip only has ~153 pins)

 5. Tools > Run Simulation Tool > RTL Simulation
      Read the last lines of the Questa Transcript window.
