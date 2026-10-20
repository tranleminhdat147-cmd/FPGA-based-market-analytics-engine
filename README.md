<img width="825" height="796" alt="image" src="https://github.com/user-attachments/assets/75c17ca3-9d55-4404-b43f-a64287418d34" />FPGA Market-Making Quote Engine
===============================

A real-time market-making quote engine in SystemVerilog. It turns every top-of-book
update into a two-sided quote in 7 clock cycles, accepts one update per clock cycle,
and fits in 13% of an Intel Cyclone IV E FPGA.

On every tick it computes a size-weighted microprice, smooths it into a fair value,
and quotes fair value plus or minus k times sigma, where sigma is a volatility
estimate updated once per time bar.


Overview
--------

A market maker continuously offers to buy (bid) and sell (ask) around what it thinks
an asset is worth, and widens its quotes when the market gets jumpy. This engine does
that pricing in hardware, with two paths:

- Fast path (every tick): microprice -> fair value -> quote, fully pipelined.
- Slow path (once per bar): price move since the last bar -> squared -> averaged ->
  square root = volatility (sigma), which sets how wide the quotes are.


The math
--------

- Microprice (every tick):  mp = bid + (ask - bid) * bid_sz / (bid_sz + ask_sz)
- Fair value (every tick):  FV = FV + (mp - FV) / 2^fv_k   (exponential moving average)
- Return (every bar):       r = FV(this bar) - FV(last bar)
- Variance (every bar):     var = var + (r^2 - var) / 2^var_k
- Volatility (every bar):   sigma = sqrt(var)
- Quote (every tick):       bid = floor(FV - k*sigma), ask = ceil(FV + k*sigma), ask >= bid + 1

Prices are in ticks, the smallest price step (for example $0.01 for US stocks).
A bar is a fixed number of clock cycles, set by bar_period (for example 50,000 cycles
= 1 ms at 50 MHz).


Key design techniques
---------------------

- Division without a divider. 1 / (bid_sz + ask_sz) is computed by writing the
  denominator as m * 2^p (1 <= m < 2): 1/m comes from a 1,024-entry lookup table in
  block RAM, and 2^-p is a shift. Worst-case error is about 0.05% of the spread.
- Uniform fixed point. Every fractional value has 16 fraction bits. Two rules keep it
  that way: shift right by 16 after a multiply, shift left by 16 before a square root.
- Pipelining with valid signals. Each stage passes its data with a valid flag, and
  values needed later are carried stage to stage, so a new tick can enter every cycle.
- Signed spread. Crossed books (ask below bid) use the same formula with a signed
  spread. Extreme garbage input is clamped so the result never wraps around.
- Exact square root. A digit-by-digit (shift-and-subtract) square root: one result bit
  per cycle, exact (rounded down), very little hardware.
- Fast path / slow path split. Only the per-tick path is latency-critical. Volatility
  changes slowly, so each quote uses the latest finished sigma.


Results
-------

Full Quartus Prime 25.1 Lite compile on a Cyclone IV E EP4CE22F17C6, with a 50 MHz
clock constraint (analytics_core_axis as the top level, ports set as virtual pins):

- Tick-to-quote latency: 7 clock cycles (140 ns at 50 MHz)
- Throughput: 1 tick per clock cycle
- Logic elements: 2,909 of 22,320 (13%)
- Registers: 981
- Memory bits: 17,408 of 608,256 (3%)
- 9-bit multipliers: 24 of 132 (18%)
- Fmax, slow model at 85 C: 55.3 MHz (target 50 MHz)
- Worst setup slack: +1.93 ns; worst hold slack: +0.11 ns


Interfaces
----------

analytics_core (plain valid-only ports):

- Inputs, one top-of-book update: tick_valid, bid, ask, bid_sz, ask_sz (32 bits each)
- Settings: fv_k and var_k (smoothing, window about 2^k samples); quote_k (quote
  half-width in sigmas, 16 fraction bits, so 2.0 = 32'h0002_0000); bar_period (cycles
  per bar, 0 = off, keep at least about 40)
- Outputs, the quote: quote_valid, quote_bid, quote_ask (whole ticks)
- Monitoring outputs: fv (fair value), sigma (volatility), ts (cycle counter)

analytics_core_axis (the same engine behind AXI4-Stream):

- Ticks in on s_axis: tdata[127:0] = {bid, ask, bid_sz, ask_sz}. tready is always 1.
- Quotes out on m_axis: tdata[63:0] = {quote_bid, quote_ask}, through a 16-entry FIFO,
  so a slow receiver can apply back-pressure. Overflows are counted in dropped_quotes.


Repository layout
-----------------

    analytics_core.sv        top of the math engine (wires the blocks together)
    analytics_core_axis.sv   AXI4-Stream wrapper with an output FIFO
    microprice.sv            size-weighted microprice (reciprocal LUT, 4-stage pipeline)
    ema.sv                   exponential moving average (fair value and variance)
    bar_trigger.sv           one pulse every bar_period cycles
    return_sq.sv             squared fair-value return per bar
    sigma_sqrt.sv            digit-by-digit square root (34 cycles)
    quote.sv                 FV +/- k*sigma, rounded outward to whole ticks
    timestamp.sv             64-bit cycle counter
    Engine_top.qpf / .qsf    Quartus project
    Engine_top.sdc           timing constraints (50 MHz clock)
    tb/
      tb_math.sv             block-level tests (each block on its own)
      tb_simple.sv           system-level test (the whole engine)
      tb_axis.sv             interface-level test (AXI4-Stream wrapper)
      VERIFICATION_PLAN.md   what is verified, how, and why
      TB_WALKTHROUGH.md      what tb_simple does, step by step
      README.txt             how to run the testbenches


Verification
------------

Three self-checking testbenches, one per level. All three pass.

tb_math.sv, block level, each block tested on its own:
- 6,000+ microprice cases: normal, crossed, locked, empty and extreme books
- 506 square roots, each checked to be exact, and their 34-cycle latency
  (counted, and checked with an SVA assertion)
- Quote rounding edge cases
- EMA settling on its target

tb_simple.sv, system level, the whole engine:
- Every microprice, fair value, sigma and quote is compared with a reference model
  whenever its valid signal appears
- An SVA assertion checks that every tick produces a quote exactly 7 cycles later
- At the end, it checks that no result was lost
- 6,289 checks per run

tb_axis.sv, interface level, the AXI4-Stream wrapper:
- 40 quotes sent through the wrapper while the receiver is ready only 1 cycle in 5
- All delivered, in order, none dropped


Running the simulations (Questa)
--------------------------------

From the tb folder:

    vlib work

    vlog -sv ../microprice.sv ../ema.sv ../sigma_sqrt.sv ../quote.sv tb_math.sv
    vsim -c tb_math -do "run -all; quit -f"

    vlog -sv ../microprice.sv ../ema.sv ../return_sq.sv ../sigma_sqrt.sv ../quote.sv ../bar_trigger.sv ../timestamp.sv ../analytics_core.sv tb_simple.sv
    vsim -c tb_simple -do "run -all; quit -f"

    vlog -sv ../microprice.sv ../ema.sv ../return_sq.sv ../sigma_sqrt.sv ../quote.sv ../bar_trigger.sv ../timestamp.sv ../analytics_core.sv ../analytics_core_axis.sv tb_axis.sv
    vsim -c tb_axis -do "run -all; quit -f"

Expected last lines: ALL PASS, RESULT: PASS, and "... dropped 0 -> PASS".


Building in Quartus
-------------------

Open Engine_top.qpf and run Processing > Start Compilation. The current top level
(analytics_core_axis) has more ports than the chip has pins, so the project sets all
ports as virtual pins. This gives real resource and timing numbers, but not a
bitstream for the board. Testbench files must not be added to the Quartus design
file list.


Status and roadmap
------------------

Done: RTL, uniform fixed-point design, AXI4-Stream wrapper, three-level verification,
full Quartus compile meeting 50 MHz.

Next:
- Engine_top: UART RX + deframer -> engine -> UART TX, so the design runs on the board
  with about 4 pins (clock, reset, RX, TX)
- Run on hardware (on-chip replay + SignalTap, then live ticks from a PC)
- Replay real top-of-book market data (for example Binance bookTicker)
- Directed tests for huge price jumps, mid-run reset and settings changed at runtime
- Optional: inventory skew (Avellaneda-Stoikov style), Ethernet input, AXI4-Lite settings


Known limitations
-----------------

- bar_period must be at least about 40 cycles; shorter bars make the square root skip
  sigma updates.
- Sigma is 0 for the first two bars, so quotes start at their minimum width (1 tick).
- A very large price gap inflates sigma for about 2^var_k bars.
- Bars run on the FPGA clock, so replayed data must be sent at real-time pace.
- The engine computes quotes only; risk checks and order entry are out of scope.
