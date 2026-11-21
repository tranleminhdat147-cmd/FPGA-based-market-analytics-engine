// ============================================================================
// engine_env.svh -- the wiring
// ============================================================================
// THIS FILE IS THE WIRING DIAGRAM.
//
// A mailbox has no destination field. `mb.put(q)` names nobody, and a monitor
// has no idea who reads the box. The destination is decided HERE, by who gets
// handed the same handle.
//
// So when reading an unfamiliar testbench and asking "where does this data
// go?", do not read the monitor -- the monitor cannot tell you. Read this
// constructor. In UVM the same information lives in connect_phase.
//
//   seq_mb       tick_sequence -> master_driver     (what to send)
//   expected_mb  core_monitor  -> scoreboard        (what should come out)
//   actual_mb    slave_monitor -> scoreboard        (what did come out)
//
// Three mailboxes, each with exactly one producer and one consumer.
// ============================================================================


class env;
    virtual axis_if vif;

    mailbox #(tick_item)  seq_mb;
    mailbox #(quote_item) expected_mb;
    mailbox #(quote_item) actual_mb;

    master_agent m_agt;
    slave_agent  s_agt;
    core_monitor core_mon;
    scoreboard   sb;

    // The only confusing part of the whole testbench, and it is six lines:
    // create each mailbox ONCE, then give it to the two classes that share
    // it. Same object, two handles -- like passing one queue pointer to a
    // producer and a consumer.
    function new(virtual axis_if vif, int ready_pct);
        this.vif = vif;

        // bounded at 1, so the sequence cannot run ahead of the driver --
        // which is what a UVM sequencer's item_done handshake gives you
        seq_mb      = new(1);
        expected_mb = new();
        actual_mb   = new();

        m_agt    = new(vif, seq_mb);                  // gets seq_mb
        s_agt    = new(vif, actual_mb, ready_pct);    // gets actual_mb
        core_mon = new(vif, expected_mb);             // gets expected_mb
        sb       = new(expected_mb, actual_mb);       // gets BOTH <- the destination
    endfunction

    task run();
        m_agt.run();          // these fork their own children
        s_agt.run();
        sb.run();
        fork
            core_mon.run();   // a leaf: a forever loop, so fork it here
        join_none
    endtask

    // Hand the test's knobs to the sequence and start it. Returns once every
    // tick has been given to the driver.
    task send(int unsigned n, int crossed_pct, int max_gap);
        m_agt.seq.n           = n;
        m_agt.seq.crossed_pct = crossed_pct;
        m_agt.seq.max_gap     = max_gap;
        m_agt.seq.run();
    endtask

    function void report(string test_name, int unsigned seed);
        bit  passed;
        real cov_pct;

        sb.final_check(vif.dropped);

        passed  = (sb.errors == 0);
        cov_pct = (m_agt.mon.cg_tick.get_coverage() +
                   core_mon.cg_fifo.get_coverage()) / 2.0;

        $display("------------------------------------------------------------");
        $display(" ticks sent         : %0d", m_agt.mon.n_seen);
        $display(" quotes produced    : %0d", sb.n_produced);
        $display("   ... accepted     : %0d", sb.n_produced - sb.n_dropped_exp);
        $display("   ... dropped      : %0d  (DUT counter says %0d)",
                 sb.n_dropped_exp, vif.dropped);
        $display(" quotes received    : %0d", sb.n_received);
        $display(" scoreboard matches : %0d", sb.n_matched);
        $display(" scoreboard errors  : %0d", sb.errors);
        $display(" functional coverage: %0.2f %%  (this run only)", cov_pct);
        $display("------------------------------------------------------------");
        $display(" TEST %s  (test=%s seed=%0d)",
                 passed ? "PASSED" : "FAILED", test_name, seed);
        if (!passed)
            $display(" reproduce: +TEST=%s +seed=%0d", test_name, seed);
        $display("------------------------------------------------------------");
    endfunction
endclass
