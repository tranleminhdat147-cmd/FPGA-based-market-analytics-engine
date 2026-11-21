# core_tb — the maths of `analytics_core`

## What it tests

That the core computes the right numbers.

| Testbench | Tests |
|---|---|
| `tb_math.sv` | **each maths block on its own**, against a formula: `microprice` (normal, crossed, locked books, zero sizes, extreme prices), `sigma_sqrt` (exact root, 34-cycle latency), `quote` (outward rounding, ask ≥ bid + 1, bid clamped at 0), `ema` (settles to its input) |
| `tb_math_chain.sv` | **the whole core, end to end**: every quote must match a reference model, predicted from the ticks alone, within 1 tick. Also: a quote 7 cycles after every tick, and no quote lost |

## Structure

**`tb_math.sv`** — one module. Each block is instantiated on its own and driven
directly. A `check_*` task per block feeds an input, waits for the output, and
compares it with the formula. Hand-picked cases first, then random sweeps.

**`tb_math_chain.sv`** — one module, the core as a black box (ticks in, quotes out):

```
ticks ──► [ analytics_core ]  ──► quote ──┐
                                          ├──► compare, ±1 tick
ticks ──► [ reference model ] ──► expected┘
```

| Part | Job |
|---|---|
| reference model | the core in plain maths: microprice → fair value (EMA) → return² per bar → variance (EMA) → sigma (√) → quote. Tracks which sigma each quote used, since a new sigma takes 37 cycles |
| `tick_c` class | constrained-random ticks: price step, book type, spread, sizes, gap |
| covergroup `cg_tick` | book type, zero sizes, and their cross |
| assertion | a quote exactly 7 cycles after every tick |
| tests | 1: 6 hand-picked books · 2: 50 back-to-back ticks · 3: 2,000 random ticks |

| File | |
|---|---|
| `tb_math.sv` | block-level testbench |
| `tb_math_chain.sv` | end-to-end testbench |
| `run.do` | compiles the design in `../`, runs one or both |
| `tb_axis.sv` | legacy wrapper check, replaced by `../axis_tb/` |
