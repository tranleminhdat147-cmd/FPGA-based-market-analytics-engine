
# axis_tb — the AXI4-Stream wrapper `analytics_core_axis`

## What it tests

That every quote the core makes is **either delivered on `m_axis` — in order and
unchanged — or dropped because the FIFO was full, and counted.**

| Check | By |
|---|---|
| every quote delivered, in order, unchanged | scoreboard |
| a quote is dropped when the FIFO is full | scoreboard |
| the DUT's `dropped_quotes` counter is right | end-of-test check |
| nothing left stuck in the FIFO | end-of-test check |
| `m_axis` holds a quote while the receiver stalls | assertion |
| the input never stalls (`s_tready` tied high) | assertion |

It does **not** check the maths — that is `../core_tb/`.

| Test | Receiver ready | Targets |
|---|---|---|
| `smoke` | 100% | every quote comes out, nothing dropped |
| `backpressure` | 20% | order holds while the FIFO fills and drains |
| `overflow` | 3% | the FIFO saturates; drops and the counter |

## Structure

No reference model: the right answer is whatever the core produced.

```
              ┌────────── analytics_core_axis ──────────┐
 s_axis ─────►│  core ──┬──► FIFO (16 deep) ────────────►├────► m_axis
              └─────────┼───────────────────────────────┘
                   EXPECTED                         ACTUAL
                        └────────► scoreboard ◄───────┘
```

12 classes, connected by 3 mailboxes:

| Class | Job |
|---|---|
| `tick_item`, `quote_item` | the transactions |
| `tick_sequence` | constrained-random ticks |
| `master_driver` | drives ticks onto `s_axis` |
| `master_monitor` | watches `s_axis`, samples tick coverage |
| `slave_driver` | drives `m_tready` — the back-pressure |
| `slave_monitor` | watches `m_axis` → **actual** |
| `core_monitor` | reads the core's output inside the DUT → **expected**; samples FIFO coverage |
| `master_agent`, `slave_agent` | hold each side's driver and monitor |
| `scoreboard` | compares expected and actual |
| `env` | creates the mailboxes, connects everything |

| File | |
|---|---|
| `axis_if.sv` | the pins, plus probes into the DUT |
| `engine_items.svh` | transactions |
| `engine_agents.svh` | sequence, drivers, monitors, agents |
| `engine_checkers.svh` | scoreboard |
| `engine_env.svh` | env |
| `engine_pkg.sv` | the package |
| `tb_top.sv` | clock, DUT, assertions, test select |
| `run.do` | compile, run, merge coverage |
