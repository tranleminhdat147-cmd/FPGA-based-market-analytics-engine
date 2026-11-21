`timescale 1ns/1ps
// ============================================================================
// tb_top.sv -- the static shell: clock, DUT, probes, assertions, test select
// ============================================================================
// Everything dynamic lives in engine_pkg.sv. This file exists because classes
// cannot do any of the following: make a clock, instantiate a DUT, hold an
// interface, or write an assertion.
//
// Plusargs:
//   +TEST=<name>  smoke | backpressure | overflow   (default: backpressure)
//   +seed=<n>     random seed (default 1)
//
// NOTE: needs a licensed simulator. randomize() and covergroups are not in
// the free Questa Starter edition that ships with Quartus.
// ============================================================================

module tb_top;

    import engine_pkg::*;

    localparam int FIFO_DEPTH = engine_pkg::FIFO_DEPTH;

    // ------------------------------------------------------------------
    // clock and reset
    // ------------------------------------------------------------------
    logic clk = 0;
    always #10 clk = ~clk;                  // 50 MHz

    logic rst_n = 0;
    initial begin
        repeat (5) @(negedge clk);
        rst_n = 1;
    end

    // ------------------------------------------------------------------
    // the pins
    // ------------------------------------------------------------------
    axis_if bus (clk, rst_n);

    // ------------------------------------------------------------------
    // DUT
    // ------------------------------------------------------------------
    analytics_core_axis #(.FIFO_DEPTH(FIFO_DEPTH)) dut (
        .aclk          (clk),
        .aresetn       (rst_n),

        .s_axis_tdata  (bus.s_tdata),
        .s_axis_tvalid (bus.s_tvalid),
        .s_axis_tready (bus.s_tready),

        .m_axis_tdata  (bus.m_tdata),
        .m_axis_tvalid (bus.m_tvalid),
        .m_axis_tready (bus.m_tready),

        .fv_k          (5'd2),
        .var_k         (5'd2),
        .quote_k       (32'h0002_0000),     // 2.0 in Q16.16
        .bar_period    (32'd50),

        .dropped_quotes(bus.dropped)
    );

    // ------------------------------------------------------------------
    // probes -- the quote stream BEFORE the FIFO
    // ------------------------------------------------------------------
    // This is where "expected" comes from. The wrapper's job is to deliver
    // every quote the core makes, so the core's own output IS the reference.
    assign bus.core_valid = dut.quote_valid;
    assign bus.core_bid   = dut.quote_bid;
    assign bus.core_ask   = dut.quote_ask;
    assign bus.fifo_full  = dut.full;
    assign bus.fifo_count = dut.wr_ptr - dut.rd_ptr;

    // ------------------------------------------------------------------
    // AXI4-Stream assertions
    // ------------------------------------------------------------------
    // Once tvalid is up it must stay up until the transfer happens, and tdata
    // must not change underneath it. These assert against our OWN driver as
    // well as the DUT -- getting the handshake wrong is that easy.
    a_tvalid_stable: assert property (@(posedge clk) disable iff (!rst_n)
        (bus.s_tvalid && !bus.s_tready) |=> (bus.s_tvalid && $stable(bus.s_tdata))
    ) else $error("[ASSERT] s_axis tvalid/tdata moved before the transfer completed");

    // The DUT must not withdraw a quote it has already offered just because
    // the receiver was slow.
    a_mvalid_stable: assert property (@(posedge clk) disable iff (!rst_n)
        (bus.m_tvalid && !bus.m_tready) |=> (bus.m_tvalid && $stable(bus.m_tdata))
    ) else $error("[ASSERT] m_axis withdrew a quote before the receiver took it");

    // NOTE on a_tvalid_stable: this DUT ties s_axis_tready to 1, so that
    // assertion's antecedent (s_tvalid && !s_tready) is ALWAYS FALSE and the
    // assertion is vacuous -- it can never fail, and its "pass" in a report
    // means nothing. It is kept because it would catch a future RTL change,
    // and because it guards our own driver.
    //
    // This assertion makes that vacuity deliberate instead of accidental: if
    // the DUT ever gains input back-pressure, this fires and tells us
    // a_tvalid_stable has started meaning something.
    a_s_ready_tied: assert property (@(posedge clk) disable iff (!rst_n)
        bus.s_tready === 1'b1
    ) else $error("[ASSERT] s_tready is no longer tied high -- input back-pressure is now live, a_tvalid_stable is no longer vacuous");

    // ------------------------------------------------------------------
    // test settings -- a test is a set of knobs, picked by +TEST=
    // ------------------------------------------------------------------
    // No base_test class and no inheritance: three tests differing by four
    // integers do not need a class hierarchy. The important property is that
    // ONLY these four numbers change between runs -- the env, the agents and
    // the scoreboard are identical, so a failure can never be "the testbench
    // was different this time".
    string       test_name   = "backpressure";
    int unsigned seed        = 1;

    int unsigned n_ticks     = 300;
    int          ready_pct   = 20;      // how often the receiver accepts
    int          crossed_pct = 10;
    int          max_gap     = 6;

    env e;

    // The verdict, as module variables so run.do can `examine` them.
    int unsigned errors      = 0;
    bit          test_passed = 0;

    initial begin
        void'($value$plusargs("TEST=%s", test_name));
        void'($value$plusargs("seed=%d", seed));
        void'($urandom(seed));
        process::self().srandom(seed);

        case (test_name)
            // receiver always ready -- every quote must come out, 0 drops
            "smoke"       : begin n_ticks=100; ready_pct=100; max_gap=4; crossed_pct=10; end
            // slow random receiver -- order must hold, the FIFO absorbs bursts
            "backpressure": begin n_ticks=300; ready_pct=20;  max_gap=6; crossed_pct=10; end
            // ticks back to back, receiver almost never ready -- the FIFO
            // fills, the DUT starts dropping, and we check its drop counter
            "overflow"    : begin n_ticks=400; ready_pct=3;   max_gap=0; crossed_pct=15; end
            default: $fatal(1, "unknown test '%s' -- try smoke, backpressure or overflow",
                            test_name);
        endcase

        $display("--- test %s: %0d ticks, receiver ready %0d %% of cycles ---",
                 test_name, n_ticks, ready_pct);

        e = new(bus, ready_pct);        // hand the pins into the class world
        e.run();                        // start every component

        wait (rst_n === 1'b1);
        e.send(n_ticks, crossed_pct, max_gap);
        drain();
        e.report(test_name, seed);

        // Copy the verdict out of the class world into MODULE variables.
        // run.do reads these with `examine`, and examine cannot walk into a
        // class: objects live on the heap, not in the elaborated hierarchy,
        // so /tb_top/e/sb/errors is not a path that exists.
        errors      = e.sb.errors;
        test_passed = (errors == 0);

        $finish;
    end

    // ------------------------------------------------------------------
    // drain -- wait for the pipeline and the FIFO to go quiet
    // ------------------------------------------------------------------
    // `automatic` because a task in a MODULE is static by default (inside a
    // class it would already be automatic). Static locals are shared between
    // calls, which is a classic source of testbench bugs.
    //
    // 50 quiet cycles in a row is well past the core's longest latency.
    task automatic drain();
        int quiet = 0, cycles = 0;
        while (quiet < 50 && cycles < 200000) begin
            @(posedge clk);
            cycles++;
            if (bus.fifo_count == 0 && !bus.core_valid) quiet++;
            else                                        quiet = 0;
        end
        if (cycles >= 200000)
            $display("WARNING: drain timed out with %0d quotes still in the FIFO",
                     bus.fifo_count);
    endtask

    // Safety net: if something deadlocks, stop instead of hanging forever.
    initial begin
        #50ms;
        $display(" TEST FAILED -- global timeout");
        $finish;
    end

endmodule
