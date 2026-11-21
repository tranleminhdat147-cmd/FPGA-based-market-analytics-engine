// ============================================================================
// engine_pkg.sv -- the package
// ============================================================================
// THE WHOLE IDEA, in four lines:
//
//   expected = every quote the core produces, tapped BEFORE the FIFO
//   actual   = every quote that comes out of m_axis
//   they must match, one for one, in order
//   and any quote the core made while the FIFO was full must be counted
//   as dropped instead
//
// There is no reference model and none is needed. This verifies the AXI
// WRAPPER, not the maths inside the core, so "the right answer" is simply
// "whatever the core produced".
//
// ----------------------------------------------------------------------------
// HOW THE PIECES CONNECT
// ----------------------------------------------------------------------------
//
//   tick_sequence --[seq_mb]--> master_driver --> s_axis --> +---------+
//                                                           |         |
//                               master_monitor <-- s_axis   |   DUT   |
//                                      |                    |         |
//                                  cg_tick                  | core -> |
//                                                           |  FIFO ->|
//   core_monitor <------- probes inside the DUT ------------ |         |
//        |     |                                            +----+----+
//    cg_fifo  [expected_mb]                                      | m_axis
//                  |                                             v
//                  +--> scoreboard <--[actual_mb]-- slave_monitor
//                                                  slave_driver -> m_tready
//
// ----------------------------------------------------------------------------
// THE INCLUDE ORDER IS THE DEPENDENCY ORDER
// ----------------------------------------------------------------------------
// SystemVerilog reads top to bottom and a class must be declared before it is
// used, so:
//   items     first, because everything carries them
//   agents    next, because they carry items
//   checkers  next
//   env       last, because it names all of the above
// ============================================================================

package engine_pkg;

    // FIFO depth of the DUT. Deliberately small: a deep FIFO can never fill,
    // which is exactly why ../core_tb/tb_axis.sv never tested the overflow path.
    parameter int FIFO_DEPTH = 16;

    typedef enum { BOOK_NORMAL,    // ask > bid, the usual case
                   BOOK_LOCKED,    // ask == bid
                   BOOK_CROSSED    // ask < bid
                 } book_e;

    `include "engine_items.svh"      // tick_item, quote_item
    `include "engine_agents.svh"     // sequence, 2 drivers, 3 monitors, 2 agents
    `include "engine_checkers.svh"   // scoreboard
    `include "engine_env.svh"        // env -- the wiring

endpackage
