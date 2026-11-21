// ============================================================================
// engine_agents.svh -- sequences, drivers, monitors and agents
// ============================================================================
// Four jobs live in this file:
//
//   decide what to send     tick_sequence
//   make it happen          master_driver, slave_driver
//   see what happened       master_monitor, slave_monitor, core_monitor
//   organise                master_agent, slave_agent   (no work)
//
// Only the drivers and monitors touch a pin, and each of them crosses between
// the class world and the hardware world in exactly ONE line:
//
//   mailbox:  class ------> class      (mb.put / mb.get, no time passes)
//   hardware: class ------> WIRES      (vif.*, consumes simulation time)
//
// A mailbox cannot set s_tvalid or wait for s_tready. That is why a driver
// exists at all.
// ============================================================================


// ============================================================================
// MASTER SIDE -- sends ticks into the DUT
// ============================================================================

// Decides WHAT to send. Knows nothing about pins or protocol -- it has no
// `vif` handle at all.
//
// In plain SystemVerilog the mailbox IS the sequencer: this class puts items
// in, the driver takes them out. UVM's uvm_sequencer is the same handoff with
// a factory and phases wrapped around it.
class tick_sequence;
    mailbox #(tick_item) mb;

    int unsigned n           = 100;
    int          crossed_pct = 10;
    int          max_gap     = 6;

    function new(mailbox #(tick_item) mb);
        this.mb = mb;
    endfunction

    task run();
        tick_item t;
        repeat (n) begin
            t = new();
            t.crossed_pct = crossed_pct;
            t.max_gap     = max_gap;
            if (!t.randomize())
                $fatal(1, "tick_item randomize() failed");
            mb.put(t);      // blocks when the driver is behind (mailbox is bounded)
        end
    endtask
endclass


// Decides HOW to send it. The only thing in the testbench that touches an
// input pin.
//
// It has no knobs and no idea which test is running: this code is
// byte-for-byte identical for smoke, backpressure and overflow. That is the
// sense in which a driver is "narrow" -- one job, done exactly, with no
// knowledge of why.
class master_driver;
    virtual axis_if      vif;    // where the pins are
    mailbox #(tick_item) mb;     // where the work comes from

    function new(virtual axis_if vif, mailbox #(tick_item) mb);
        this.vif = vif;
        this.mb  = mb;
    endfunction

    task run();
        tick_item t;

        vif.s_tvalid <= 1'b0;
        vif.s_tdata  <= '0;
        wait (vif.rst_n === 1'b1);

        forever begin
            mb.get(t);                          // <-- MAILBOX. Blocks until work.

            // ---------------- everything below is HARDWARE ----------------
            repeat (t.gap) @(negedge vif.clk);

            // AXI4-Stream rule: raise tdata and tvalid, then HOLD them
            // until a rising edge where tready is also high. That edge is
            // the transfer. Dropping tvalid early is illegal.
            @(negedge vif.clk);
            vif.s_tdata  <= t.pack();
            vif.s_tvalid <= 1'b1;

            do @(posedge vif.clk); while (vif.s_tready !== 1'b1);

            @(negedge vif.clk);
            vif.s_tvalid <= 1'b0;
        end
    endtask
endclass


// Watches the input pins and counts coverage.
//
// Why not just sample inside the driver? Because the driver knows what it
// INTENDED. The monitor reports what the WIRES did. If the driver had a bug,
// its own record would be a lie and the coverage report would claim you
// tested something you never sent.
class master_monitor;
    virtual axis_if vif;
    int unsigned    n_seen = 0;

    // sampled variables -- a covergroup samples variables, not expressions
    book_e     cv_book;
    bit [31:0] cv_bid_sz, cv_ask_sz;

    covergroup cg_tick;
        // An enum coverpoint gets one automatic bin per label.
        cp_book: coverpoint cv_book;

        // Only zero vs non-zero matters: zero is the microprice fallback
        // case, and every non-zero size takes the same path.
        cp_bid_sz: coverpoint cv_bid_sz { bins zero = {0}; bins nonzero = {[1:$]}; }
        cp_ask_sz: coverpoint cv_ask_sz { bins zero = {0}; bins nonzero = {[1:$]}; }

        // Both sizes zero at once is the fallback case. Only the cross can
        // prove that combination was actually reached.
        x_sizes: cross cp_bid_sz, cp_ask_sz;
    endgroup

    function new(virtual axis_if vif);
        this.vif = vif;
        cg_tick  = new();    // a covergroup in a class must be built in new()
    endfunction

    task run();
        tick_item t = new();
        forever begin
            @(posedge vif.clk);
            // A transfer happens only when BOTH tvalid and tready are high.
            if (vif.rst_n && vif.s_tvalid && vif.s_tready) begin
                t.unpack(vif.s_tdata);
                cv_book   = t.book;
                cv_bid_sz = t.bid_sz;
                cv_ask_sz = t.ask_sz;
                n_seen++;
                cg_tick.sample();
            end
        end
    endtask
endclass


// A container. It does no work: it builds its three pieces and starts two of
// them. Delete it and the env would call drv.run() and mon.run() itself.
//
// What a container buys you in a real project: you can build the monitor and
// NOT the driver, so the same checking works at chip level where a
// neighbouring block drives the bus. That is what UVM's active/passive switch
// is. Nothing here is ever passive, so this one is holding a switch nobody
// flips -- it is here because it is the shape the industry uses.
class master_agent;
    virtual axis_if      vif;
    mailbox #(tick_item) seq_mb;     // <-- this is the sequencer

    tick_sequence  seq;              // what to send
    master_driver  drv;              // how to send it
    master_monitor mon;              // what actually went out

    function new(virtual axis_if vif, mailbox #(tick_item) seq_mb);
        this.vif    = vif;
        this.seq_mb = seq_mb;
        seq = new(seq_mb);
        drv = new(vif, seq_mb);      // same mailbox, both ends
        mon = new(vif);
    endfunction

    task run();
        fork
            drv.run();               // a class cannot contain an always
            mon.run();               // block, so processes are forked
        join_none                    // by hand
    endtask
endclass


// ============================================================================
// SLAVE SIDE -- receives quotes, and decides how slowly
// ============================================================================

// Drives exactly one wire. That wire is the most important thing in this
// testbench: it is the only knob that separates the three tests, and the
// reason ../core_tb/tb_axis.sv was worthless (it kept the receiver ready often
// enough that the FIFO could never fill).
//
// No sequencer, because a stream of "ready / not ready" coin flips is not
// worth writing a sequence for. The sequence-based version is the right
// choice when the response side has to react to what it received, which is
// not the case here.
class slave_driver;
    virtual axis_if vif;
    int             ready_pct;      // chance tready is high on any cycle

    function new(virtual axis_if vif, int ready_pct);
        this.vif       = vif;
        this.ready_pct = ready_pct;
    endfunction

    task run();
        vif.m_tready <= 1'b0;
        wait (vif.rst_n === 1'b1);
        forever begin
            @(negedge vif.clk);
            vif.m_tready <= ($urandom_range(99) < ready_pct);
        end
    endtask
endclass


// Watches the output pins. Everything it sees is "actual".
//
// Note what is NOT in this class: there is no `scoreboard` member. It knows
// only that there is a mailbox. Delete the scoreboard entirely and this still
// compiles -- that decoupling is the one thing here that genuinely earns its
// keep.
//
// Same five lines as master_monitor, different destination -- which is why,
// for a real bus, you buy one VIP and configure it twice instead of writing
// this twice.
class slave_monitor;
    virtual axis_if       vif;
    mailbox #(quote_item) mb;       // "a box". Not "the scoreboard".
    int unsigned          n_seen = 0;

    function new(virtual axis_if vif, mailbox #(quote_item) mb);
        this.vif = vif;
        this.mb  = mb;
    endfunction

    task run();
        quote_item q;
        forever begin
            @(posedge vif.clk);
            if (vif.rst_n && vif.m_tvalid && vif.m_tready) begin
                q     = new();
                q.bid = vif.m_tdata[63:32];
                q.ask = vif.m_tdata[31:0];
                n_seen++;
                mb.put(q);          // <-- MAILBOX. One line.
            end
        end
    endtask
endclass


class slave_agent;
    virtual axis_if       vif;
    mailbox #(quote_item) actual_mb;

    slave_driver  drv;
    slave_monitor mon;

    function new(virtual axis_if vif, mailbox #(quote_item) actual_mb,
                 int ready_pct);
        this.vif       = vif;
        this.actual_mb = actual_mb;
        drv = new(vif, ready_pct);
        mon = new(vif, actual_mb);
    endfunction

    task run();
        fork
            drv.run();
            mon.run();
        join_none
    endtask
endclass


// ============================================================================
// THE EXPECTED STREAM
// ============================================================================
// In no agent, because there is no bus here and nothing to drive. It is a
// lone observer of the chip's insides, reaching at dut.quote_valid -- not a
// standard, not a boundary, so it can never be reused anywhere. That is
// exactly what it is for.
//
// Every quote the core produces either
//   * goes into the FIFO     -> it must appear on m_axis later, in order
//   * is dropped (FIFO full) -> it must be counted in dropped_quotes
//
// It also collects the FIFO coverage, because it is already looking at the
// FIFO every cycle.
class core_monitor;
    virtual axis_if       vif;
    mailbox #(quote_item) mb;       // -> scoreboard, as "expected"
    int unsigned          n_produced = 0;

    int cv_count;
    bit cv_tready;

    covergroup cg_fifo;
        cp_occupancy: coverpoint cv_count {
            bins empty = {0};
            bins part  = {[1:FIFO_DEPTH-1]};
            bins full  = {FIFO_DEPTH};
        }
        cp_tready: coverpoint cv_tready;      // automatic bins: 0 and 1

        // A full FIFO while the receiver is stalled IS the drop case.
        x_full_stalled: cross cp_occupancy, cp_tready;
    endgroup

    function new(virtual axis_if vif, mailbox #(quote_item) mb);
        this.vif = vif;
        this.mb  = mb;
        cg_fifo  = new();
    endfunction

    task run();
        quote_item q;
        forever begin
            @(posedge vif.clk);
            if (vif.rst_n) begin
                // FIFO coverage is per CYCLE, not per quote
                cv_count  = vif.fifo_count;
                cv_tready = vif.m_tready;
                cg_fifo.sample();

                if (vif.core_valid) begin
                    q            = new();
                    q.bid        = vif.core_bid;
                    q.ask        = vif.core_ask;
                    q.dropped    = vif.fifo_full;   // full -> the DUT drops it
                    q.fifo_count = vif.fifo_count;
                    n_produced++;
                    mb.put(q);
                end
            end
        end
    endtask
endclass
