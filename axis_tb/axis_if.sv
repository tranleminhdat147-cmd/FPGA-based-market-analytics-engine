// ============================================================================
// axis_if.sv -- the pins, in one place
// ============================================================================
// A class cannot see a wire. Inside a class, `s_tvalid` is not a name that
// exists -- an object lives on the heap, not in the module hierarchy.
//
// This interface is the bridge. tb_top instantiates ONE of these and wires it
// to the DUT; every class gets a `virtual axis_if` handle to it, which is just
// a pointer. That is the only connection between the class world and the
// hardware world.
// ============================================================================

interface axis_if (input logic clk, input logic rst_n);

    // ---- s_axis: ticks going IN  {bid, ask, bid_sz, ask_sz} ----
    logic [127:0] s_tdata;      // driven by master_driver
    logic         s_tvalid;     // driven by master_driver
    logic         s_tready;     // driven by the DUT

    // ---- m_axis: quotes coming OUT  {quote_bid, quote_ask} ----
    logic [63:0]  m_tdata;      // driven by the DUT
    logic         m_tvalid;     // driven by the DUT
    logic         m_tready;     // driven by slave_driver -- the back-pressure

    // ---- the DUT's own drop counter ----
    logic [31:0]  dropped;

    // ---- probes INSIDE the DUT, assigned by tb_top ----
    // This is where "expected" comes from: the quote stream before the FIFO.
    // Not a bus, not a standard -- this chip's guts. Reusable nowhere, which
    // is exactly what it is for.
    logic         core_valid;
    logic [31:0]  core_bid;
    logic [31:0]  core_ask;
    logic         fifo_full;
    logic [4:0]   fifo_count;   // 5 bits, same as the DUT's pointers (FIFO_DEPTH = 16).
                                // Must NOT be wider: wr_ptr - rd_ptr has to wrap at 32,
                                // or the count is garbage whenever the pointers have wrapped.

endinterface
